#!/bin/bash
exec >> /home/admin/logs/validator-startup.log 2>&1

# ---- basics ----
mkdir -p /home/admin/logs
CONTAINER_NAME="validator-node"
DAEMON_HOME="/mnt/nvme/qubetics"
VALIDATOR_IMAGE="bannimal/validator-node:v2.0.0"
: "${UPGRADEVER:=v2.0.0}"  # must match the on-chain plan dir name under upgrades/


docker pull --platform=linux/amd64 "$VALIDATOR_IMAGE"
NEW_IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$VALIDATOR_IMAGE")"

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  CUR_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$CONTAINER_NAME")"
  if [ "$CUR_IMAGE_ID" != "$NEW_IMAGE_ID" ]; then
    echo "♻️ Image changed; recreating container..."
    docker stop "$CONTAINER_NAME" || true
    docker rm "$CONTAINER_NAME" || true
  fi
fi


# ✅ Wait for Docker daemon (max 30s)
#RETRIES=30
#until docker info >/dev/null 2>&1 || [ $RETRIES -eq 0 ]; do
#  echo "⏳ Waiting for Docker to be ready..."
#  sleep 1
#  RETRIES=$((RETRIES - 1))
#done

#if [ $RETRIES -eq 0 ]; then
#  echo "❌ Docker not ready. Exiting."
#  exit 1
#fi

# ✅ Create container if it doesn't exist
if ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "📦 Container '$CONTAINER_NAME' not found. Creating it..."
  docker run -dit \
  --platform=linux/amd64 \
  --name "$CONTAINER_NAME" \
  --privileged \
  --network host \
  --restart unless-stopped \
  --cpuset-cpus="0-7" \
  --cpus="8" \
  --memory=16g \
  --memory-swap=24g \
  --ulimit nofile=65536:65536 \
  --ulimit memlock=-1 \
  --cap-add sys_nice \
  -v /mnt/nvme:/mnt/nvme \
  -e DAEMON_NAME=qubeticsd \
  -e DAEMON_HOME="$DAEMON_HOME" \
  -e DAEMON_ALLOW_DOWNLOAD_BINARIES=false \
  -e DAEMON_RESTART_AFTER_UPGRADE=true \
  -e DAEMON_LOG_BUFFER_SIZE=512 \
  "$VALIDATOR_IMAGE"
fi

# ✅ Start if not running
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" != "true" ]; then
  echo "🚀 Starting existing container '$CONTAINER_NAME'..."
  docker start "$CONTAINER_NAME" >/dev/null

  # Give Docker some time to stabilize container state
  for i in {1..10}; do
    sleep 2
    state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)"
    if [ "$state" = "running" ]; then
      echo "✅ Container '$CONTAINER_NAME' is running."
      break
    elif [ "$state" = "exited" ]; then
      echo "❌ Container '$CONTAINER_NAME' exited immediately."
      docker logs "$CONTAINER_NAME" --tail=100
      exit 1
    fi
    echo "⏳ Waiting for container... state=$state"
  done

  if [ "$state" != "running" ]; then
    echo "❌ Container failed to reach running state. Logs:"
    docker logs "$CONTAINER_NAME" --tail=100
    exit 1
  fi
else
  echo "✅ Container '$CONTAINER_NAME' is already running."
fi

# ─────────────────────────────────────────────────────────
# 📌 Seed upgrade binary from image → NVMe if missing
#   Image must contain: /opt/cosmovisor/upgrades/${UPGRADEVER}/bin/qubeticsd
#   Copies to:          /mnt/nvme/qubetics/cosmovisor/upgrades/${UPGRADEVER}/bin/qubeticsd
# ─────────────────────────────────────────────────────────
if ! docker exec "$CONTAINER_NAME" test -x "/mnt/nvme/qubetics/cosmovisor/upgrades/${UPGRADEVER}/bin/qubeticsd"; then
  echo "📥 Seeding upgrade ${UPGRADEVER} binary to host volume..."
  docker exec "$CONTAINER_NAME" bash -lc "
    set -e
    if [ ! -x \"/opt/cosmovisor/upgrades/${UPGRADEVER}/bin/qubeticsd\" ]; then
      echo '❌ Missing /opt/cosmovisor/upgrades/${UPGRADEVER}/bin/qubeticsd in image'; exit 1
    fi
    mkdir -p \"/mnt/nvme/qubetics/cosmovisor/upgrades/${UPGRADEVER}/bin\" &&
    cp \"/opt/cosmovisor/upgrades/${UPGRADEVER}/bin/qubeticsd\" \"/mnt/nvme/qubetics/cosmovisor/upgrades/${UPGRADEVER}/bin/\" &&
    chmod +x \"/mnt/nvme/qubetics/cosmovisor/upgrades/${UPGRADEVER}/bin/qubeticsd\"
  " || { echo "❌ Seeding failed"; exit 1; }
else
  echo "✅ Upgrade binary ${UPGRADEVER} already present on NVMe."
fi

# ✅ Start Cosmovisor with retry logic
echo "📦 Attempting to start Cosmovisor with retry on DB lock..."

START_RETRIES=10
SLEEP_INTERVAL=10
COSMOVISOR_STARTED=false

for ((j=1; j<=START_RETRIES; j++)); do
  echo "⏳ Attempt #$j: Starting Cosmovisor..."

  # 📌 Get initial log line count before starting
  BASELINE_LINE_COUNT=$(docker exec "$CONTAINER_NAME" bash -c "wc -l < '$DAEMON_HOME/cosmovisor.log' || echo 0")

  # 🚀 Start Cosmovisor
  docker exec "$CONTAINER_NAME" bash -lc "
    nohup cosmovisor run start \
      --home \"$DAEMON_HOME\" \
      --json-rpc.api eth,net,web3 \
      >> \"$DAEMON_HOME/cosmovisor.log\" 2>&1 &
  "

  echo "⏳ Watching new log lines for block sync events..."
  CHECK_RETRIES=25

  for ((k=1; k<=CHECK_RETRIES; k++)); do
    if docker exec "$CONTAINER_NAME" bash -lc "tail -n +$((BASELINE_LINE_COUNT + 1)) '$DAEMON_HOME/cosmovisor.log' | grep -q 'indexed block events'"; then
      echo "✅ Cosmovisor is indexing blocks. Startup successful."
      COSMOVISOR_STARTED=true
      break 2
    fi

    echo "⏳ Still waiting for new block events... ($k/$CHECK_RETRIES)"
    sleep "$SLEEP_INTERVAL"
  done

  echo "⚠️ Cosmovisor did not show block events after $CHECK_RETRIES attempts."
done

if [ "$COSMOVISOR_STARTED" != true ] ; then
  echo "❌ Cosmovisor startup failed after $START_RETRIES attempts."
  exit 1
fi

# Start vote/proposer monitoring in background
mkdir -p /mnt/nvme/qubetics/logs
nohup tail -F /mnt/nvme/qubetics/cosmovisor.log | grep -Ei "missed|vote" > /mnt/nvme/qubetics/logs/validator_vote_monitor.log 2>&1 < /dev/null & disown

echo "✅ Cosmovisor started successfully and vote monitor is running."
exit 0