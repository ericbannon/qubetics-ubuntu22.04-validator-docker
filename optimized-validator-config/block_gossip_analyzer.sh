#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Block Gossip Speed Analyzer (Tendermint / CometBFT only)
#
# Measures, for each new block height:
#  - Proposer timestamp (from header.time)
#  - When your local node first reports that height
#  - When each reference RPC first reports that height
#  - Delay vs proposer (ms) for you and each reference
#
# Uses only: /status and /block?height=H
# ============================================================

# ---- CONFIG -------------------------------------------------

# Local node (your validator)
LOCAL_RPC="${LOCAL_RPC:-http://localhost:26657}"

# Comma-separated reference RPCs (guardian, sentry, etc.)
# You can override this when running:
#   REF_RPCS="http://3.95.155.80:26657,http://34.42.60.46:26657" ./block_gossip_analyzer.sh
REF_RPCS="${REF_RPCS:-http://3.95.155.80:26657,http://34.42.60.46:26657}"

# How often to poll local /status for new heights (seconds)
POLL_INTERVAL="${POLL_INTERVAL:-1}"

# How often to poll each reference RPC while waiting for height H (seconds)
REF_POLL_INTERVAL="${REF_POLL_INTERVAL:-0.5}"

# Max time to wait for a reference RPC to reach height H (seconds)
MAX_REF_WAIT_SEC="${MAX_REF_WAIT_SEC:-10}"

# Minimum height to start from (0 = auto-detect current tip)
START_HEIGHT="${START_HEIGHT:-0}"

# ============================================================
# Utility: require jq & curl
# ============================================================
for cmd in curl jq date; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' not found in PATH. Please install it." >&2
    exit 1
  fi
done

# ============================================================
# Utility: RFC3339(+nsec) -> epoch ms
# e.g. 2025-12-10T08:07:09.011569241Z -> 1733827629.011 -> ms
# ============================================================
ts_to_ms() {
  local ts="$1"       # full RFC3339 with or without fractional
  # Strip trailing Z if present
  ts="${ts%Z}"

  local base frac
  if [[ "$ts" == *.* ]]; then
    base="${ts%.*}"
    frac="${ts#*.}"
  else
    base="$ts"
    frac="0"
  fi

  # Use only first 3 digits of fractional as ms
  frac="${frac}000"          # pad
  local ms="${frac:0:3}"

  # Convert base (seconds) with date
  local sec
  sec=$(date -d "${base}Z" +%s 2>/dev/null || echo 0)

  echo $(( sec * 1000 + ms ))
}

# ============================================================
# Globals for summary stats
# ============================================================
total_blocks=0
sum_local_delay=0

# Per-ref associative arrays (indexed by ref URL)
declare -A ref_sum_delay_ms
declare -A ref_count
declare -A ref_last_moniker

# ============================================================
# Summary on exit
# ============================================================
summarize() {
  echo
  echo "===== BLOCK GOSSIP SUMMARY ====="
  echo "Total blocks observed: $total_blocks"
  if (( total_blocks > 0 )); then
    local avg_local=$(( sum_local_delay / total_blocks ))
    echo "Average local delay vs proposer: ${avg_local} ms"
  fi
  echo

  if (( ${#ref_count[@]} == 0 )); then
    echo "No reference RPCs successfully sampled."
    exit 0
  fi

  printf "%-35s %-10s %-10s\n" "Reference" "Samples" "AvgDelay(ms)"
  echo "---------------------------------------------------------------"
  for ref in "${!ref_count[@]}"; do
    local cnt=${ref_count[$ref]}
    local sum=${ref_sum_delay_ms[$ref]}
    local avg=$(( sum / cnt ))
    local label="$ref"
    if [[ -n "${ref_last_moniker[$ref]:-}" ]]; then
      label="${ref_last_moniker[$ref]} (${ref})"
    fi
    printf "%-35s %-10d %-10d\n" "$label" "$cnt" "$avg"
  done

  echo
  echo "Note:"
  echo "- Delay is: time_we_saw_ref_height(H) - block_proposer_time(H)"
  echo "- Positive delta vs local means YOU are slower than that reference."
  exit 0
}

trap summarize INT TERM

# ============================================================
# Parse REF_RPCS into an array
# ============================================================
IFS=',' read -r -a REF_ARRAY <<< "$REF_RPCS"

echo "[INFO] Local RPC       : $LOCAL_RPC"
echo "[INFO] Reference RPC(s): ${REF_ARRAY[*]}"
echo "[INFO] Poll interval   : ${POLL_INTERVAL}s (local), ${REF_POLL_INTERVAL}s (refs)"
echo "[INFO] Max ref wait    : ${MAX_REF_WAIT_SEC}s per block"
echo

# ============================================================
# Get initial local height
# ============================================================
local_json=$(curl -sf "$LOCAL_RPC/status" || { echo "ERROR: cannot reach $LOCAL_RPC/status"; exit 1; })
local_height=$(echo "$local_json" | jq -r '.result.sync_info.latest_block_height // "0"')

if ! [[ "$local_height" =~ ^[0-9]+$ ]]; then
  echo "ERROR: non-numeric local height: $local_height" >&2
  exit 1
fi

if (( START_HEIGHT > 0 )); then
  if (( START_HEIGHT > local_height )); then
    echo "[WARN] START_HEIGHT=$START_HEIGHT > current tip=$local_height; using tip."
    START_HEIGHT=$local_height
  fi
  next_height=$START_HEIGHT
else
  next_height=$(( local_height + 1 ))
fi

echo "[INFO] Starting from height: $next_height"
echo "[INFO] Press CTRL-C to stop and see summary."
echo

# ============================================================
# Main loop
# ============================================================
while true; do
  # 1. Poll local /status
  local_json=$(curl -sf "$LOCAL_RPC/status" 2>/dev/null || echo "")
  if [[ -z "$local_json" ]]; then
    echo "$(date -Iseconds) [WARN] Could not fetch local /status"
    sleep "$POLL_INTERVAL"
    continue
  fi

  local_current=$(echo "$local_json" | jq -r '.result.sync_info.latest_block_height // "0"' 2>/dev/null || echo "0")

  # If no progress yet
  if ! [[ "$local_current" =~ ^[0-9]+$ ]]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  # If we’re still below desired next_height, just wait
  if (( local_current < next_height )); then
    sleep "$POLL_INTERVAL"
    continue
  fi

  # If we jumped ahead multiple heights (e.g. node lagged briefly),
  # process each missing height up to local_current.
  while (( next_height <= local_current )); do
    height=$next_height
    t_local_ms=$(date +%s%3N)

    # --------------------------------------------------------
    # Get block header time from local /block
    # --------------------------------------------------------
    block_json=$(curl -sf "$LOCAL_RPC/block?height=$height" 2>/dev/null || echo "")
    if [[ -z "$block_json" ]]; then
      echo "$(date -Iseconds) [WARN] Could not fetch /block?height=$height"
      next_height=$(( height + 1 ))
      continue
    fi

    header_time=$(echo "$block_json" | jq -r '.result.block.header.time // empty')
    if [[ -z "$header_time" || "$header_time" == "null" ]]; then
      echo "$(date -Iseconds) [WARN] Missing header.time at height=$height"
      next_height=$(( height + 1 ))
      continue
    fi

    block_ms=$(ts_to_ms "$header_time")
    local_delay_ms=$(( t_local_ms - block_ms ))

    total_blocks=$(( total_blocks + 1 ))
    sum_local_delay=$(( sum_local_delay + local_delay_ms ))

    ts_now=$(date -Iseconds)
    echo
    echo "$ts_now [BLOCK] h=$height proposer_time=$header_time"
    echo "  local_seen_t     = $t_local_ms ms since epoch"
    echo "  local_delay_ms   = $local_delay_ms"

    # --------------------------------------------------------
    # For each reference RPC, measure when it first reports height >= H
    # --------------------------------------------------------
    for ref in "${REF_ARRAY[@]}"; do
      [[ -z "$ref" ]] && continue

      start_ms=$(date +%s%3N)
      deadline_ms=$(( start_ms + MAX_REF_WAIT_SEC * 1000 ))
      ref_seen_ms=0
      ref_height=0
      ref_moniker=""

      while :; do
        now_ms=$(date +%s%3N)
        if (( now_ms > deadline_ms )); then
          break
        fi

        ref_json=$(curl -sf "$ref/status" 2>/dev/null || echo "")
        if [[ -z "$ref_json" ]]; then
          sleep "$REF_POLL_INTERVAL"
          continue
        fi

        ref_height=$(echo "$ref_json" | jq -r '.result.sync_info.latest_block_height // "0"' 2>/dev/null || echo "0")
        ref_moniker=$(echo "$ref_json" | jq -r '.result.node_info.moniker // ""' 2>/dev/null || echo "")

        # Track last moniker
        ref_last_moniker["$ref"]="$ref_moniker"

        if [[ "$ref_height" =~ ^[0-9]+$ ]] && (( ref_height >= height )); then
          ref_seen_ms=$now_ms
          break
        fi

        sleep "$REF_POLL_INTERVAL"
      done

      if (( ref_seen_ms == 0 )); then
        echo "  ref[$ref_moniker | $ref]: did NOT reach height=$height within ${MAX_REF_WAIT_SEC}s (latest=$ref_height)"
        continue
      fi

      ref_delay_ms=$(( ref_seen_ms - block_ms ))
      delta_vs_local=$(( ref_delay_ms - local_delay_ms ))

      # Update stats
      ref_count["$ref"]=$(( ${ref_count[$ref]:-0} + 1 ))
      ref_sum_delay_ms["$ref"]=$(( ${ref_sum_delay_ms[$ref]:-0} + ref_delay_ms ))

      printf "  ref[%s | %s]: height=%s delay=%d ms (Δ vs local: %+d ms)\n" \
        "${ref_moniker:-unknown}" "$ref" "$ref_height" "$ref_delay_ms" "$delta_vs_local"
    done

    next_height=$(( height + 1 ))
  done

  sleep "$POLL_INTERVAL"
done
