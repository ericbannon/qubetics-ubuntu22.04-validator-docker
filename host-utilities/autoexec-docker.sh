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
    --restart unless-stopped \
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
  docker start "$CONTAINER_NAME"
  sleep 5

  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" != "true" ]; then
    echo "❌ Container failed to start. Printing logs:"
    docker logs "$CONTAINER_NAME" --tail=100
    exit 1
  fi
else
  echo "✅ Container '$CONTAINER_NAME' is already running."
fi

# ✅ Start Cosmovisor with retry logic
echo "📦 Attempting to start Cosmovisor with retry on DB lock..."

START_RETRIES=10
SLEEP_INTERVAL=10

for ((j=1; j<=START_RETRIES; j++)); do
  echo "⏳ Attempt #$j: Starting Cosmovisor..."

  docker exec "$CONTAINER_NAME" bash -c "
    nohup cosmovisor run start \
      --home \"$DAEMON_HOME\" \
      --json-rpc.api eth,txpool,personal,net,debug,web3 \
      >> \"$DAEMON_HOME/cosmovisor.log\" 2>&1 &
  "

  sleep 5

 echo "⏳ Checking Cosmovisor log for block height messages..."

CHECK_RETRIES=20
for ((k=1; k<=CHECK_RETRIES; k++)); do
  if docker exec "$CONTAINER_NAME" grep -q 'executed block height=' "$DAEMON_HOME/cosmovisor.log"; then
    echo "✅ Cosmovisor is syncing blocks. Startup successful."
    break 2
  fi

  echo "⏳ Still waiting for block sync... ($k/$CHECK_RETRIES)"
  sleep "$SLEEP_INTERVAL"
done

if [ "$k" -gt "$CHECK_RETRIES" ]; then
  echo "❌ Cosmovisor did not show block execution after $CHECK_RETRIES attempts."
  docker exec "$CONTAINER_NAME" tail -n 100 "$DAEMON_HOME/cosmovisor.log"
  exit 1
fi

# ✅ Tail logs
echo "📜 Tailing Cosmovisor log..."
docker exec -it "$CONTAINER_NAME" tail -n 50 -f "$DAEMON_HOME/cosmovisor.log"

exit 0