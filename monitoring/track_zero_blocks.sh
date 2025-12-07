#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
RPC="http://localhost:26657"
RUN_SECONDS=$((6 * 3600))   # 6 hours
SLEEP_SECS=1                # how often to poll latest height
LOG_FILE="${HOME}/missed_zero_blocks_$(date -u +%Y%m%dT%H%M%SZ).log"

echo "=== Zero-ending block miss tracker ==="
echo "RPC endpoint: $RPC"
echo "Duration: $((RUN_SECONDS / 3600)) hours"
echo "Log file: $LOG_FILE"
echo

# --- Get our consensus address ---
echo "Detecting validator consensus address from $RPC/status ..."
MY_ADDR=$(curl -s "$RPC/status" | jq -r '.result.validator_info.address // empty')

if [[ -z "$MY_ADDR" || "$MY_ADDR" == "null" ]]; then
  echo "ERROR: Could not determine validator_info.address from /status"
  echo "Make sure this node is a validator and RPC is correct."
  exit 1
fi

echo "Validator consensus address: $MY_ADDR"
echo

# --- Initial chain height ---
LATEST_STR=$(curl -s "$RPC/status" | jq -r '.result.sync_info.latest_block_height // "0"')
if ! [[ "$LATEST_STR" =~ ^[0-9]+$ ]]; then
  echo "ERROR: latest_block_height is not numeric: $LATEST_STR"
  exit 1
fi

LAST_HEIGHT=$LATEST_STR
echo "Starting at height: $LAST_HEIGHT"
echo

START_TS=$(date +%s)
END_TS=$((START_TS + RUN_SECONDS))

checked_zero_blocks=0
missed_zero_blocks=0
signed_zero_blocks=0

echo "Tracking… (Ctrl+C to stop early)"
echo "-----------------------------------------"

while :; do
  now_ts=$(date +%s)
  if (( now_ts >= END_TS )); then
    echo
    echo "Reached 6-hour limit, exiting loop."
    break
  fi

  # Get current chain height
  LATEST_STR=$(curl -s "$RPC/status" | jq -r '.result.sync_info.latest_block_height // "0"' || echo "0")

  if ! [[ "$LATEST_STR" =~ ^[0-9]+$ ]]; then
    echo "WARN: Non-numeric latest_block_height: $LATEST_STR (skipping iteration)"
    sleep "$SLEEP_SECS"
    continue
  fi

  CUR_HEIGHT=$LATEST_STR

  if (( CUR_HEIGHT <= LAST_HEIGHT )); then
    sleep "$SLEEP_SECS"
    continue
  fi

  # Process new heights between LAST_HEIGHT+1 and CUR_HEIGHT
  for (( h = LAST_HEIGHT + 1; h <= CUR_HEIGHT; h++ )); do
    # Only care about heights ending in 0
    if (( h % 10 != 0 )); then
      continue
    fi

    # Pull the block and see if our validator signed the last_commit
    BLOCK_JSON=$(curl -s "$RPC/block?height=$h" || echo "")
    if [[ -z "$BLOCK_JSON" ]]; then
      echo "WARN: Failed to fetch block $h"
      continue
    fi

    checked_zero_blocks=$((checked_zero_blocks + 1))

    # Extract all validator_address values from last_commit signatures
    if echo "$BLOCK_JSON" \
        | jq -r '.result.block.last_commit.signatures[].validator_address // empty' \
        | grep -q "$MY_ADDR"; then
      signed_zero_blocks=$((signed_zero_blocks + 1))
      status="SIGNED"
    else
      missed_zero_blocks=$((missed_zero_blocks + 1))
      status="MISSED"
    fi

    msg="$(date -u +%Y-%m-%dT%H:%M:%SZ) height=$h ends_with_0 status=$status total_checked=$checked_zero_blocks signed=$signed_zero_blocks missed=$missed_zero_blocks"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
  done

  LAST_HEIGHT=$CUR_HEIGHT
  sleep "$SLEEP_SECS"
done

echo
echo "========== FINAL SUMMARY =========="
echo "Time window: $(date -d @"$START_TS" -u +%Y-%m-%dT%H:%M:%SZ) to $(date -d @"$END_TS" -u +%Y-%m-%dT%H:%M:%SZ) (UTC)"
echo "Validator address: $MY_ADDR"
echo "Zero-ending blocks checked: $checked_zero_blocks"
echo "Zero-ending blocks SIGNED:  $signed_zero_blocks"
echo "Zero-ending blocks MISSED:  $missed_zero_blocks"
echo "Log file: $LOG_FILE"
echo "==================================="
