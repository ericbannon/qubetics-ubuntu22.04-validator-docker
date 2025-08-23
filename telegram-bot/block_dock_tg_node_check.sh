#!/usr/bin/env bash
# Block Dock Validator Health Reporter (MERGED)
# - 3m/10m P2P metrics (inbound avg, churn, precommit timeouts)
# - Gossip totals over window + MB/s rates
# - Live 5s RX/TX sample
# - Auto IFACE + background sampler (10s) feeding /var/tmp JSONL
# Deps: docker, jq, bc, curl, md5sum, awk, ping, python3, iproute2
# Cron example (every 10 min):
# */10 * * * * IFACE=wlp4s0 . /etc/default/telegram.env; /home/admin/scripts/blockdock_updater_merged.sh >> /home/admin/scripts/blockdock_updater.log 2>&1

set -o pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- load Telegram env (required) ---
if [ -r /etc/default/telegram.env ]; then
  set -a; . /etc/default/telegram.env; set +a
fi
: "${TELEGRAM_BOT_TOKEN:?Telegram env not set}"
: "${TELEGRAM_CHAT_ID:?Telegram env not set}"

# === CONFIG ===
NODE_RPC="${NODE_RPC:-http://localhost:26657}"
DAEMON_HOME="${DAEMON_HOME:-/mnt/nvme/qubetics}"
DOCKER_NAME="${DOCKER_NAME:-validator-node}"

VALIDATOR_ADDR="${VALIDATOR_ADDR:-qubeticsvaloper18llj8eqh9k9mznylk8svrcc63ucf7y2r4xkd8l}"
WALLET_ADDR="${WALLET_ADDR:-qubetics18llj8eqh9k9mznylk8svrcc63ucf7y2rkyqm2m}"
VALCONS_ADDR="${VALCONS_ADDR:-qubeticsvalcons1jpprhtglnlp7f65m526h5rlpf69z0k09254veh}"

SLASH_LOOKBACK_BLOCKS="${SLASH_LOOKBACK_BLOCKS:-200000}"
ALERT_FILE="${ALERT_FILE:-/tmp/qubetics_last_alert}"
LOG_FILE="${LOG_FILE:-/home/admin/scripts/blockdock_updater.log}"

# Metrics window (600s pairs well with 10m timer; set WINDOW_SECS=180 if you want a 3m view)
: "${WINDOW_SECS:=600}"

# --- logging path ---
mkdir -p "$(dirname "$LOG_FILE")" || true
if ! touch "$LOG_FILE" 2>/dev/null; then
  LOG_FILE="$HOME/.local/state/blockdock/updates.log"
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE" || { echo "cannot write $LOG_FILE"; exit 1; }
fi

# --- Quiet mode: only print to terminal if script FAILS ---
: "${QUIET:=1}"
if [ "$QUIET" = "1" ]; then
  _TMP_OUT="$(mktemp)"
  exec 5>&1 6>&2
  exec >"$_TMP_OUT" 2>&1
  _on_exit() {
    s=$?
    if [ $s -ne 0 ]; then
      echo "❌ blockdock_updater_merged.sh failed (exit $s)" >&5
      cat "$_TMP_OUT" >&5
    fi
    rm -f "$_TMP_OUT"
    exit $s
  }
  trap _on_exit EXIT
fi

# === Helpers ===
run_q() { docker exec -i "$DOCKER_NAME" qubeticsd "$@"; }
log()  { echo "$(date +'%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }
fmt_pct()  { awk -v x="$1" 'BEGIN{printf "%.2f", (x+0)}'; }
fmt_tics() { awk -v x="$1" 'BEGIN{printf "%.3f", (x+0)}'; }
now_ts() { date +%s; }
human_bytes() {
  local b=$1 d=0 s=("B" "KB" "MB" "GB" "TB")
  while (( b >= 1024 && d < 4 )); do b=$(( b/1024 )); d=$(( d+1 )); done
  printf "%s%s" "$b" "${s[$d]}"
}

send_telegram_alert() {
  local msg="$1"
  local resp body code
  resp=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
           -d chat_id="$TELEGRAM_CHAT_ID" -d parse_mode="Markdown" --data-urlencode text="$msg")
  body=$(echo "$resp" | sed -e 's/HTTP_STATUS\:.*//g')
  code=$(echo "$resp" | tr -d '\n' | sed -e 's/.*HTTP_STATUS://')
  if [ "$code" != "200" ]; then
    log "❌ Telegram send failed ($code): $body"
    echo "❌ Telegram send failed ($code): $body" >&2
    return 1
  fi
  log "✅ Telegram message sent."
}

# === Logs source (for churn/timeout scan) ===
if [[ -z "${COSMO_LOG:-}" ]]; then
  for p in \
    "/mnt/nvme/qubetics/cosmovisor.log" \
    "/var/log/qubetics/cosmovisor.log" \
    "/var/log/qubetics/qubetics.log" \
    "/mnt/nvme/qubetics/qubetics.log"
  do
    [[ -r "$p" ]] && COSMO_LOG="$p" && break
  done
fi
: "${COSMO_LOG:=/mnt/nvme/qubetics/cosmovisor.log}"

# === IFACE detection (env override -> default route -> first non-virtual -> eth0) ===
if [[ -z "${IFACE:-}" ]]; then
  IFACE="$(ip route show default 2>/dev/null | awk '/^default/ {for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
fi
if [[ -z "${IFACE:-}" ]]; then
  IFACE="$(ls -1 /sys/class/net | grep -Ev '^(lo|docker|veth|br-)' | head -n1)"
fi
: "${IFACE:=wlp4s0}"   # your known Wi‑Fi NIC; change to enpXsY if you wire up Ethernet

# === Background IFACE sampler (10s) writing JSONL; single instance guarded by lock+PID ===
SAMPLE_PERIOD="${SAMPLE_PERIOD:-10}"
STATE_DIR="${STATE_DIR:-/var/tmp}"
state_file="${STATE_DIR}/validator_ifstats_${IFACE}.jsonl"
lock_file="${STATE_DIR}/validator_ifstats_${IFACE}.lock"
pid_file="${STATE_DIR}/validator_ifstats_${IFACE}.pid"

start_iface_sampler() {
  mkdir -p "$STATE_DIR"
  if [ -f "$pid_file" ] && ps -p "$(cat "$pid_file" 2>/dev/null)" > /dev/null 2>&1; then
    return
  fi
  nohup bash -c "
    exec 9>\"$lock_file\"
    if ! flock -n 9; then exit 0; fi
    echo \$\$ > \"$pid_file\"
    PATH=$PATH
    while true; do
      t=\$(date +%s)
      rx=\$(cat /sys/class/net/${IFACE}/statistics/rx_bytes 2>/dev/null || echo)
      tx=\$(cat /sys/class/net/${IFACE}/statistics/tx_bytes 2>/dev/null || echo)
      if [[ -n \"\$rx\" && -n \"\$tx\" ]]; then
        echo \"{\\\"ts\\\":\${t},\\\"rx\\\":\${rx},\\\"tx\\\":\${tx}}\" >> \"$state_file\"
        [ \$(wc -l < \"$state_file\" 2>/dev/null || echo 0) -gt 2000 ] && tail -n 2000 \"$state_file\" > \"${state_file}.tmp\" && mv \"${state_file}.tmp\" \"$state_file\"
      fi
      sleep ${SAMPLE_PERIOD}
    done
  " >/dev/null 2>&1 &
}
start_iface_sampler

# --- quick live 5s iface sample (decimal MB/s) -> globals live_rx_mbs/live_tx_mbs ---
quick_iface_sample() {
  local _iface="${1:-$IFACE}" _secs="${2:-5}" r1 t1 r2 t2
  r1=$(cat "/sys/class/net/${_iface}/statistics/rx_bytes" 2>/dev/null || echo 0)
  t1=$(cat "/sys/class/net/${_iface}/statistics/tx_bytes" 2>/dev/null || echo 0)
  sleep "$_secs"
  r2=$(cat "/sys/class/net/${_iface}/statistics/rx_bytes" 2>/dev/null || echo 0)
  t2=$(cat "/sys/class/net/${_iface}/statistics/tx_bytes" 2>/dev/null || echo 0)
  read -r live_rx_mbs live_tx_mbs <<EOF
$(python3 - <<PY
r1,r2,t1,t2,secs = map(int, "${r1} ${r2} ${t1} ${t2} ${_secs}".split())
print(f"{(r2-r1)/secs/1048576:.3f} {(t2-t1)/secs/1048576:.3f}")
PY
)
EOF
}

# === 3m/10m Metrics Collector (uses sampler file + fallbacks) ===
compute_3m_metrics() {
  local ts_now ts_cutoff
  ts_now="$(now_ts)"; ts_cutoff="$(( ts_now - WINDOW_SECS ))"

  # Inbound peers now + avg
  local netinfo
  netinfo="$(curl -sf --max-time 3 "${NODE_RPC}/net_info" 2>/dev/null || echo)"
  inbound_now="$(echo "$netinfo" | jq '[.result.peers[]? | select(.is_outbound==false or .is_outbound=="false")] | length' 2>/dev/null || echo 0)"
  inbound_avg_3m="$inbound_now"

  # Peer churn + precommit timeouts from cosmovisor log
  peer_added_3m=0; peer_removed_3m=0; timeout_precommit_3m=0
  if [[ -r "${COSMO_LOG}" ]]; then
    while IFS= read -r line; do
      ts="$(echo "$line" | sed -n 's/^\([0-9T:\-\.Z\+]*\).*/\1/p' | head -n1)"
      if [[ -n "$ts" ]]; then
        epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
        if [[ "$epoch" -ge "$ts_cutoff" ]]; then
          echo "$line" | grep -q -E "Added peer|added peer|Connected to peer" && peer_added_3m=$((peer_added_3m+1))
          echo "$line" | grep -q -E "Removed peer|removed peer|Disconnected from peer|peer down|Stopping peer|stopped peer" && peer_removed_3m=$((peer_removed_3m+1))
          echo "$line" | grep -qiE "timeout[_ ]precommit|Timed out.*Precommit|precommit timeout|step:.*Precommit" && timeout_precommit_3m=$((timeout_precommit_3m+1))
        fi
      fi
    done < <(tail -n 50000 "${COSMO_LOG}")
  fi

  # Gateway RTT/loss
  gw_rtt_ms_avg=""; gw_loss_pc_avg=""
  local gw; gw="$(ip route | awk '/default/ {print $3; exit}')"
  if command -v ping >/dev/null 2>&1 && [[ -n "$gw" ]]; then
    out="$(ping -c 5 -i 0.2 -w 2 "$gw" 2>/dev/null || true)"
    loss="$(echo "$out" | awk -F',' '/packet loss/ {gsub(/%/, "", $3); gsub(/ /, "", $3); print $3}')"
    rtt="$(echo "$out" | awk -F'/' '/rtt|round-trip/ {print $5}')"
    [[ -n "$rtt" ]] && gw_rtt_ms_avg="$rtt"
    [[ -n "$loss" ]] && gw_loss_pc_avg="$loss"
  fi

  # Gossip via IFACE bytes with pruning & bootstrap
  local tmp_prune lines_cnt line_first line_last ts_first ts_last rx_first tx_first rx_last tx_last rx_delta tx_delta elapsed
  tmp_prune="$(mktemp 2>/dev/null || echo /tmp/ifstats.$$)"
  awk -v cutoff="$ts_cutoff" '
    BEGIN{FS="[,:}]"}
    { for(i=1;i<=NF;i++) if($i ~ /"ts"/) { if($(i+1) >= cutoff) { print $0; break } } }
  ' "${state_file}" > "${tmp_prune}" 2>/dev/null || true
  mv "${tmp_prune}" "${state_file}" 2>/dev/null || true

  lines_cnt="$(wc -l < "${state_file}" 2>/dev/null || echo 0)"
  if [[ "${lines_cnt}" -lt 2 ]]; then
    # inline quick bootstrap if sampler is fresh
    for _ in 1 2 3; do
      t="$(now_ts)"
      b1="$(cat /sys/class/net/${IFACE}/statistics/rx_bytes 2>/dev/null || echo)"
      b2="$(cat /sys/class/net/${IFACE}/statistics/tx_bytes 2>/dev/null || echo)"
      [[ -n "$b1" && -n "$b2" ]] && echo "{\"ts\":${t},\"rx\":${b1},\"tx\":${b2}}" >> "${state_file}"
      sleep 2
    done
  fi

  line_first="$(head -n 1 "${state_file}" 2>/dev/null)"
  line_last="$(tail -n 1 "${state_file}" 2>/dev/null)"
  gossip_rx_3m=0; gossip_tx_3m=0; gossip_rx_3m_h="0B"; gossip_tx_3m_h="0B"; gossip_rx_mbs=""; gossip_tx_mbs=""

  if [[ -n "$line_first" && -n "$line_last" ]]; then
    ts_first="$(echo "$line_first" | jq -r '.ts' 2>/dev/null || echo)"
    ts_last="$(echo "$line_last" | jq -r '.ts' 2>/dev/null || echo)"
    if [[ -n "$ts_first" && -n "$ts_last" && "$ts_last" -gt "$ts_first" ]]; then
      rx_first="$(echo "$line_first" | jq -r '.rx' 2>/dev/null || echo 0)"
      tx_first="$(echo "$line_first" | jq -r '.tx' 2>/dev/null || echo 0)"
      rx_last="$(echo "$line_last"  | jq -r '.rx' 2>/dev/null || echo 0)"
      tx_last="$(echo "$line_last"  | jq -r '.tx' 2>/dev/null || echo 0)"
      rx_delta="$(( rx_last - rx_first ))"; (( rx_delta < 0 )) && rx_delta=0
      tx_delta="$(( tx_last - tx_first ))"; (( tx_delta < 0 )) && tx_delta=0
      elapsed="$(( ts_last - ts_first ))"
      gossip_rx_3m="$rx_delta"; gossip_tx_3m="$tx_delta"
      gossip_rx_3m_h="$(human_bytes "${rx_delta}")"
      gossip_tx_3m_h="$(human_bytes "${tx_delta}")"
      if (( elapsed > 0 )); then
        gossip_rx_mbs="$(python3 - <<PY
b=${rx_delta}; w=${elapsed}
print(round((b/1048576)/w, 3))
PY
)"
        gossip_tx_mbs="$(python3 - <<PY
b=${tx_delta}; w=${elapsed}
print(round((b/1048576)/w, 3))
PY
)"
      fi
    fi
  fi
}

# === Start ===
log "🔍 Starting validator health check..."

# --- Node status ---
status="$(curl -s "$NODE_RPC/status")"
if [ -z "$status" ] || [ "$status" = "null" ]; then
  log "❌ Node RPC empty"
  send_telegram_alert "❌ *Node is unreachable* at $(date)" || true
  exit 1
fi
catching_up=$(echo "$status"  | jq -r .result.sync_info.catching_up)
latest_block=$(echo "$status" | jq -r .result.sync_info.latest_block_height)
latest_time=$(echo "$status"  | jq -r .result.sync_info.latest_block_time)
sync_status="✅ *Node is synced*"
[ "$catching_up" = "true" ] && sync_status="⏳ *Node is catching up*"

# --- Peers (outbound only) ---
if net_json="$(curl -sf "$NODE_RPC/net_info" 2>/dev/null)"; then
  outbound_peers="$(
    echo "$net_json" \
    | jq -r '[(.result.peers // [])[] | select((.is_outbound==true) or (.is_outbound=="true"))] | length'
  )"
else
  net_json="$(run_q net-info -o json 2>/dev/null || echo '{}')"
  outbound_peers="$(
    echo "$net_json" \
    | jq -r '[(.peers // [])[] | select((.is_outbound==true) or (.is_outbound=="true"))] | length'
  )"
fi
: "${outbound_peers:=0}"

# --- Validator info ---
val_info="$(run_q query staking validator "$VALIDATOR_ADDR" --node="$NODE_RPC" -o json 2>/dev/null)"
if [ -z "$val_info" ] || [ "$val_info" = "null" ]; then
  log "❌ validator info fetch failed"
  send_telegram_alert "❌ *Validator info fetch failed* at $(date)" || true
  exit 1
fi

is_jailed=$(echo "$val_info" | jq -r .jailed)
[ "$is_jailed" = "true" ] && jailed_status="🚨 *Validator is JAILED*" || jailed_status="🟢 *Validator is ACTIVE*"
commission=$(echo "$val_info" | jq -r .commission.commission_rates.rate)
commission_pct=$(fmt_pct "$(bc -l <<< "$commission * 100")")

# Delegators & total stake
delegations_json="$(run_q query staking delegations-to "$VALIDATOR_ADDR" --node="$NODE_RPC" --count-total -o json 2>/dev/null)"
delegator_total=$(echo "$delegations_json" | jq -r '.pagination.total // "0"')
if [[ "$delegator_total" =~ ^[0-9]+$ && "$delegator_total" -gt 0 ]]; then
  delegator_count="$delegator_total"
else
  delegator_count=$(echo "$delegations_json" | jq -r '.delegation_responses | length')
fi

val_tokens_raw=$(echo "$val_info" | jq -r '.tokens // "0"')
total_stake_tics=$(bc <<< "scale=6; $val_tokens_raw / 1000000000000000000")
total_stake_tics_fmt=$(fmt_tics "$total_stake_tics")

# Self-delegation
self_delegation=$(run_q query staking delegation "$WALLET_ADDR" "$VALIDATOR_ADDR" --node="$NODE_RPC" --home="$DAEMON_HOME" -o json 2>/dev/null | jq -r '.balance.amount // "0"')
self_tics=$(fmt_tics "$(bc -l <<< "$self_delegation / 1000000000000000000")")

# === SLASHING INFO ===
cons_addr_b32="$(run_q tendermint show-address --home "$DAEMON_HOME" 2>/dev/null || true)"
target_addr="${cons_addr_b32:-$VALCONS_ADDR}"
signing_record=$(
  run_q query slashing signing-infos --node="$NODE_RPC" -o json \
  | jq -r --arg V "$target_addr" '.info[]? | select((.address // .cons_address // "") == $V)'
)
missed_blocks=$(echo "$signing_record" | jq -r '.missed_blocks_counter // empty')
tombstoned=$(echo "$signing_record"    | jq -r '.tombstoned // empty')
jailed_until=$(echo "$signing_record"  | jq -r '.jailed_until // empty')
[[ -z "$missed_blocks" ]] && missed_blocks="N/A"
[[ -z "$tombstoned"    ]] && tombstoned="unknown"

uptime_pct="N/A"
if [[ "$missed_blocks" =~ ^[0-9]+$ ]]; then
  signed_window=$(run_q query slashing params --node="$NODE_RPC" -o json | jq -r '.signed_blocks_window // 0')
  if [[ "$signed_window" =~ ^[0-9]+$ && "$signed_window" -gt 0 ]]; then
    uptime_pct=$(awk -v m="$missed_blocks" -v w="$signed_window" 'BEGIN{printf "%.2f", (w-m)/w*100}')
  fi
fi

# Slashing history over window
start_h=$(( latest_block > SLASH_LOOKBACK_BLOCKS ? latest_block - SLASH_LOOKBACK_BLOCKS + 1 : 1 ))
slashes_json=$(run_q query distribution slashes "$VALIDATOR_ADDR" "$start_h" "$latest_block" --node="$NODE_RPC" -o json 2>/dev/null)
slash_count=$(echo "$slashes_json" | jq -r '.slashes | length')
recent_fractions=$(echo "$slashes_json" | jq -r '[.slashes[-3:][]?.fraction] | map(tostring) | join(", ")')
[[ -z "$recent_fractions" || "$recent_fractions" == "null" ]] && recent_fractions="none"

# === P2P/gateway + gossip ===
compute_3m_metrics
# quick live 5s throughput on the same IFACE
quick_iface_sample "$IFACE" 5

# === Message ===
msg="📡 *Block Dock Validator Node Health Check (every 10 minutes)*
$jailed_status
$sync_status
🧱 Latest block: *$latest_block*
🕒 Block time: \`$latest_time\`
🔌 Outbound peers: *$outbound_peers*
👥 Delegators: *$delegator_count*
💎 Total stake (validator): *$total_stake_tics_fmt TICS*
📈 Uptime (window-based): *${uptime_pct}%*
⚰️ Tombstoned: *$([ "$tombstoned" = "true" ] && echo Yes || echo No)*   🔒 Jail: *$([[ "$jailed_until" = "Not jailed" ]] && echo Not\ jailed || echo "$jailed_until")*
📜 Slashing events (last ${SLASH_LOOKBACK_BLOCKS} blocks): *$slash_count*  (recent: $recent_fractions)
💰 Commission rate: *${commission_pct}%*
🪙 Self-delegated: *$self_tics TICS*"

msg+="
🔌 Inbound peers (win avg): *${inbound_avg_3m}*
🔄 Peer churn (win): +${peer_added_3m} / -${peer_removed_3m}
⏱️ Precommit timeouts (win): *${timeout_precommit_3m}*"
if [[ -n "${gw_rtt_ms_avg}" || -n "${gw_loss_pc_avg}" ]]; then
  msg+="
🌐 Gateway: *${gw_rtt_ms_avg:-?} ms*, loss *${gw_loss_pc_avg:-?}%*"
fi
msg+="
🗣️ Gossip (win): *${gossip_rx_3m_h} RX* / *${gossip_tx_3m_h} TX*"
if [[ -n "${gossip_rx_mbs}" || -n "${gossip_tx_mbs}" ]]; then
  msg+="
🚿 Gossip rate (avg): *${gossip_rx_mbs:-0} MB/s RX* / *${gossip_tx_mbs:-0} MB/s TX*"
fi
msg+="
⚡ Live (5s): *${live_rx_mbs} MB/s RX* / *${live_tx_mbs} MB/s TX*"

msg+="
📅 Updated: \`$(TZ=America/Denver date)\`)"

# === De-dupe + send ===
new_hash=$(echo "$msg" | md5sum | awk '{print $1}')
prev_hash=$(cat "$ALERT_FILE" 2>/dev/null || true)

if [ "$new_hash" != "$prev_hash" ]; then
  if ! send_telegram_alert "$msg"; then
    exit 1
  fi
  echo "$new_hash" > "$ALERT_FILE"
else
  log "ℹ️ No change in status — no alert sent."
fi

exit 0