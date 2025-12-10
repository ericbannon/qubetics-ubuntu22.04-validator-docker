#!/usr/bin/env bash
set -euo pipefail


# ============================================================
# Giant-miss pattern analyzer (Tendermint/CometBFT RPC only)
#
# - Uses ONLY:
#     /status
#     /commit?height=H
#     /validators?height=H&per_page=300
#
# - Detects "giant-miss" blocks:
#     missed_total >= THRESH (default: 18)
#
# - Analyzes spacing between these blocks and highlights
#   blocks whose height ends in 0.
# ============================================================

RPC="${RPC:-http://localhost:26657}"   # Tendermint RPC endpoint
WINDOW="${WINDOW:-20000}"              # how many blocks back from tip to scan
THRESH="${THRESH:-18}"                # giant-miss threshold (missed_total >= THRESH)

echo "[INFO] RPC: $RPC"
echo "[INFO] Window: last $WINDOW blocks"
echo "[INFO] Giant-miss threshold: missed_total >= $THRESH"
echo

# ------------------------------------------------------------
# Discover latest height
# ------------------------------------------------------------
status_json=$(curl -sf "$RPC/status" 2>/dev/null || true)
if [[ -z "$status_json" ]]; then
  echo "[ERROR] Could not fetch $RPC/status"
  exit 1
fi

LATEST=$(echo "$status_json" | jq -r '.result.sync_info.latest_block_height // "0"')
if ! [[ "$LATEST" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] Non-numeric latest_block_height: $LATEST"
  exit 1
fi

START=$(( LATEST - WINDOW + 1 ))
if (( START < 1 )); then
  START=1
fi

echo "[INFO] Scanning heights $START .. $LATEST"
echo

TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

# Header for giant-miss table
printf "height,timestamp,valset_size,missed_total,miss_pct,ends_in_zero\n" > "$TMP_FILE"

# ------------------------------------------------------------
# Main scan loop
# ------------------------------------------------------------
for (( h=START; h<=LATEST; h++ )); do
  # Fetch commit
  commit_json=$(curl -sf "$RPC/commit?height=$h" 2>/dev/null || true)
  if [[ -z "$commit_json" ]]; then
    echo "[WARN] Could not fetch /commit?height=$h"
    continue
  fi

  ts=$(echo "$commit_json" | jq -r '.result.signed_header.header.time // "unknown"')

  # Signers (block_id_flag == 2)
  signed_addrs=$(echo "$commit_json" | jq \
    '[.result.signed_header.commit.signatures[]
      | select(.block_id_flag == 2)
      | .validator_address]')

  # Fetch validators at this height
  vals_json=$(curl -sf "$RPC/validators?height=$h&per_page=300" 2>/dev/null || true)
  if [[ -z "$vals_json" ]]; then
    echo "[WARN] Could not fetch /validators?height=$h"
    continue
  fi

  all_addrs=$(echo "$vals_json" | jq '[.result.validators[].address]')
  valset_size=$(echo "$all_addrs" | jq 'length')

  # Compute how many missed (set difference: all - signed)
  missed_total=$(jq -n --argjson signed "$signed_addrs" --argjson all "$all_addrs" '
    ($all - $signed) | length
  ')

  # Only care about giant misses
  if (( missed_total < THRESH )); then
    continue
  fi

  # percent of validators that missed (approx: by count, not voting power)
  if (( valset_size > 0 )); then
    miss_pct=$(( 100 * missed_total / valset_size ))
  else
    miss_pct=0
  fi

  # ends in zero?
  if (( h % 10 == 0 )); then
    ends_zero="yes"
  else
    ends_zero="no"
  fi

  printf "%d,%s,%d,%d,%d,%s\n" \
    "$h" "$ts" "$valset_size" "$missed_total" "$miss_pct" "$ends_zero" >> "$TMP_FILE"
done

echo
echo "===== GIANT-MISS BLOCKS (missed_total >= $THRESH) ====="
if [[ $(wc -l < "$TMP_FILE") -le 1 ]]; then
  echo "[INFO] No giant-miss blocks found in $START..$LATEST"
  exit 0
fi

# Pretty print table
column -t -s',' "$TMP_FILE"

# ------------------------------------------------------------
# Pattern / spacing analysis
# ------------------------------------------------------------
echo
echo "===== PATTERN ANALYSIS (spacing between giant-miss blocks) ====="

# Extract just the heights (skip header)
heights=($(awk -F',' 'NR>1 {print $1}' "$TMP_FILE"))

count=${#heights[@]}
if (( count < 2 )); then
  echo "[INFO] Only one giant-miss block found; no spacing pattern to analyze."
else
  # Compute intervals, print transitions
  echo
  echo "Giant-miss transitions (prev_height -> height, Δ):"
  total_delta=0
  min_delta=0
  max_delta=0
  declare -A freq

  prev=${heights[0]}
  for (( i=1; i<count; i++ )); do
    cur=${heights[i]}
    delta=$(( cur - prev ))
    echo "  $prev -> $cur  (Δ=$delta)"

    # track stats
    if (( i == 1 )) || (( delta < min_delta )); then
      min_delta=$delta
    fi
    if (( delta > max_delta )); then
      max_delta=$delta
    fi
    total_delta=$(( total_delta + delta ))
    freq[$delta]=$(( ${freq[$delta]:-0} + 1 ))
    prev=$cur
  done

  num_intervals=$(( count - 1 ))
  avg_delta=$(awk -v sum="$total_delta" -v n="$num_intervals" 'BEGIN { if (n>0) printf "%.2f\n", sum/n; else print "0.00" }')

  echo
  echo "INTERVAL STATS:"
  echo "  giant-miss blocks       : $count"
  echo "  intervals (count-1)     : $num_intervals"
  echo "  min spacing (Δ)         : $min_delta"
  echo "  max spacing (Δ)         : $max_delta"
  echo "  avg spacing (Δ)         : $avg_delta"

  # Interval frequency (which spacings happen most)
  echo
  echo "INTERVAL FREQUENCY (Δ -> count):"
  for d in "${!freq[@]}"; do
    printf "  Δ=%s -> %d\n" "$d" "${freq[$d]}"
  done | sort -n -k2,2 -k1,1
fi

# ------------------------------------------------------------
# Highlight blocks ending in 0
# ------------------------------------------------------------
echo
echo "===== ZERO-ENDING HEIGHTS AMONG GIANT-MISS BLOCKS ====="
zero_count=$(awk -F',' 'NR>1 && $6=="yes" {print}' "$TMP_FILE" | wc -l | tr -d ' ')
total_giant=$(awk 'NR>1 {c++} END{print c+0}' "$TMP_FILE")

if (( total_giant > 0 )); then
  pct_zero=$(awk -v z="$zero_count" -v t="$total_giant" 'BEGIN { if (t>0) printf "%.2f\n", 100*z/t; else print "0.00" }')
else
  pct_zero="0.00"
fi

echo "  total giant-miss blocks : $total_giant"
echo "  zero-ending heights     : $zero_count"
echo "  zero-ending percentage  : ${pct_zero}%"
echo
echo "Zero-ending giant-miss blocks:"
awk -F',' 'NR==1 || $6=="yes"' "$TMP_FILE" | column -t -s','

echo
echo "[DONE] Pattern analysis complete."
