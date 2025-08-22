#!/usr/bin/env bash
# test_3m_metrics.sh
# Standalone tester for the new additions:
# - Inbound peers (3m avg)
# - Peer churn (3m)
# - Precommit timeouts (3m)
# - Gateway RTT/loss
# - Gossip volume (3m)
#
# It prints a simple Markdown-ish block so you can verify values locally.
# No Telegram send, no external dependencies beyond typical CLI tools.
#
# Env overrides (all optional):
#   RPC=http://127.0.0.1:26657
#   LOG_PATH=/mnt/nvme/qubetics/cosmovisor.log
#   IFACE=eth0
#   WINDOW_SECS=180
#   STATE_DIR=/var/tmp
#   DEBUG=1     (print debug lines)
set -euo pipefail

RPC="${RPC:-http://127.0.0.1:26657}"
LOG_PATH="${LOG_PATH:-/mnt/nvme/qubetics/cosmovisor.log}"
WINDOW_SECS="${WINDOW_SECS:-180}"
STATE_DIR="${STATE_DIR:-/var/tmp}"

# Pick interface
IFACE="${IFACE:-}"
if [[ -z "${IFACE}" ]]; then
  IFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
fi
IFACE="${IFACE:-eth0}"

now_ts() { date +%s; }
ts_now="$(now_ts)"
ts_cutoff="$(( ts_now - WINDOW_SECS ))"

# 1) Inbound peers (now), avg (use observer if present; otherwise use now value)
inbound_now="$(curl -sf --max-time 3 "${RPC}/net_info" | jq '[.result.peers[] | select(.is_outbound==false)] | length' 2>/dev/null || echo 0)"
inbound_avg_3m="${inbound_now}"

obs_dir="$(ls -d /tmp/observe_3m.* 2>/dev/null | tail -n 1 || true)"
if [[ -n "$obs_dir" && -f "$obs_dir/samples.jsonl" ]]; then
  inbound_avg_3m="$(jq --argjson since "$ts_cutoff" -r '
    [ inputs | select(.ts >= $since) | .inbound_peers ] as $w
    | if ($w|length) == 0 then 0 else (( ($w|add) / ($w|length) )) end
  ' "$obs_dir/samples.jsonl" 2>/dev/null || echo "$inbound_now")"
fi

# 2) Peer churn and precommit timeouts from logs (3m window)
peer_added_3m=0; peer_removed_3m=0; timeout_precommit_3m=0
if [[ -r "${LOG_PATH}" ]]; then
  while IFS= read -r line; do
    ts="$(echo "$line" | sed -n 's/^\([0-9T:\-\.Z\+]*\).*/\1/p' | head -n1)"
    if [[ -n "$ts" ]]; then
      epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
      if [[ "$epoch" -ge "$ts_cutoff" ]]; then
        if echo "$line" | grep -q -E "Added peer|added peer|Added.*peer"; then peer_added_3m=$((peer_added_3m+1)); fi
        if echo "$line" | grep -q -E "Removed peer|removed peer|Stopping peer|stopped peer"; then peer_removed_3m=$((peer_removed_3m+1)); fi
        if echo "$line" | grep -qiE "timeout[_ ]precommit|Timed out.*Precommit|precommit timeout"; then timeout_precommit_3m=$((timeout_precommit_3m+1)); fi
      fi
    fi
  done < <(tail -n 50000 "${LOG_PATH}")
fi

# 3) Gateway RTT/loss (quick sample)
gw_rtt_ms_avg="N/A"; gw_loss_pc_avg="N/A"
gw="$(ip route | awk '/default/ {print $3; exit}')"
if command -v ping >/dev/null 2>&1 && [[ -n "$gw" ]]; then
  out="$(ping -c 5 -i 0.2 -w 2 "$gw" 2>/dev/null || true)"
  loss="$(echo "$out" | awk -F',' '/packet loss/ {gsub(/%/, "", $3); gsub(/ /, "", $3); print $3+0}')"
  rtt="$(echo "$out" | awk -F'/' '/rtt|round-trip/ {print $5+0}')"
  [[ -n "$rtt" ]] && gw_rtt_ms_avg="$rtt"
  [[ -n "$loss" ]] && gw_loss_pc_avg="$loss"
fi

# 4) Gossip volume via interface bytes (maintain small 3m state in STATE_DIR)
state_file="${STATE_DIR}/validator_ifstats_${IFACE}.jsonl"
rx_now="$(cat /sys/class/net/${IFACE}/statistics/rx_bytes 2>/dev/null || echo 0)"
tx_now="$(cat /sys/class/net/${IFACE}/statistics/tx_bytes 2>/dev/null || echo 0)"
echo "{\"ts\":${ts_now},\"rx\":${rx_now},\"tx\":${tx_now}}" >> "${state_file}" 2>/dev/null || true

# prune old
tmp_prune="$(mktemp 2>/dev/null || echo /tmp/ifstats.$$)"
awk -v cutoff="$ts_cutoff" 'BEGIN{FS="[:,]}"}{for(i=1;i<=NF;i++){if($i ~ /"ts"/){ if($(i+1)>=cutoff){print $0} }}}' "${state_file}" > "${tmp_prune}" 2>/dev/null || true
mv "${tmp_prune}" "${state_file}" 2>/dev/null || true

line_first="$(head -n 1 "${state_file}" 2>/dev/null)"
line_last="$(tail -n 1 "${state_file}" 2>/dev/null)"
gossip_rx_3m=0; gossip_tx_3m=0
if [[ -n "$line_first" && -n "$line_last" ]]; then
  rx_first="$(echo "$line_first" | jq -r '.rx' 2>/dev/null || echo 0)"
  tx_first="$(echo "$line_first" | jq -r '.tx' 2>/dev/null || echo 0)"
  rx_last="$(echo "$line_last" | jq -r '.rx' 2>/dev/null || echo 0)"
  tx_last="$(echo "$line_last" | jq -r '.tx' 2>/dev/null || echo 0)"
  gossip_rx_3m="$(( rx_last - rx_first ))"
  gossip_tx_3m="$(( tx_last - tx_first ))"
  (( gossip_rx_3m < 0 )) && gossip_rx_3m=0
  (( gossip_tx_3m < 0 )) && gossip_tx_3m=0
fi

# Humanize bytes + compute per-second rates
human_bytes() {
  local b=$1; local d=0; local s=("B" "KB" "MB" "GB" "TB")
  while (( b >= 1024 && d < 4 )); do b=$(( b/1024 )); d=$(( d+1 )); done
  echo "${b}${s[$d]}"
}

gossip_rx_3m_h="$(human_bytes "${gossip_rx_3m}")"
gossip_tx_3m_h="$(human_bytes "${gossip_tx_3m}")"
# Use actual window elapsed between first and last point when possible
window_elapsed=${WINDOW_SECS}
if [[ -n "$line_first" && -n "$line_last" ]]; then
  ts_first="$(echo "$line_first" | jq -r '.ts' 2>/dev/null || echo 0)"
  ts_last="$(echo "$line_last" | jq -r '.ts' 2>/dev/null || echo 0)"
  if (( ts_last > ts_first )); then
    window_elapsed=$(( ts_last - ts_first ))
  fi
fi
rx_mbs=$(python3 - <<PY
import sys
b=${gossip_rx_3m}; w=${window_elapsed} if ${window_elapsed} else 1
print(round((b/1048576)/w, 3))
PY
)
tx_mbs=$(python3 - <<PY
import sys
b=${gossip_tx_3m}; w=${window_elapsed} if ${window_elapsed} else 1
print(round((b/1048576)/w, 3))
PY
)

# Output
cat <<EOM
### 3-minute Metrics Sanity Check
🔌 Inbound peers (now): ${inbound_now}
🔌 Inbound peers (3m avg): ${inbound_avg_3m}
🔄 Peer churn (3m): +${peer_added_3m} / -${peer_removed_3m}
⏱️ Precommit timeouts (3m): ${timeout_precommit_3m}
🌐 Gateway: ${gw_rtt_ms_avg} ms, loss ${gw_loss_pc_avg}%
🗣️ Gossip (3m): ${gossip_rx_3m_h} RX / ${gossip_tx_3m_h} TX
🚿 Gossip rate: ${rx_mbs} MB/s RX / ${tx_mbs} MB/s TX
IFACE=${IFACE}  WINDOW_SECS=${WINDOW_SECS}  STATE_DIR=${STATE_DIR}
Cutoff: $(date -d "@$ts_cutoff" -Is)  Now: $(date -d "@$ts_now" -Is)
EOM

if [[ "${DEBUG:-0}" == "1" ]]; then
  echo "--- DEBUG ---"
  echo "RPC=$RPC"
  echo "LOG_PATH=$LOG_PATH"
  echo "IFACE=$IFACE"
  echo "State file: $state_file"
  tail -n 3 "$state_file" 2>/dev/null || true
fi
