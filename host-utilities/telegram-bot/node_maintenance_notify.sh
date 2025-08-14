#!/usr/bin/env bash
set -euo pipefail

# --- Telegram from .env ONLY ---
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
if [ -f "/home/admin/scripts/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "/home/admin/scripts/.env"
  set +a
fi
: "${TELEGRAM_BOT_TOKEN:?Missing TELEGRAM_BOT_TOKEN in /home/admin/scripts/.env or env}"
: "${TELEGRAM_CHAT_ID:?Missing TELEGRAM_CHAT_ID in /home/admin/scripts/.env or env}"

# --- Fixed config (per your request) ---
NODE_RPC="http://localhost:26657"
DAEMON_HOME="/mnt/nvme/qubetics"
DOCKER_NAME="validator-node"
VALIDATOR_ADDR="qubeticsvaloper18llj8eqh9k9mznylk8svrcc63ucf7y2r4xkd8l"
WALLET_ADDR="<redacted>"
VALCONS_ADDR="qubeticsvalcons1jpprhtglnlp7f65m526h5rlpf69z0k09254veh"
NODE_NAME="Block Dock Validator"

# Health check tuning
MAX_WAIT_TIME=${MAX_WAIT_TIME:-300}   # seconds
CHECK_INTERVAL=${CHECK_INTERVAL:-5}   # seconds

send_telegram() {
  local msg="$1"
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode="Markdown" \
    --data-urlencode text="$msg" > /dev/null || true
}

# Best-effort node snapshot (won't fail the script)
snapshot_status() {
  local peers="n/a" height="n/a" catching="n/a"
  if curl -fsS "${NODE_RPC}/net_info" -o /tmp/ni.json 2>/dev/null; then
    peers=$(jq '.result.peers | length' /tmp/ni.json 2>/dev/null || echo "n/a")
  fi
  if curl -fsS "${NODE_RPC}/status" -o /tmp/st.json 2>/dev/null; then
    height=$(jq -r '.result.sync_info.latest_block_height' /tmp/st.json 2>/dev/null || echo "n/a")
    catching=$(jq -r '.result.sync_info.catching_up' /tmp/st.json 2>/dev/null || echo "n/a")
  fi
  echo "Peers: ${peers} | Height: ${height} | CatchingUp: ${catching}"
}

wait_for_docker() {
  local tries=0
  until docker info >/dev/null 2>&1 || [ $tries -ge 30 ]; do
    sleep 2; tries=$((tries+1))
  done
}

boot_flow() {
  wait_for_docker

  send_telegram "⚙️ *${NODE_NAME} - Node Maintenance Notice*

🔄 Rebooting node container: \`${NODE_NAME}\`
📦 Applying updates / restart sequence...
⏱️ Expected downtime: *~2–5 minutes*

No action needed. Your funds are safe 🛡️"

  if ! docker inspect "$DOCKER_NAME" >/dev/null 2>&1; then
    send_telegram "❌ *${NODE_NAME} Maintenance Error*

Container \`${DOCKER_NAME}\` not found.
Please verify the container name in the script."
    exit 1
  fi

  # Wait for healthy/running
  local elapsed=0 status="unknown"
  while (( elapsed < MAX_WAIT_TIME )); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "$DOCKER_NAME" 2>/dev/null || echo "")"
    if [[ -z "$status" || "$status" == "<no value>" ]]; then
      status="$(docker inspect -f '{{.State.Status}}' "$DOCKER_NAME" 2>/dev/null || echo "")"
      [[ "$status" == "running" ]] && break
    fi
    [[ "$status" == "healthy" ]] && break
    sleep "$CHECK_INTERVAL"
    (( elapsed += CHECK_INTERVAL ))
  done

  if [[ "$status" == "healthy" || "$status" == "running" ]]; then
    send_telegram "✅ *${NODE_NAME} is Back Online*

Container \`${DOCKER_NAME}\` is *running and healthy* 🟢
$(snapshot_status)

Thank you for your trust 🙌"
  else
    send_telegram "❌ *${NODE_NAME} Restart Warning*

Container \`${DOCKER_NAME}\` failed to reach a healthy state after *${MAX_WAIT_TIME}s*.
Check logs and validator sync manually.

🔍 Use: \`docker logs ${DOCKER_NAME}\`"
    exit 2
  fi
}

pre_shutdown_flow() {
  # Best effort: send an “about to stop” notice *before* services go down
  send_telegram "🛠️ *${NODE_NAME} - Pre-shutdown Notice*

The validator node is going offline for a planned reboot/maintenance.
$(snapshot_status)

We’ll notify once it’s back online. 🔄"
}

# --- Entry point ---
case "${1:-}" in
  --pre-shutdown) pre_shutdown_flow ;;
  ""|--boot)      boot_flow ;;
  *) echo "Usage: $0 [--pre-shutdown|--boot]"; exit 64 ;;
esac
