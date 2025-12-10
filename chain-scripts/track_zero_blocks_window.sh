#!/usr/bin/env bash
set -euo pipefail

RPC="http://localhost:26657"
WINDOW=5000  # how many blocks back from the tip to scan

echo "[INFO] Detecting validator consensus address from /status ..."
CONS_ADDR=$(curl -s "$RPC/status" | jq -r '.result.validator_info.address // empty')

if [[ -z "$CONS_ADDR" || "$CONS_ADDR" == "null" ]]; then
  echo "[ERROR] Could not determine validator_info.address from $RPC/status"
  exit 1
fi

echo "[INFO] Validator address: $CONS_ADDR"

# Get latest height
LATEST=$(curl -s "$RPC/status" | jq -r '.result.sync_info.latest_block_height // "0"')
if ! [[ "$LATEST" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] Non-numeric latest_block_height: $LATEST"
  exit 1
fi

# Compute window start
START=$(( LATEST - WINDOW + 1 ))
if (( START < 1 )); then
  START=1
fi

echo "[INFO] Scanning from height $START to $LATEST (window=$WINDOW)"
echo

total_zero_blocks=0
you_missed_zero=0
high_miss_zero_blocks=0   # blocks where missed_validators > 9

for (( h=START; h<=LATEST; h++ )); do
  # Only check heights ending with 0
  if (( h % 10 != 0 )); then
    continue
  fi

  commit_json=$(curl -sf "$RPC/commit?height=$h" 2>/dev/null || echo "")
  if [[ -z "$commit_json" ]]; then
    echo "[WARN] Could not fetch commit for height=$h"
    continue
  fi

  ts=$(echo "$commit_json" | jq -r '.result.signed_header.header.time // "unknown"')

  # Did YOU sign this block?
  if echo "$commit_json" | jq -e --arg ADDR "$CONS_ADDR" \
      '.result.signed_header.commit.signatures[]
       | select(.block_id_flag == 2 and .validator_address == $ADDR)' \
      >/dev/null 2>&1; then
    you_signed="yes"
  else
    you_signed="no"
  fi

  # Addresses of all signers (block_id_flag=2)
  signed_addrs=$(echo "$commit_json" | jq \
    '[.result.signed_header.commit.signatures[]
      | select(.block_id_flag == 2)
      | .validator_address]')

  # Full validator set
  vals_json=$(curl -sf "$RPC/validators?height=$h&per_page=300" 2>/dev/null || echo "")
  if [[ -z "$vals_json" ]]; then
    echo "[WARN] Could not fetch validators for height=$h"
    continue
  fi


  all_addrs=$(echo "$vals_json" | jq '[.result.validators[].address]')

  # How many validators missed this block?
  missed_count=$(jq -n --argjson signed "$signed_addrs" --argjson all "$all_addrs" '
    ($all - $signed) | length
  ')

  total_zero_blocks=$(( total_zero_blocks + 1 ))
  if [[ "$you_signed" == "no" ]]; then
    you_missed_zero=$(( you_missed_zero + 1 ))
    status="MISS"
  else
    status="OK"
  fi

  # Only report and tally blocks where > 9 validators missed
  if (( missed_count > 9 )); then
    high_miss_zero_blocks=$(( high_miss_zero_blocks + 1 ))
    echo "[$status] height=$h ts=$ts you_signed=$you_signed missed_validators=$missed_count"
  fi
done

echo
echo "===== SUMMARY (last $WINDOW blocks) ====="
echo "Zero-ending blocks checked                    : $total_zero_blocks"
echo "You missed zero-ending blocks                 : $you_missed_zero"
echo "Zero-ending blocks with >9 misses (others)    : $high_miss_zero_blocks"
if (( total_zero_blocks > 0 )); then
  pct=$(( 100 * (total_zero_blocks - you_missed_zero) / total_zero_blocks ))
  echo "Your zero-ending block signing rate           : ${pct}%"
fi
