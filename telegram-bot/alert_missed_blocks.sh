#!/usr/bin/env bash
set -o pipefail

# --- Telegram env (required) ---
if [ -r /etc/default/telegram.env ]; then
  set -a; . /etc/default/telegram.env; set +a
fi
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set}"

# Accept legacy TELEGRAM_CHAT_ID as "private" if provided
: "${TELEGRAM_CHAT_ID_PRIVATE:=${TELEGRAM_CHAT_ID:-}}"
: "${TELEGRAM_CHAT_ID_CHANNEL:=}"

# Build recipients list (must have at least one)
TELEGRAM_CHAT_IDS=()
[[ -n "$TELEGRAM_CHAT_ID_PRIVATE" ]] && TELEGRAM_CHAT_IDS+=("$TELEGRAM_CHAT_ID_PRIVATE")
[[ -n "$TELEGRAM_CHAT_ID_CHANNEL" ]] && TELEGRAM_CHAT_IDS+=("$TELEGRAM_CHAT_ID_CHANNEL")
if [[ ${#TELEGRAM_CHAT_IDS[@]} -eq 0 ]]; then
  echo "ERROR: set TELEGRAM_CHAT_ID_PRIVATE and/or TELEGRAM_CHAT_ID_CHANNEL in /etc/default/telegram.env" >&2
  exit 1
fi

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- Config ---
HOME_DIR="${HOME_DIR:-/mnt/nvme/qubetics}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"           # seconds between checks
DOCKER_NAME="${DOCKER_NAME:-validator-node}"     # container name
STATE_FILE="${STATE_FILE:-/var/tmp/qubetics_missed_state}"  # stores last counter seen

# --- Helpers (always exec inside Docker) ---
run_q() { docker exec -i "$DOCKER_NAME" qubeticsd "$@"; }

send_alert() {
  local message="$1"
  local resp code
  for chat in "${TELEGRAM_CHAT_IDS[@]}"; do
    resp=$(curl -s --connect-timeout 5 --max-time 10 \
           -w "\nHTTP_STATUS:%{http_code}" -X POST \
           "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
           -d chat_id="$chat" \
           -d parse_mode=Markdown \
           --data-urlencode text="$message")
    code=$(echo "$resp" | tr -d '\n' | sed -e 's/.*HTTP_STATUS://')
    if [ "$code" != "200" ]; then
      echo "[$(date)] Telegram send failed ($code) for chat $chat: ${resp%HTTP_STATUS:*}" >&2
    fi
  done
}

get_latest_height() {
  # Try RPC first (fast), fall back to CLI if needed
  local h
  h=$(curl -s --max-time 2 http://127.0.0.1:26657/status \
      | jq -r '.result.sync_info.latest_block_height' 2>/dev/null)
  if [[ -z "$h" || "$h" == "null" ]]; then
    # Kick the CLI once (ensures container/daemon is responsive), then retry RPC
    run_q status >/dev/null 2>&1
    h=$(curl -s --max-time 2 http://127.0.0.1:26657/status \
        | jq -r '.result.sync_info.latest_block_height' 2>/dev/null)
  fi
  echo "${h:-unknown}"
}

echo "[$(date)] missed-block height alert loop starting (interval=${CHECK_INTERVAL}s; docker=$DOCKER_NAME)"

# Initialize previous counter (if any)
prev_counter=""
[[ -r "$STATE_FILE" ]] && prev_counter="$(cat "$STATE_FILE" 2>/dev/null || true)"

while true; do
  # consensus address (bech32 or hex tolerated by CLI below)
  CONS_ADDR=$(run_q tendermint show-validator --home "$HOME_DIR" 2>/dev/null | tr -d '\r\n')
  if [ -z "$CONS_ADDR" ]; then
    echo "[$(date)] ERROR: could not get tendermint show-validator" >&2
    sleep "$CHECK_INTERVAL"; continue
  fi

  # current missed counter (only for change detection)
  CUR_COUNTER=$(
    run_q query slashing signing-info "$CONS_ADDR" \
      --home "$HOME_DIR" --output json 2>/dev/null \
    | jq -r '.missed_blocks_counter // empty'
  )

  if [[ -z "$CUR_COUNTER" || ! "$CUR_COUNTER" =~ ^[0-9]+$ ]]; then
    echo "[$(date)] WARN: missing/invalid missed counter (CONS_ADDR=$CONS_ADDR)" >&2
    sleep "$CHECK_INTERVAL"; continue
  fi

  # First run: just record and continue
  if [[ -z "$prev_counter" ]]; then
    echo "$CUR_COUNTER" > "$STATE_FILE"
    prev_counter="$CUR_COUNTER"
    echo "[$(date)] Initialized missed counter to $CUR_COUNTER"
    sleep "$CHECK_INTERVAL"; continue
  fi

  # If the counter increased, we likely missed one or more blocks; alert.
  if (( CUR_COUNTER > prev_counter )); then
    delta=$(( CUR_COUNTER - prev_counter ))
    height="$(get_latest_height)"
    when="$(TZ=America/Denver date)"
    msg="⚠️ *Qubetics Validator Missed Block*
Height (approx): *${height}*
Missed delta detected: *${delta}* block(s)
Time: \`${when}\`"
    send_alert "$msg"
    echo "[$(date)] Missed delta=$delta at ~height $height (prev=$prev_counter -> cur=$CUR_COUNTER)"
    echo "$CUR_COUNTER" > "$STATE_FILE"
    prev_counter="$CUR_COUNTER"
  fi

  sleep "$CHECK_INTERVAL"
done