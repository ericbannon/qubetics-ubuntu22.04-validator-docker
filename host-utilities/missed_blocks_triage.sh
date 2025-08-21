#!/usr/bin/env bash
# inspect_commits.sh
set -euo pipefail

# Defaults (override via env or flags)
CONTAINER="${CONTAINER:-validator-node}"
HOME_DIR="${HOME_DIR:-/mnt/nvme/qubetics}"
RPC="${RPC:-http://127.0.0.1:26657}"

usage() {
  cat <<EOF
Usage: $0 -H <start_height> [-n <count> | -E <end_height>] [--]
Env overrides: CONTAINER, HOME_DIR, RPC
Examples:
  $0 -H 914180 -n 40
  $0 -H 914180 -E 914220
EOF
  exit 1
}

H_START=""; H_END=""; COUNT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--height) H_START="${2:-}"; shift 2;;
    -n|--count)  COUNT="${2:-}";   shift 2;;
    -E|--end)    H_END="${2:-}";   shift 2;;
    -h|--help)   usage;;
    --) shift; break;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

[[ -z "${H_START}" ]] && { echo "Missing -H <start_height>"; usage; }
[[ -n "${COUNT}" && -n "${H_END}" ]] && { echo "Use either -n or -E, not both"; usage; }

# Resolve end height
if [[ -n "${COUNT}" ]]; then
  if ! [[ "${COUNT}" =~ ^[0-9]+$ ]]; then echo "Invalid count: ${COUNT}"; exit 1; fi
  H_END=$(( H_START + COUNT - 1 ))
elif [[ -z "${H_END}" ]]; then
  H_END="${H_START}"
fi

# Validate numbers
for v in "$H_START" "$H_END"; do
  [[ "$v" =~ ^[0-9]+$ ]] || { echo "Heights must be integers"; exit 1; }
done

# Get your validator consensus hex address (uppercased)
VALHEX="$(docker exec "$CONTAINER" sh -lc "qubeticsd tendermint show-address --home '$HOME_DIR'" | tr '[:lower:]' '[:upper:]')"

# Small helpers
jget() { jq -r "$1" 2>/dev/null || true; }
flag_name() {
  case "$1" in
    1) echo "ABSENT" ;;
    2) echo "COMMIT" ;;
    3) echo "NIL"    ;;
    *) echo "UNKNOWN($1)" ;;
  esac
}

echo "CONTAINER=$CONTAINER  RPC=$RPC"
echo "VALCONS(hex)=$VALHEX"
echo "Range: $H_START..$H_END"
echo

for (( h=H_START; h<=H_END; h++ )); do
  # Header (proposer + time)
  HDR_JSON="$(curl -s "$RPC/block?height=$h")"
  PROP="$(echo "$HDR_JSON" | jget '.result.block.header.proposer_address')"
  TIME="$(echo "$HDR_JSON" | jget '.result.block.header.time')"
  [[ -z "$PROP" ]] && PROP="$(echo "$HDR_JSON" | grep -o '"proposer_address":"[A-F0-9]\+"' | cut -d: -f2 | tr -d '"')"

  # Commit flag for *your* validator at this height
  COM_JSON="$(curl -s "$RPC/commit?height=$h")"
  RAW_FLAG="$(echo "$COM_JSON" | jq -r --arg V "$VALHEX" \
    '.result.signed_header.commit.signatures[]? | select(.validator_address==$V) | .block_id_flag' 2>/dev/null || true)"
  if [[ -z "$RAW_FLAG" || "$RAW_FLAG" == "null" ]]; then
    FLAG="ABSENT"
  else
    FLAG="$(flag_name "$RAW_FLAG")"
  fi

  echo "height=$h time=$TIME proposer=$PROP you=$VALHEX commit_flag=$FLAG"
done
