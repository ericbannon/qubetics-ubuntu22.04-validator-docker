#!/usr/bin/env bash
set -euo pipefail

RPC="${RPC:-http://127.0.0.1:26657}"
LOG_PATH="${LOG_PATH:-/mnt/nvme/qubetics/cosmovisor.log}"
NODE_HOME="${NODE_HOME:-/mnt/nvme/qubetics}"
WINDOW_SECS="${WINDOW_SECS:-180}"
SAMPLE_SECS="${SAMPLE_SECS:-10}"
PRINT_SECS="${PRINT_SECS:-30}"

# Auto-detect default interface if not provided
IFACE="${IFACE:-}"
if [[ -z "${IFACE}" ]]; then
  IFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
fi
IFACE="${IFACE:-eth0}"

state_dir="$(mktemp -d -t observe_3m.XXXX)"
samples_file="${state_dir}/samples.jsonl"
iface_stats_file="${state_dir}/iface_stats.jsonl"
log_cursor_file="${state_dir}/log_cursor.pos"

touch "${samples_file}" "${iface_stats_file}" "${log_cursor_file}"

json_escape() { python3 - <<'PY'
import json,sys
print(json.dumps(sys.stdin.read().rstrip('\n')))
PY
}

now_ts() { date +%s; }

# --- Gather functions ---

# 1) Inbound peers from /net_info
gather_inbound_peers() {
  curl -s "${RPC}/net_info" | jq '[.result.peers[] | select(.is_outbound==false)] | length' 2>/dev/null || echo 0
}

# 2) Missed blocks in last WINDOW_SECS (we check signatures on recent commits)
# We detect our validator address and scan back until block time < now - WINDOW_SECS.
# Counts how many commits in that window are missing our signature.
gather_missed_blocks() {
  local now=$(now_ts)
  local my_addr
  my_addr="$(curl -s "${RPC}/status" | jq -r '.result.validator_info.address')"
  if [[ -z "${my_addr}" || "${my_addr}" == "null" ]]; then
    echo 0; return
  fi

  local tip_h tip_t cutoff
  tip_h="$(curl -s "${RPC}/status" | jq -r '.result.sync_info.latest_block_height')"
  tip_t="$(curl -s "${RPC}/status" | jq -r '.result.sync_info.latest_block_time' | sed 's/Z$//')"
  cutoff=$(( now - WINDOW_SECS ))

  # Fast path: if node is far behind, don't loop forever
  local max_scan=300  # up to ~300 blocks (enough for 3m at ~0.6s/block or slower blocks with long timeouts)
  local h="$tip_h"
  local missed=0
  local scanned=0

  # Convert RFC3339 to epoch via date
  # tip_t is for latest block; we'll step downwards until block_time < cutoff
  while [[ "$h" -ge 1 && "$scanned" -lt "$max_scan" ]]; do
    local commit_json
    commit_json="$(curl -s "${RPC}/commit?height=${h}")" || break
    local bh_time
    bh_time="$(echo "$commit_json" | jq -r '.result.signed_header.header.time' | sed 's/Z$//')"
    local bh_epoch
    bh_epoch=$(date -d "$bh_time" +%s 2>/dev/null || echo 0)
    if [[ "$bh_epoch" -lt "$cutoff" ]]; then
      break
    fi
    # Did we sign?
    local signed
    signed="$(echo "$commit_json" | jq --arg A "$my_addr" '[.result.canonical_commit.signatures[]?.validator_address] | index($A)')" || signed="null"
    if [[ "$signed" == "null" ]]; then
      # try alt path in case canonical_commit not populated (older versions)
      signed="$(echo "$commit_json" | jq --arg A "$my_addr" '[.result.signed_header.commit.signatures[]?.validator_address] | index($A)')" || signed="null"
    fi
    if [[ "$signed" == "null" ]]; then
      missed=$(( missed + 1 ))
    fi
    scanned=$(( scanned + 1 ))
    h=$(( h - 1 ))
  done

  echo "$missed"
}

# 3) Peer churn from logs: count Added/Removed peers in last WINDOW_SECS
gather_peer_churn() {
  local since_ts=$(( $(now_ts) - WINDOW_SECS ))
  local cnt_add=0 cnt_rm=0

  if [[ -r "${LOG_PATH}" ]]; then
    # We rely on timestamps like 2025-08-21T.. in the log; filter lines newer than since_ts
    # If timestamps are not in every line, we approximate by tailing last 50k lines.
    local lines
    lines="$(tail -n 50000 "${LOG_PATH}")"
    # Filter by time (approx): keep lines containing 202- prefix, then awk to epoch
    while IFS= read -r line; do
      # Extract ISO time
      ts="$(echo "$line" | sed -n 's/^\([0-9T:\-\.Z\+]*\).*/\1/p' | head -n1)"
      if [[ -n "$ts" ]]; then
        epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
        if [[ "$epoch" -ge "$since_ts" ]]; then
          if echo "$line" | grep -q -E "Added peer|added peer|Added.*peer"; then cnt_add=$((cnt_add+1)); fi
          if echo "$line" | grep -q -E "Removed peer|removed peer|Stopping peer|stopped peer"; then cnt_rm=$((cnt_rm+1)); fi
          if echo "$line" | grep -qi "timeout_precommit"; then :; fi # handled elsewhere
        fi
      fi
    done <<< "$lines"
  fi

  echo "${cnt_add} ${cnt_rm}"
}

# 4) timeout_precommit occurrences from logs in last WINDOW_SECS
gather_timeout_precommit() {
  local since_ts=$(( $(now_ts) - WINDOW_SECS ))
  local cnt=0
  if [[ -r "${LOG_PATH}" ]]; then
    local lines
    lines="$(tail -n 50000 "${LOG_PATH}")"
    while IFS= read -r line; do
      ts="$(echo "$line" | sed -n 's/^\([0-9T:\-\.Z\+]*\).*/\1/p' | head -n1)"
      if [[ -n "$ts" ]]; then
        epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
        if [[ "$epoch" -ge "$since_ts" ]]; then
          if echo "$line" | grep -qiE "timeout[_ ]precommit|Timed out.*Precommit|precommit timeout"; then
            cnt=$((cnt+1))
          fi
        fi
      fi
    done <<< "$lines"
  fi
  echo "$cnt"
}

# 5) Gateway RTT & loss over ~2s (10 pings @ 0.2s)
gather_gw_net() {
  local gw
  gw="$(ip route | awk '/default/ {print $3; exit}')"
  if [[ -z "$gw" ]]; then echo "0 0"; return; fi
  # ping summary: packet loss and rtt avg
  local out
  out="$(ping -c 10 -i 0.2 -w 3 "$gw" 2>/dev/null || true)"
  local loss="$(echo "$out" | awk -F',' '/packet loss/ {gsub(/%/, "", $3); gsub(/ /, "", $3); print $3+0}')"
  local rtt="$(echo "$out" | awk -F'/' '/rtt|round-trip/ {print $5+0}')"
  loss="${loss:-0}"; rtt="${rtt:-0}"
  echo "$rtt $loss"
}

# 6) Gossip volume via iface byte counters delta over WINDOW_SECS
gather_iface_bytes() {
  local rx tx
  rx="$(cat /sys/class/net/${IFACE}/statistics/rx_bytes 2>/dev/null || echo 0)"
  tx="$(cat /sys/class/net/${IFACE}/statistics/tx_bytes 2>/dev/null || echo 0)"
  echo "${rx} ${tx}"
}

record_sample() {
  local ts=$(now_ts)
  local inbound_peers missed add rm to_pc rtt loss rx tx
  inbound_peers="$(gather_inbound_peers)"
  missed="$(gather_missed_blocks)"
  read -r add rm < <(gather_peer_churn)
  to_pc="$(gather_timeout_precommit)"
  read -r rtt loss < <(gather_gw_net)
  read -r rx tx < <(gather_iface_bytes)
  printf '{"ts":%s,"inbound_peers":%s,"missed_blocks":%s,"peer_added":%s,"peer_removed":%s,"timeout_precommit":%s,"gw_rtt_ms":%s,"gw_loss_pc":%s,"rx_bytes":%s,"tx_bytes":%s}\n' \
    "$ts" "$inbound_peers" "$missed" "$add" "$rm" "$to_pc" "$rtt" "$loss" "$rx" "$tx" >> "${samples_file}"
}

print_window() {
  local now=$(now_ts)
  local since=$(( now - WINDOW_SECS ))
  # Load last N lines (limit for speed)
  local lines
  lines="$(tail -n 2000 "${samples_file}")"
  local summary="$(echo "$lines" | jq --argjson since "$since" -r '
    [ . as $all
      | (map(select(.ts >= $since)) ) as $w
      | {
          samples: ($w|length),
          inbound_peers_avg: (($w|map(.inbound_peers)|add) / ( ($w|length) + 1e-9 )),
          missed_blocks: ($w|map(.missed_blocks)|max // 0),
          peer_added: ($w|map(.peer_added)|add // 0),
          peer_removed: ($w|map(.peer_removed)|add // 0),
          timeout_precommit: ($w|map(.timeout_precommit)|add // 0),
          gw_rtt_ms_avg: (($w|map(.gw_rtt_ms)|add) / ( ($w|length) + 1e-9 )),
          gw_loss_pc_avg: (($w|map(.gw_loss_pc)|add) / ( ($w|length) + 1e-9 )),
          gossip_bytes_rx: ( ( ($w|last).rx_bytes // 0) - ( ($w|first).rx_bytes // 0) ),
          gossip_bytes_tx: ( ( ($w|last).tx_bytes // 0) - ( ($w|first).tx_bytes // 0) )
        }
    ][0]
  ')"
  echo "=== 3m window @ $(date -Is) IFACE=${IFACE} ==="
  echo "$summary" | jq .
}

# Main loop
last_print=$(now_ts)
while true; do
  record_sample
  sleep "${SAMPLE_SECS}"
  now=$(now_ts)
  if (( now - last_print >= PRINT_SECS )); then
    print_window
    last_print=$now
  fi
done
