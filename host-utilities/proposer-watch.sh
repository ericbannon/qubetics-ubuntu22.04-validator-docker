#!/usr/bin/env bash
set -euo pipefail

# --- config ---
HOME_DIR="/mnt/nvme/qubetics"     # your node home
SLEEP_SECS=5                      # poll interval
STATE_FILE="/tmp/proposer_last_height"
# -------------

CONS_ADDR="$(qubeticsd tendermint show-address --home "$HOME_DIR")"
echo "Watching proposer for consensus addr: $CONS_ADDR  (Ctrl+C to stop)"

# Helper: print a notification (stdout + syslog + optional wall)
notify() {
  local msg="$1"
  echo "$msg"
  command -v logger >/dev/null 2>&1 && logger -t proposer-watch "$msg"
  command -v wall   >/dev/null 2>&1 && echo "$msg" | wall >/dev/null 2>&1 || true
}

# Helper: robust JSON field extract; falls back to grep if jq missing
# Args: stdin, jq_filter, [grep_key]
get_json_field() {
  local filter="${2:-}" key="${3:-}" out=""
  if command -v jq >/dev/null 2>&1; then
    out="$(jq -r "$filter // empty" 2>/dev/null || true)"
    [[ -n "$out" && "$out" != "null" ]] && { printf '%s' "$out"; return 0; }
  fi
  if [[ -n "$key" ]]; then
    out="$(grep -m1 -E "^[[:space:]]*$key[[:space:]]" | awk '{print $2}' || true)"
    printf '%s' "$out"
  fi
}

# Initialize last notified height
LAST_NOTIFIED="$(cat "$STATE_FILE" 2>/dev/null || true)"

while true; do
  # 1) Get the latest block (JSON or YAML depending on your build)
  BLK_OUT="$(qubeticsd query block || true)"
  H="$(printf '%s' "$BLK_OUT" | get_json_field '.block.header.height' 'height:')"
  [[ -z "$H" ]] && { echo "waiting for height…"; sleep "$SLEEP_SECS"; continue; }

  # 2) Get proposer address for that height
  PROP_OUT="$(qubeticsd query block "$H" || true)"
  PROP="$(printf '%s' "$PROP_OUT" | get_json_field '.block.header.proposer_address' 'proposer_address:')"
  [[ -z "$PROP" ]] && { echo "waiting for proposer…"; sleep "$SLEEP_SECS"; continue; }

  if [[ "$PROP" == "$CONS_ADDR" ]]; then
    if [[ "$H" != "$LAST_NOTIFIED" ]]; then
      notify "🚀 You proposed block $H (proposer=$PROP)"
      echo "$H" > "$STATE_FILE"
      LAST_NOTIFIED="$H"
    else
      echo "Already alerted for block $H (you were proposer)."
    fi
  else
    echo "Block $H proposed by $PROP"
  fi

  sleep "$SLEEP_SECS"
done
