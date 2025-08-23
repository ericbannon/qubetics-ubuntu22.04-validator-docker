#!/usr/bin/env bash
set -euo pipefail

# --- Load Telegram env: prefer /etc/default, fallback to local .env ---
if [ -r /etc/default/telegram.env ]; then
  set -a; . /etc/default/telegram.env; set +a
elif [ -r /home/admin/scripts/.env ]; then
  set -a; . /home/admin/scripts/.env; set +a
fi
: "${TELEGRAM_BOT_TOKEN:?Missing TELEGRAM_BOT_TOKEN in env}"
: "${TELEGRAM_CHAT_ID:?Missing TELEGRAM_CHAT_ID in env}"

# --- Fixed config (yours) ---
NODE_RPC="http://localhost:26657"
DAEMON_HOME="/mnt/nvme/qubetics"
DOCKER_NAME="validator-node"
VALIDATOR_ADDR="qubeticsvaloper18llj8eqh9k9mznylk8svrcc63ucf7y2r4xkd8l"
WALLET_ADDR="<redacted>"
VALCONS_ADDR="qubeticsvalcons1jpprhtglnlp7f65m526h5rlpf69z0k09254veh"
NODE_NAME="Block Dock Validator"

# Health check tuning
MAX_WAIT_TIME=${MAX_WAIT_TIME:-300}   # secs for container to become healthy/running
CHECK_INTERVAL=${CHECK_INTERVAL:-5}   # secs between checks
ETA_SECONDS=${ETA_SECONDS:-90}        # wait after container ready before expecting blocks
SYNC_DEADLINE=${SYNC_DEADLINE:-420}   # extra time to confirm block movement

send_telegram() {
  local msg="$1"
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode="Markdown" \
    --data-urlencode text="$msg" >/dev/null || true
}

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

get_height()   { curl -fsS "${NODE_RPC}/status" 2>/dev/null | jq -r '.result.sync_info.latest_block_height' 2>/dev/null || echo ""; }
get_catching() { curl -fsS "${NODE_RPC}/status" 2>/dev/null | jq -r '.result.sync_info.catching_up'        2>/dev/null || echo ""; }
get_peers()    { curl -fsS "${NODE_RPC}/net_info" 2>/dev/null | jq -r '.result.peers | length'              2>/dev/null || echo ""; }

wait_for_docker() {
  local tries=0
  until docker info >/dev/null 2>&1 || [ $tries -ge 30 ]; do
    sleep 2; tries=$((tries+1))
  done
}

# Wait until we observe block movement (height increases twice)
wait_for_block_progress() {
  local deadline_secs="$1"
  local start_height="$(get_height)"
  [[ -z "$start_height" || "$start_height" == "null" ]] && start_height=0

  local waited=0
  local last_height="$start_height"
  while (( waited < deadline_secs )); do
    sleep "$CHECK_INTERVAL"
    waited=$((waited + CHECK_INTERVAL))
    local h="$(get_height)"
    [[ -z "$h" || "$h" == "null" ]] && continue
    if [[ "$h" =~ ^[0-9]+$ ]] && (( h > last_height )); then
      sleep "$CHECK_INTERVAL"
      local h2="$(get_height)"; [[ -z "$h2" || "$h2" == "null" ]] && h2="$h"
      if [[ "$h2" =~ ^[0-9]+$ ]] && (( h2 > h )); then
        echo "$h2"; return 0
      fi
      last_height="$h"
    fi
  done
  echo "$last_height"; return 1
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

  # Wait for container to be running/healthy
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

  if [[ "$status" != "healthy" && "$status" != "running" ]]; then
    send_telegram "❌ *${NODE_NAME} Restart Warning*

Container \`${DOCKER_NAME}\` failed to reach a healthy state after *${MAX_WAIT_TIME}s*.
Check logs and validator sync manually.

🔍 Use: \`docker logs ${DOCKER_NAME}\`"
    exit 2
  fi

  local peers_now="$(get_peers)";   [[ -z "$peers_now"   || "$peers_now"   == "null" ]] && peers_now="n/a"
  local height_now="$(get_height)"; [[ -z "$height_now" || "$height_now" == "null" ]] && height_now="n/a"
  send_telegram "✅ *${NODE_NAME} is Back Online*

Container \`${DOCKER_NAME}\` is *running* 🟢
${NODE_NAME} is starting *Cosmovisor*.
⏳ *ETA ~${ETA_SECONDS}s* before blocks begin writing…

$(snapshot_status)
"

  sleep "$ETA_SECONDS"

  local final_height
  if final_height="$(wait_for_block_progress "$SYNC_DEADLINE")"; then
    local catching="$(get_catching)"
    local peers="$(get_peers)"
    send_telegram "🟢 *${NODE_NAME} is Writing Blocks Again*

Height: *${final_height}*  |  Peers: *${peers:-n/a}*  |  CatchingUp: *${catching:-n/a}*

All systems nominal. 🚀"
  else
    send_telegram "⚠️ *${NODE_NAME} Post‑Start Check*

Cosmovisor started *${ETA_SECONDS}s* ago, but block movement was not confirmed within *${SYNC_DEADLINE}s*.

$(snapshot_status)

Please check logs:
\`docker logs ${DOCKER_NAME} --tail=200\`"
    exit 3
  fi
}

pre_shutdown_flow() {
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