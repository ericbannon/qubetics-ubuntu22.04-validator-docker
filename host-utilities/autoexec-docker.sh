#!/bin/bash
exec >> /home/admin/validator-startup.log 2>&1

CONTAINER_NAME="validator-node"
DAEMON_HOME="/mnt/nvme/qubetics"
VALIDATOR_IMAGE="bannimal/tics-validator-node:v1.0.1"

echo "🔁 Resetting QEMU binfmt for cross-arch Docker support..."
docker run --privileged --rm tonistiigi/binfmt --install all

# ✅ Wait for Docker daemon (max 30s)
RETRIES=30
until docker info >/dev/null 2>&1 || [ $RETRIES -eq 0 ]; do
  echo "⏳ Waiting for Docker to be ready..."
  sleep 1
  RETRIES=$((RETRIES - 1))
done

if [ $RETRIES -eq 0 ]; then
  echo "❌ Docker not ready. Exiting."
  exit 1
fi

# ✅ Create container if it doesn't exist
if ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "📦 Container '$CONTAINER_NAME' not found. Creating it..."
  docker run -dit \
    --platform=linux/amd64 \
    --name "$CONTAINER_NAME" \
    --privileged \
    --network host \
    --cpus="$(nproc)" \
    --memory="0" \
    --restart unless-stopped \
    -p 26656:26656 \
    -p 26657:26657 \
    -v /mnt/nvme:/mnt/nvme \
    -e DAEMON_NAME=qubeticsd \
    -e DAEMON_HOME="$DAEMON_HOME" \
    -e DAEMON_ALLOW_DOWNLOAD_BINARIES=false \
    -e DAEMON_RESTART_AFTER_UPGRADE=true \
    -e DAEMON_LOG_BUFFER_SIZE=512 \
    #-e DAEMON_DATA_BACKUP_DIR="/home/admin/qubetics_backup_2025-08-01" \
    "$VALIDATOR_IMAGE"
fi

# ✅ Start if not running
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" != "true" ]; then
  echo "🚀 Starting existing container '$CONTAINER_NAME'..."
  docker start "$CONTAINER_NAME"
  sleep 5

  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" != "true" ]; then
    echo "❌ Container failed to start. Printing logs:"
    docker logs "$CONTAINER_NAME" --tail=100
    exit 1
  fi
else
  echo "✅ Container '$CONTAINER_NAME' is running."
fi

# ✅ Start Cosmovisor with retry logic
echo "📦 Attempting to start Cosmovisor with retry on DB lock..."

START_RETRIES=10
SLEEP_INTERVAL=10
COSMOVISOR_STARTED=false

for ((j=1; j<=START_RETRIES; j++)); do
  echo "⏳ Attempt #$j: Starting Cosmovisor..."

  # 📌 Get initial log line count before starting
  BASELINE_LINE_COUNT=$(docker exec "$CONTAINER_NAME" bash -c "wc -l < '$DAEMON_HOME/cosmovisor.log'")

  # 🚀 Start Cosmovisor
  docker exec "$CONTAINER_NAME" bash -c "
    nohup cosmovisor run start \
      --home \"$DAEMON_HOME\" \
      --json-rpc.api eth,txpool,personal,net,debug,web3 \
      >> \"$DAEMON_HOME/cosmovisor.log\" 2>&1 &
  "

  echo "⏳ Watching new log lines for block sync events..."
  CHECK_RETRIES=25

  for ((k=1; k<=CHECK_RETRIES; k++)); do
    if docker exec "$CONTAINER_NAME" bash -c "tail -n +$((BASELINE_LINE_COUNT + 1)) '$DAEMON_HOME/cosmovisor.log' | grep -q 'indexed block events'"; then
      echo "✅ Cosmovisor is indexing blocks. Startup successful."
      COSMOVISOR_STARTED=true
      break 2
    fi

    echo "⏳ Still waiting for new block events... ($k/$CHECK_RETRIES)"
    sleep "$SLEEP_INTERVAL"
  done

  echo "⚠️ Cosmovisor did not show block events after $CHECK_RETRIES attempts."
done

if [ "$COSMOVISOR_STARTED" != true ]; then
  echo "❌ Cosmovisor startup failed after $START_RETRIES attempts."
  docker exec "$CONTAINER_NAME" tail -n 100 "$DAEMON_HOME/cosmovisor.log"
  exit 1
fi

# Start vote/proposer monitoring in background
nohup tail -F /mnt/nvme/qubetics/cosmovisor.log | grep -Ei "missed|vote" > /mnt/nvme/qubetics/validator_vote_monitor.log 2>&1 &

exit 0