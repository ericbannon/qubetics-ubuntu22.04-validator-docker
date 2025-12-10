#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# commit_quorum_analyzer.sh
#
# Check commit quorum for a range of blocks using ONLY
# the Tendermint/CometBFT RPC (no Cosmos REST).
#
# For each height:
#   - GET $RPC/commit?height=H
#   - GET $RPC/validators?height=H&per_page=300
#   - Compute:
#       * total voting power
#       * signed voting power
#       * quorum %
#       * whether >= 2/3+ threshold
#       * which validators missed (address + power)
#
# Now also:
#   - FLAGS column marking ZERO (height%10==0) and LOW
#   - Summary at the end, including zero-ending blocks only
#
# Usage:
#   RPC=http://localhost:26657 ./commit_quorum_analyzer.sh <START_HEIGHT> <END_HEIGHT>
#
# Example:
#   ./commit_quorum_analyzer.sh 2572100 2572200
#   RPC=http://tendermint.qubetics.com ./commit_quorum_analyzer.sh 2572100 2572200
# ============================================================

RPC="${RPC:-http://localhost:26657}"

if [[ $# -ne 2 ]]; then
  echo "Usage: RPC=http://localhost:26657 $0 <START_HEIGHT> <END_HEIGHT>" >&2
  exit 1
fi

START_HEIGHT="$1"
END_HEIGHT="$2"

if ! [[ "$START_HEIGHT" =~ ^[0-9]+$ ]] || ! [[ "$END_HEIGHT" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] Heights must be numeric." >&2
  exit 1
fi

if (( END_HEIGHT < START_HEIGHT )); then
  echo "[ERROR] END_HEIGHT must be >= START_HEIGHT." >&2
  exit 1
fi

echo "[INFO] Using RPC: $RPC"
echo "[INFO] Analyzing heights $START_HEIGHT .. $END_HEIGHT"
echo

printf "%-10s %-12s %-24s %-16s %-16s %-9s %-10s\n" \
  "HEIGHT" "FLAGS" "TIME" "TOTAL_POWER" "SIGNED_POWER" "QUORUM%" "STATUS"
echo "------------------------------------------------------------------------------------------------------"

# =========================
# Summary accumulators
# =========================
total_blocks=0
ok_blocks=0
low_blocks=0

sum_quorum="0"
min_quorum=""
max_quorum=""

zero_blocks=0
zero_ok=0
zero_low=0

sum_zero_quorum="0"
min_zero_quorum=""
max_zero_quorum=""
worst_zero_height=""

for (( H = START_HEIGHT; H <= END_HEIGHT; H++ )); do
  commit_json=$(curl -sf "$RPC/commit?height=$H" 2>/dev/null || echo "")
  if [[ -z "$commit_json" ]]; then
    echo "[WARN] Could not fetch /commit for height=$H"
    continue
  fi

  ts=$(echo "$commit_json" | jq -r '.result.signed_header.header.time // "unknown"')

  vals_json=$(curl -sf "$RPC/validators?height=$H&per_page=300" 2>/dev/null || echo "")
  if [[ -z "$vals_json" ]]; then
    echo "[WARN] Could not fetch /validators for height=$H"
    continue
  fi

  total_power=$(echo "$vals_json" | jq '[.result.validators[].voting_power|tonumber] | add // 0')

  signers=$(echo "$commit_json" | jq '[.result.signed_header.commit.signatures[]
                                      | select(.block_id_flag == 2)
                                      | .validator_address]')

  signed_power=$(jq -n \
    --argjson vals "$(echo "$vals_json"   | jq '.result.validators')" \
    --argjson signers "$signers" '
      [ $vals[]
        | select(.address as $addr | $signers | index($addr))
        | .voting_power | tonumber
      ] | add // 0
    ')

  n_vals=$(echo "$vals_json"   | jq '.result.validators | length')
  n_signers=$(echo "$signers" | jq 'length')

  quorum_pct=$(awk -v s="$signed_power" -v t="$total_power" 'BEGIN {
    if (t == 0) { printf "0.00"; exit }
    printf "%.2f", (100.0 * s / t)
  }')

  status=$(awk -v s="$signed_power" -v t="$total_power" 'BEGIN {
    if (t == 0) { print "NOSET"; exit }
    if (s * 3 >= 2 * t) { print "OK_2/3+" } else { print "LOW" }
  }')

  # Flags: ZERO if height ends in 0; LOW if quorum < 2/3; both if applicable
  flag=""
  if (( H % 10 == 0 )); then
    flag="ZERO"
  fi
  if [[ "$status" == "LOW" ]]; then
    if [[ -n "$flag" ]]; then
      flag="$flag,LOW"
    else
      flag="LOW"
    fi
  fi

  printf "%-10s %-12s %-24s %-16s %-16s %-9s %-10s\n" \
    "$H" "$flag" "$ts" "$total_power" "$signed_power" "$quorum_pct" "$status"

  # Detail: only list missers if not everyone signed
  if (( n_signers < n_vals )); then
    echo "  Missed validators at height $H:"
    jq -r \
      --argjson vals   "$(echo "$vals_json" | jq '.result.validators')" \
      --argjson signers "$signers" '
        $vals[]
        | select(.address as $addr | $signers | index($addr) | not)
        | "    \(.address)  power=\(.voting_power)"
      ' <<< "{}"
  fi

  # =========================
  # Update summary stats
  # =========================
  total_blocks=$((total_blocks + 1))

  if [[ "$status" == "OK_2/3+" ]]; then
    ok_blocks=$((ok_blocks + 1))
  elif [[ "$status" == "LOW" ]]; then
    low_blocks=$((low_blocks + 1))
  fi

  # overall quorum sum / min / max
  sum_quorum=$(awk -v s="$sum_quorum" -v q="$quorum_pct" 'BEGIN { printf "%.6f", s+q }')
  if [[ -z "$min_quorum" ]]; then
    min_quorum="$quorum_pct"
    max_quorum="$quorum_pct"
  else
    min_quorum=$(awk -v a="$min_quorum" -v b="$quorum_pct" 'BEGIN { if (b < a) print b; else print a }')
    max_quorum=$(awk -v a="$max_quorum" -v b="$quorum_pct" 'BEGIN { if (b > a) print b; else print a }')
  fi

  # zero-ending subset
  if (( H % 10 == 0 )); then
    zero_blocks=$((zero_blocks + 1))
    sum_zero_quorum=$(awk -v s="$sum_zero_quorum" -v q="$quorum_pct" 'BEGIN { printf "%.6f", s+q }')

    if [[ "$status" == "OK_2/3+" ]]; then
      zero_ok=$((zero_ok + 1))
    elif [[ "$status" == "LOW" ]]; then
      zero_low=$((zero_low + 1))
    fi

    if [[ -z "$min_zero_quorum" ]]; then
      min_zero_quorum="$quorum_pct"
      max_zero_quorum="$quorum_pct"
      worst_zero_quorum="$quorum_pct"
      worst_zero_height="$H"
    else
      min_zero_quorum=$(awk -v a="$min_zero_quorum" -v b="$quorum_pct" 'BEGIN { if (b < a) print b; else print a }')
      max_zero_quorum=$(awk -v a="$max_zero_quorum" -v b="$quorum_pct" 'BEGIN { if (b > a) print b; else print a }')
      # track worst zero-ending block (lowest quorum)
      cmp=$(awk -v a="$worst_zero_quorum" -v b="$quorum_pct" 'BEGIN { if (b < a) print 1; else print 0 }')
      if [[ "$cmp" -eq 1 ]]; then
        worst_zero_quorum="$quorum_pct"
        worst_zero_height="$H"
      fi
    fi
  fi

done

echo
echo "===== QUORUM SUMMARY ($START_HEIGHT .. $END_HEIGHT) ====="

if (( total_blocks == 0 )); then
  echo "No blocks successfully analyzed in this range."
  exit 0
fi

avg_quorum=$(awk -v s="$sum_quorum" -v n="$total_blocks" 'BEGIN {
  if (n == 0) { printf "0.00"; exit }
  printf "%.2f", s/n
}')

echo "Total blocks analyzed          : $total_blocks"
echo "  OK_2/3+ commits              : $ok_blocks"
echo "  LOW (<2/3) commits           : $low_blocks"
echo "Overall quorum %%              : min=$min_quorum  avg=$avg_quorum  max=$max_quorum"

echo
echo "----- Zero-ending blocks (heights % 10 == 0) -----"
if (( zero_blocks == 0 )); then
  echo "No zero-ending heights in this range."
else
  avg_zero_quorum=$(awk -v s="$sum_zero_quorum" -v n="$zero_blocks" 'BEGIN {
    if (n == 0) { printf "0.00"; exit }
    printf "%.2f", s/n
  }')

  echo "Zero-ending blocks analyzed    : $zero_blocks"
  echo "  OK_2/3+ zero-ending commits  : $zero_ok"
  echo "  LOW zero-ending commits      : $zero_low"
  echo "Zero-ending quorum %%          : min=$min_zero_quorum  avg=$avg_zero_quorum  max=$max_zero_quorum"
  echo "Worst zero-ending block        : height=$worst_zero_height  quorum%=$worst_zero_quorum"
fi

echo
echo "[DONE] Quorum analysis complete."
echo "Flags legend:"
echo "  ZERO   = height % 10 == 0"
echo "  LOW    = quorum < 2/3 total voting power"
echo "  ZERO,LOW = zero-ending block that failed 2/3 quorum"
