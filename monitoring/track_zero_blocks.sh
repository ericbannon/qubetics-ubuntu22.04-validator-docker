#!/usr/bin/env bash
set -euo pipefail

RPC="${RPC:-http://localhost:26657}"
DURATION=$((6 * 3600))   # 6 hours
SLEEP=5

echo "[INFO] RPC = $RPC"
echo "[INFO] Monitoring ONLY blocks where height % 10 == 0"
echo "[INFO] Duration = $DURATION seconds"
echo

# Detect consensus address
if [[ -z "${CONS_ADDR:-}" ]]; then
  CONS_ADDR=$(curl -s "$RPC/status" | jq -r '.result.validator_info.address')
fi

if [[ -z "$CONS_ADDR" || "$CONS_ADDR" == "null" ]]; then
  echo "[ERROR] Could not detect validator consensus address!"
  exit 1
fi

echo "[INFO] Validator address: $CONS_ADDR"
echo

start_time=$(date +%s)

# Start from the next block
latest=$(curl -s "$RPC/status" | jq -r '.result.sync_info.latest_block_height | tonumber')
next=$((latest + 1))

checked=0
missed_self=0

while true; do
  now=$(date +%s)
  if (( now - start_time >= DURATION )); then
    echo
    echo "===== DONE (6 HOURS) ====="
    echo "Zero-ending blocks checked:      $checked"
    echo "Zero-ending blocks YOU missed:   $missed_self"
    exit 0
  fi

  latest=$(curl -s "$RPC/status" | jq -r '.result.sync_info.latest_block_height | tonumber')

  while (( next <= latest )); do
    h=$next
    next=$((next + 1))

    # Only care about blocks ending in 0
    if (( h % 10 != 0 )); then
      continue
    fi

    checked=$((checked + 1))

    commit=$(curl -s "$RPC/commit?height=$h")

    ts=$(echo "$commit" | jq -r '.result.signed_header.header.time // "unknown"')

    # Did *you* sign?
    signed=$(echo "$commit" \
      | jq --arg A "$CONS_ADDR" \
        '[.result.signed_header.commit.signatures[]
          | select(.validator_address == $A and .block_id_flag == 2)] | length')

    # How many validators in total missed?
    # block_id_flag != 2 => absent or nil vote
    total_missed=$(echo "$commit" \
      | jq '[.result.signed_header.commit.signatures[]
             | select(.block_id_flag != 2)] | length')

    if [[ "$signed" == "0" ]]; then
      missed_self=$((missed_self + 1))
      echo "[MISS] height=$h ts=$ts — YOU did NOT sign (self_miss $missed_self / $checked) | missed_validators=$total_missed"
    else
      echo "[OK]   height=$h ts=$ts — you signed | missed_validators=$total_missed"
    fi

    # Light summary every 50 zero-ending blocks
    if (( checked % 50 == 0 )); then
      echo "[SUMMARY] checked_zero=$checked | your_misses=$missed_self (last_height=$h, last_missed_validators=$total_missed)"
    fi
  done

  sleep $SLEEP
done
