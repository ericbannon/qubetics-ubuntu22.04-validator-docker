#!/usr/bin/env bash
# missed_block_analysis.sh
# Usage:
#   ./missed_block_analysis.sh -H 858252
#   ./missed_block_analysis.sh --latest

set -o pipefail  # keep errors visible in pipelines; don't use -e so we still print diagnostics

# --- Hard-coded node details ---
RPC="http://localhost:26657"
CN="validator-node"
HOME_Q="/mnt/nvme/qubetics"

usage() {
  cat <<EOF
Usage: $0 -H <height> | --latest
  -H, --height <n>   Block height to inspect (integer)
  -l, --latest       Use the latest block height
  -h, --help         Show this help
EOF
}

# --- Args ---
H=""
LATEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    -H|--height) H="${2:-}"; shift 2 ;;
    -l|--latest) LATEST=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; break ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

if [ "$LATEST" -eq 1 ]; then
  H="$(curl -sf "$RPC/status" | jq -r .result.sync_info.latest_block_height 2>/dev/null)"
fi
if [[ -z "${H:-}" || ! "$H" =~ ^[0-9]+$ ]]; then
  echo "Error: height required. Use -H <int> or --latest." >&2
  exit 1
fi

echo "Inspecting height: $H"
echo "RPC: $RPC"
echo

# --- Derive your consensus addresses (RPC-first; CLI fallback) ---
VALCONS="$(docker exec -i "$CN" qubeticsd tendermint show-address --home "$HOME_Q" 2>/dev/null | tr -d '\r' || true)"
MYHEX="$(curl -sf "$RPC/status" | jq -r '.result.validator_info.address // empty')"

if [ -z "$MYHEX" ] && [ -n "$VALCONS" ]; then
  MYHEX="$(docker exec -i "$CN" qubeticsd debug addr "$VALCONS" 2>/dev/null \
            | awk '/Address \(hex\):/{print $3}')"
fi

echo "▶ ValCons(bech32) = ${VALCONS:-<unknown>}"
echo "▶ ValCons(hex)    = ${MYHEX:-<unknown>}"

MYHEXU="$(echo -n "$MYHEX" | tr '[:lower:]' '[:upper:]')"

# --- Block header (always prints if RPC ok) ---
echo; echo "== Block header =="
if ! curl -sf "$RPC/block?height=$H" | jq -r '.result.block.header | {height,time,proposer_address}'; then
  echo "Failed to fetch block header from $RPC" >&2
  exit 1
fi

# --- Were you in the validator set at that height? ---
echo; echo "== In validator set at height? =="
if [ -n "$MYHEXU" ]; then
  # Try single page with big per_page; if empty array returned, print UNKNOWN
  if ! curl -sf "$RPC/validators?height=$H&per_page=1000" \
    | jq -r --arg MY "$MYHEXU" '
        (.result.validators // []) as $V
        | if ($V | length) == 0 then
            "UNKNOWN (no validators returned)"
          else
            ( [ $V[].address | ascii_upcase ] | index($MY) | if .==null then "NOT_IN_SET" else "IN_SET" end )
          end
      '
  then
    echo "Could not fetch /validators"
  fi
else
  echo "Unknown (no hex addr)"
fi

# --- Your commit vote (COMMIT / NIL / ABSENT) ---
echo; echo "== Your commit at this height =="
if [ -n "$MYHEXU" ]; then
  # Print a friendly mapping; if no entry, say so
  if ! curl -sf "$RPC/commit?height=$H" \
    | jq -r --arg MY "$MYHEXU" '
        .result.signed_header.commit.signatures
        | map(select((.validator_address | ascii_upcase) == $MY))
        | if (length==0) then
            "No commit entry (likely NOT_IN_SET)"
          else
            .[0] as $s
            | "validator_address=\($s.validator_address // "n/a")  block_id_flag=\($s.block_id_flag // "n/a")  signed=\((($s.signature!=null) // false) | tostring)"
            + "\n→ meaning: " +
              ( ($s.block_id_flag|tostring) |
                if .=="2" then "COMMIT (you signed the block)"
                elif .=="3" then "NIL (you voted, but not for the proposed block)"
                elif .=="1" then "ABSENT (no vote from you at this height)"
                else "UNKNOWN"
                end
              )
          end
      '
  then
    echo "Could not fetch /commit"
  fi
else
  echo "Skipped (no hex addr to match)"
fi
