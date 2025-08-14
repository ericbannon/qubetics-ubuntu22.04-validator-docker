#!/bin/bash
# Block Dock Validator Health Reporter (signing-infos counter)
# Silent cron example (every 10 min):
# */10 * * * * /bin/bash /home/admin/scripts/blockdock_updater.sh >/dev/null 2>&1

set -o pipefail

# === CONFIG ===
NODE_RPC="http://localhost:26657"
DAEMON_HOME="/mnt/nvme/qubetics"
DOCKER_NAME="validator-node"

VALIDATOR_ADDR="qubeticsvaloper18llj8eqh9k9mznylk8svrcc63ucf7y2r4xkd8l"
WALLET_ADDR="qubetics18llj8eqh9k9mznylk8svrcc63ucf7y2rkyqm2m"

# Your known valcons (used if we can't auto-resolve)
VALCONS_ADDR="qubeticsvalcons1jpprhtglnlp7f65m526h5rlpf69z0k09254veh"

ALERT_FILE="/tmp/qubetics_last_alert"
LOG_FILE="${LOG_FILE:-/home/admin/scripts/blockdock_updater.log}"

# Telegram from .env (recommended)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# === Load .env if present ===
if [ -f "/home/admin/scripts/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "/home/admin/scripts/.env"
  set +a
fi

# Ensure log path (fallback if needed)
mkdir -p "$(dirname "$LOG_FILE")" || true
if ! touch "$LOG_FILE" 2>/dev/null; then
  LOG_FILE="$HOME/.local/state/blockdock/updates.log"
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE" || { echo "cannot write $LOG_FILE"; exit 1; }
fi

# === Quiet mode: only print on failure ===
: "${QUIET:=1}"
if [ "$QUIET" = "1" ]; then
  _TMP_OUT="$(mktemp)"
  exec 5>&1 6>&2
  exec >"$_TMP_OUT" 2>&1
  _on_exit() {
    s=$?
    if [ $s -ne 0 ]; then
      echo "❌ blockdock_updater.sh failed (exit $s)" >&5
      cat "$_TMP_OUT" >&5
    fi
    rm -f "$_TMP_OUT"
    exit $s
  }
  trap _on_exit EXIT
fi

# === Helpers ===
run_q() { docker exec -i "$DOCKER_NAME" qubeticsd "$@"; }
log()  { echo "$(date +'%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }
fmt_pct()  { awk 'BEGIN{printf "%.2f",('"${1:-0}"')}'; }
fmt_tics() { awk 'BEGIN{printf "%.3f",('"${1:-0}"')}'; }

send_telegram_alert() {
  local msg="$1"
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log "❌ TELEGRAM_* env not set"
    echo "Telegram env not set" >&2
    return 1
  fi
  local resp body code
  resp=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
           -d chat_id="$TELEGRAM_CHAT_ID" -d parse_mode="Markdown" --data-urlencode text="$msg")
  body=$(echo "$resp" | sed -e 's/HTTP_STATUS\:.*//g')
  code=$(echo "$resp" | tr -d '\n' | sed -e 's/.*HTTP_STATUS://')
  if [ "$code" != "200" ]; then
    log "❌ Telegram send failed ($code): $body"
    echo "❌ Telegram send failed ($code): $body" >&2
    return 1
  fi
  log "✅ Telegram message sent."
}

# === Start ===
log "🔍 Starting validator health check..."

# Node status
status="$(curl -s "$NODE_RPC/status")"
if [ -z "$status" ] || [ "$status" = "null" ]; then
  log "❌ Node RPC empty"
  send_telegram_alert "❌ *Node is unreachable* at $(date)" || true
  exit 1
fi
catching_up=$(echo "$status"  | jq -r .result.sync_info.catching_up)
latest_block=$(echo "$status" | jq -r .result.sync_info.latest_block_height)
latest_time=$(echo "$status"  | jq -r .result.sync_info.latest_block_time)

sync_status="✅ *Node is synced*"
[ "$catching_up" = "true" ] && sync_status="⏳ *Node is catching up*"

# Peers
net_info="$(curl -s "$NODE_RPC/net_info")"
inbound_peers=$(echo "$net_info" | jq '[.result.peers[]? | select(.is_outbound==false)] | length')

# Validator info
val_info="$(run_q query staking validator "$VALIDATOR_ADDR" --node="$NODE_RPC" -o json 2>/dev/null)"
if [ -z "$val_info" ] || [ "$val_info" = "null" ]; then
  log "❌ validator info fetch failed"
  send_telegram_alert "❌ *Validator info fetch failed* at $(date)" || true
  exit 1
fi
is_jailed=$(echo "$val_info" | jq -r .jailed)
[ "$is_jailed" = "true" ] && jailed_status="🚨 *Validator is JAILED*" || jailed_status="🟢 *Validator is ACTIVE*"

commission=$(echo "$val_info" | jq -r .commission.commission_rates.rate)
commission_pct=$(fmt_pct "$(bc -l <<< "$commission * 100")")

# Delegators & total stake
delegations_json="$(run_q query staking delegations-to "$VALIDATOR_ADDR" --node="$NODE_RPC" --count-total -o json 2>/dev/null)"
delegator_total=$(echo "$delegations_json" | jq -r '.pagination.total // "0"')
if [[ "$delegator_total" =~ ^[0-9]+$ && "$delegator_total" -gt 0 ]]; then
  delegator_count="$delegator_total"
else
  delegator_count=$(echo "$delegations_json" | jq -r '.delegation_responses | length')
fi

val_tokens_raw=$(echo "$val_info" | jq -r '.tokens // "0"')
total_stake_tics=$(bc <<< "scale=6; $val_tokens_raw / 1000000000000000000")
total_stake_tics_fmt=$(fmt_tics "$total_stake_tics")

# Self-delegation
self_delegation=$(run_q query staking delegation "$WALLET_ADDR" "$VALIDATOR_ADDR" --node="$NODE_RPC" --home="$DAEMON_HOME" -o json 2>/dev/null \
  | jq -r '.balance.amount // "0"')
self_tics=$(fmt_tics "$(bc -l <<< "$self_delegation / 1000000000000000000")")

# === Missed blocks via signing-infos (your request) ===
# Try to auto-resolve valcons; if not, use your provided VALCONS_ADDR
cons_addr_b32="$(run_q tendermint show-address --home "$DAEMON_HOME" 2>/dev/null || true)"
target_addr="${cons_addr_b32:-$VALCONS_ADDR}"

missed_blocks=$(
  run_q query slashing signing-infos --node="$NODE_RPC" -o json \
  | jq -r --arg V "$target_addr" '.info[]? | select((.address // .cons_address // "") == $V) | .missed_blocks_counter // empty'
)
[ -z "$missed_blocks" ] && missed_blocks="N/A"

# Uptime (window-based) if counter is numeric
uptime_pct="N/A"
if [[ "$missed_blocks" =~ ^[0-9]+$ ]]; then
  signed_window=$(run_q query slashing params --node="$NODE_RPC" -o json | jq -r '.signed_blocks_window // 0')
  if [[ "$signed_window" =~ ^[0-9]+$ && "$signed_window" -gt 0 ]]; then
    uptime_pct=$(awk -v m="$missed_blocks" -v w="$signed_window" 'BEGIN{printf "%.2f", (w-m)/w*100}')
  fi
fi

# Message
msg="📡 *Block Dock Validator Node Health Check (every 10 minutes)*
$jailed_status
$sync_status
🧱 Latest block: *$latest_block*
🕒 Block time: \`$latest_time\`
🔌 Inbound peers: *$inbound_peers*
👥 Delegators: *$delegator_count*
💎 Total stake (validator): *$total_stake_tics_fmt TICS*
📈 Uptime (window-based): *${uptime_pct}%*
💰 Commission rate: *${commission_pct}%*
🪙 Self-delegated: *$self_tics TICS*
📉 Missed blocks: *$missed_blocks*
📅 Updated: \`$(TZ=America/Denver date)\`"

# De-dupe + send
new_hash=$(echo "$msg" | md5sum | awk '{print $1}')
prev_hash=$(cat "$ALERT_FILE" 2>/dev/null || true)

if [ "$new_hash" != "$prev_hash" ]; then
  if ! send_telegram_alert "$msg"; then
    exit 1
  fi
  echo "$new_hash" > "$ALERT_FILE"
else
  log "ℹ️ No change in status — no alert sent."
fi

exit 0

