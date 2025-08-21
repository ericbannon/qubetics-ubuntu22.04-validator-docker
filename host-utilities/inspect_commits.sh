#!/usr/bin/env bash
# inspect_commits.sh (hex-consaddr from RPC)
set -euo pipefail

CONTAINER="${CONTAINER:-validator-node}"
HOME_DIR="${HOME_DIR:-/mnt/nvme/qubetics}"
RPC="${RPC:-http://127.0.0.1:26657}"

usage(){ echo "Usage: $0 -H <start_height> [-n <count> | -E <end_height>]"; exit 1; }
H_START=""; H_END=""; COUNT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--height) H_START="${2:-}"; shift 2;;
    -n|--count)  COUNT="${2:-}";   shift 2;;
    -E|--end)    H_END="${2:-}";   shift 2;;
    -h|--help)   usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done
[[ -z "${H_START}" ]] && usage
[[ -n "${COUNT}" && -n "${H_END}" ]] && { echo "Use either -n or -E (not both)"; exit 1; }
if [[ -n "${COUNT}" ]]; then H_END=$(( H_START + COUNT - 1 )); fi
: "${H_END:=$H_START}"

# --- Your consensus HEX address (from RPC, not CLI) ---
VALHEX="$(curl -s "$RPC/status" | jq -r '.result.validator_info.address' | tr '[:lower:]' '[:upper:]' | tr -d '\r\n ')"
if [[ -z "$VALHEX" || "$VALHEX" == "null" ]]; then
  echo "Failed to obtain hex consensus addr from $RPC/status"; exit 1
fi

flag_name(){ case "$1" in 1) echo ABSENT;; 2) echo COMMIT;; 3) echo NIL;; *) echo "UNKNOWN($1)";; esac; }

get_flag_for_height(){
  local h="$1" hex="$2" flag cj bj
  cj="$(curl -s "$RPC/commit?height=$h")" || true
  flag="$(echo "$cj" | jq -r --arg V "$hex" '
    .result.signed_header.commit.signatures[]? |
    select((.validator_address // "") | ascii_upcase == $V) |
    .block_id_flag' 2>/dev/null || true)"
  if [[ -n "$flag" && "$flag" != "null" ]]; then
    echo "$(flag_name "$flag")"; return
  fi
  bj="$(curl -s "$RPC/block?height=$h")" || true
  flag="$(echo "$bj" | jq -r --arg V "$hex" '
    .result.block.last_commit.signatures[]? |
    select((.validator_address // "") | ascii_upcase == $V) |
    .block_id_flag' 2>/dev/null || true)"
  if [[ -n "$flag" && "$flag" != "null" ]]; then
    echo "$(flag_name "$flag")"; return
  fi
  echo "ABSENT"
}

echo "RPC=$RPC"
echo "VALCONS(hex)=$VALHEX"
echo "Range: $H_START..$H_END"
echo

printed_debug=0
SIGNED=0; MISSED=0; NIL=0; TOTAL=0

for (( h=H_START; h<=H_END; h++ )); do
  hdr="$(curl -s "$RPC/block?height=$h")"
  prop="$(echo "$hdr" | jq -r '.result.block.header.proposer_address // empty')"
  time="$(echo "$hdr" | jq -r '.result.block.header.time // empty')"

  flag="$(get_flag_for_height "$h" "$VALHEX")"
  echo "height=$h time=$time proposer=$prop you=$VALHEX commit_flag=$flag"

  case "$flag" in
    COMMIT) SIGNED=$((SIGNED+1));;
    ABSENT) MISSED=$((MISSED+1));;
    NIL)    NIL=$((NIL+1));;
  esac
  TOTAL=$((TOTAL+1))

  if [[ $printed_debug -eq 0 ]]; then
    echo "debug_sample_addresses:"
    echo "$hdr" | jq -r '.result.block.last_commit.signatures[]?.validator_address' \
      | awk 'NF' | head -n 8 | sed 's/^/  - /'
    printed_debug=1
  fi
done

echo
echo "===== SUMMARY ====="
echo "Heights checked: $H_START → $H_END  (total $TOTAL)"
echo "Signed (COMMIT): $SIGNED"
echo "Missed (ABSENT): $MISSED"
echo "NIL votes:       $NIL"
pct=$(( 100 * SIGNED / TOTAL ))
echo "Success rate:    $pct% signed"
