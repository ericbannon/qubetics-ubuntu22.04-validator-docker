#!/usr/bin/env bash
set -o pipefail

# --- Telegram env (required) ---
if [ -r /etc/default/telegram.env ]; then
  set -a; . /etc/default/telegram.env; set +a
fi
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set}"
: "${TELEGRAM_CHAT_ID_PRIVATE:?TELEGRAM_CHAT_ID_PRIVATE not set}"

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- Config ---
RPC="${RPC:-http://127.0.0.1:26657}"         # Tendermint RPC reachable from host
SCAN_RANGE="${SCAN_RANGE:-300}"              # how many recent blocks to scan each loop
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"       # seconds between scans
INCLUDE_NIL="${INCLUDE_NIL:-0}"              # set 1 to alert on NIL votes too
STATE_DIR="${STATE_DIR:-/var/tmp}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/qubetics_missed_byheight.state}"  # last scanned height
SEEN_FILE="${SEEN_FILE:-$STATE_DIR/qubetics_missed_seen.list}"        # list of heights already alerted

mkdir -p "$STATE_DIR"

# --- Telegram ---
send_alert() {
  local message="$1"
  local resp code body
  resp=$(curl -s --connect-timeout 5 --max-time 10 \
         -w "\nHTTP_STATUS:%{http_code}" -X POST \
         "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
         -d chat_id="$TELEGRAM_CHAT_ID_PRIVATE" \
         -d disable_web_page_preview=true \
         --data-urlencode text="$message")
  body=$(printf "%s" "$resp" | sed -e 's/HTTP_STATUS:.*//')
  code=$(printf "%s" "$resp" | tr -d '\n' | sed -e 's/.*HTTP_STATUS://')
  if [ "$code" != "200" ]; then
    echo "[$(date)] Telegram send failed ($code): $body" >&2
  fi
}

# --- Helpers ---
rpc_json() {
  # $1: path (e.g. /status or /commit?height=123)
  curl -s --connect-timeout 3 --max-time 6 "$RPC$1"
}

get_my_hex_upper() {
  rpc_json "/status" \
    | jq -r '.result.validator_info.address // empty' \
    | tr '[:lower:]' '[:upper:]'
}

get_latest_height() {
  rpc_json "/status" \
    | jq -r '.result.sync_info.latest_block_height // empty'
}

# Extract our commit flag at height H:
# returns: 2=COMMIT (ok), 1=ABSENT (miss), 3=NIL (no block id), or NA if not in set/unknown
get_flag_for_height() {
  local h="$1" my="$2"
  rpc_json "/commit?height=$h" \
    | jq -r --arg MY "$my" '
        .result.signed_header.commit.signatures
        | map(select((.validator_address|ascii_upcase)==$MY))[0].block_id_flag // "NA"
      ' 2>/dev/null
}

# --- Startup ---
echo "[$(date)] by-height missed-block alert loop starting (interval=${CHECK_INTERVAL}s; range=${SCAN_RANGE}; rpc=${RPC})"
send_alert "✅ Test: by-height missed-block alert running on $(hostname) at $(date)"

# Init seen file
touch "$SEEN_FILE"

# Load last scanned height if present (we'll still window by SCAN_RANGE)
LAST_SCANNED=0
if [[ -r "$STATE_FILE" ]]; then
  LAST_SCANNED=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  [[ "$LAST_SCANNED" =~ ^[0-9]+$ ]] || LAST_SCANNED=0
fi

# --- Main loop ---
while true; do
  MYHEXU="$(get_my_hex_upper)"
  if [ -z "$MYHEXU" ] || [ "$MYHEXU" = "null" ]; then
    echo "[$(date)] ERROR: could not determine validator hex address via /status" >&2
    sleep "$CHECK_INTERVAL"; continue
  fi

  LATEST="$(get_latest_height)"
  if ! [[ "$LATEST" =~ ^[0-9]+$ ]]; then
    echo "[$(date)] WARN: latest height unavailable" >&2
    sleep "$CHECK_INTERVAL"; continue
  fi

  # Determine scan window
  # Start at max(LAST_SCANNED+1, LATEST-SCAN_RANGE+1), never less than 1
  START=$(( LAST_SCANNED + 1 ))
  WINDOW_START=$(( LATEST - SCAN_RANGE + 1 ))
  (( WINDOW_START < 1 )) && WINDOW_START=1
  if (( START < WINDOW_START )); then
    START=$WINDOW_START
  fi
  if (( START > LATEST )); then
    # nothing new to scan
    sleep "$CHECK_INTERVAL"; continue
  fi

  new_misses=()   # collect fresh missed heights to alert on
  scanned_to=$START

  for (( h=START; h<=LATEST; h++ )); do
    scanned_to="$h"

    flag="$(get_flag_for_height "$h" "$MYHEXU")"
    # normalize unknown to NA
    [[ -z "$flag" || "$flag" == "null" ]] && flag="NA"

    case "$flag" in
      2) : ;;                    # COMMIT OK
      1)                         # ABSENT (missed)
         if ! grep -qx "$h" "$SEEN_FILE"; then
           new_misses+=("$h")
           echo "$h" >> "$SEEN_FILE"
         fi
         ;;
      3)                         # NIL (optional treat as miss)
         if [ "$INCLUDE_NIL" = "1" ]; then
           if ! grep -qx "$h" "$SEEN_FILE"; then
             new_misses+=("$h")
             echo "$h" >> "$SEEN_FILE"
           fi
         fi
         ;;
      *) : ;;                    # NOT_IN_SET / NA
    esac
  done

  # Persist last scanned height
  echo "$scanned_to" > "$STATE_FILE"
  LAST_SCANNED="$scanned_to"

  # Alert if we found new misses
  if [ "${#new_misses[@]}" -gt 0 ]; then
    count="${#new_misses[@]}"
    first="${new_misses[0]}"
    last="${new_misses[-1]}"
    # Show up to 10 specific heights, then summarize
    list_preview="$(printf "%s\n" "${new_misses[@]}" | head -n 10 | paste -sd ',')"
    more=$(( count - 10 ))
    more_str=""
    (( more > 0 )) && more_str=" …(+${more} more)"

    when="$(TZ=America/Denver date)"
    msg="⚠️ Qubetics Validator Missed Block(s)
Range scanned: ${START}-${LATEST}
New misses: *${count}*
Heights: ${list_preview}${more_str}
Time: ${when}"

    # send (plain text; if you want Markdown here, add parse_mode=Markdown and escape properly)
    send_alert "$msg"
    echo "[$(date)] Alerted ${count} new misses; range ${START}-${LATEST}; first=$first last=$last"
  fi

  sleep "$CHECK_INTERVAL"
done