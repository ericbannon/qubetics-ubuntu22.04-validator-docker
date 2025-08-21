#!/usr/bin/env bash
# netstab_plus.sh
# Sample p2p health every INTERVAL_SEC and append to CSV.
# Every WINDOW_SEC, also append a rolling #SUMMARY row.

set -euo pipefail

# -------- Config (override via env or flags) --------
RPC_URL="${RPC_URL:-http://127.0.0.1:26657}"
CSV_FILE="${CSV_FILE:-/tmp/netstab.csv}"
INTERVAL_SEC="${INTERVAL_SEC:-10}"          # 10s sample cadence
WINDOW_SEC="${WINDOW_SEC:-1800}"            # 30m rolling window
GW_PING_COUNT="${GW_PING_COUNT:-3}"         # pings per sample
JOURNAL_UNIT="${JOURNAL_UNIT:-}"            # e.g. "qubetics.service" (optional)
LOG_SCAN_SEC="${LOG_SCAN_SEC:-10}"          # how far back to count timeouts each sample

usage() {
  cat <<EOF
Usage: $0 [--rpc URL] [--file PATH] [--interval-sec N] [--window-sec N]
          [--journal-unit NAME] [--log-scan-sec N] [--gw-ping-count N]

Writes samples to CSV every INTERVAL_SEC and appends a #SUMMARY row every WINDOW_SEC.
Sample columns:
  ts,outbound,new,lost,timeout_prevote,timeout_precommit,gw_rtt_ms,gw_loss_pct
Summary columns:
  #SUMMARY,from_ts,to_ts,steps,avg_outbound,total_new,total_lost,sum_timeout_prevote,sum_timeout_precommit,avg_gw_rtt_ms,avg_gw_loss_pct
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpc) RPC_URL="$2"; shift 2 ;;
    --file) CSV_FILE="$2"; shift 2 ;;
    --interval-sec) INTERVAL_SEC="$2"; shift 2 ;;
    --window-sec) WINDOW_SEC="$2"; shift 2 ;;
    --journal-unit) JOURNAL_UNIT="$2"; shift 2 ;;
    --log-scan-sec) LOG_SCAN_SEC="$2"; shift 2 ;;
    --gw-ping-count) GW_PING_COUNT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac 
done

ts_now() { date -u +"%Y-%m-%dT%H:%M:%S"; }

ensure_csv_header() {
  if [[ ! -s "$CSV_FILE" ]] || ! head -1 "$CSV_FILE" | grep -q '^ts,'; then
    echo "ts,outbound,new,lost,timeout_prevote,timeout_precommit,gw_rtt_ms,gw_loss_pct" >>"$CSV_FILE"
  fi
}

# Track previous peer set to compute new/lost
PREV_SET_FILE="$(mktemp -t netstab_prev.XXXXXX)"
trap 'rm -f "$PREV_SET_FILE" "$WIN_FILE"' EXIT
: > "$PREV_SET_FILE"

# Rolling window scratch file (keeps only the most recent N lines)
WIN_FILE="$(mktemp -t netstab_win.XXXXXX)"
: > "$WIN_FILE"

# Expected lines in window
lines_in_window() {
  python3 - "$INTERVAL_SEC" "$WINDOW_SEC" <<'PY'
import sys
i,w = map(float, sys.argv[1:3])
print(max(1, int(round(w / i))))
PY
}

# ---- peer snapshot helpers ----
get_peers_snapshot() {
  local json outc ids
  if ! json="$(curl -sS --max-time 2 "$RPC_URL/net_info")"; then
    echo "0"; echo ""; return
  fi
  outc="$(jq -r '[.result.peers[]? | select(.is_outbound==true)] | length' <<<"$json" 2>/dev/null || echo 0)"
  ids="$(jq -r '.result.peers[]?.node_info.id' <<<"$json" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  echo "${outc:-0}"
  echo "${ids:-}"
}

diff_sets() {
  local prev="$1" curr="$2"
  local new=0 lost=0
  declare -A P C
  for p in $prev; do P["$p"]=1; done
  for c in $curr; do C["$c"]=1; done
  for c in $curr; do [[ -z "${P[$c]:-}" ]] && ((new++)); done
  for p in $prev; do [[ -z "${C[$p]:-}" ]] && ((lost++)); done
  echo "$new" "$lost"
}

scan_timeouts() {
  local tprev=0 tprecommit=0
  if [[ -n "$JOURNAL_UNIT" ]] && command -v journalctl >/dev/null 2>&1; then
    local since_ts
    since_ts="$(date -u --date="@$(($(date +%s)-LOG_SCAN_SEC))" +"%Y-%m-%d %H:%M:%S")"
    local slice
    slice="$(journalctl -u "$JOURNAL_UNIT" --since "$since_ts" --no-pager 2>/dev/null || true)"
    tprev="$(grep -ciE 'timeout_prevote|prevote timeout' <<<"$slice" || true)"
    tprecommit="$(grep -ciE 'timeout_precommit|precommit timeout' <<<"$slice" || true)"
  fi
  echo "${tprev:-0}" "${tprecommit:-0}"
}

gw_ping() {
  local gw
  gw="$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')"
  if [[ -z "$gw" ]]; then echo "0" "100"; return; fi
  local out rt loss
  out="$(ping -n -c "$GW_PING_COUNT" -w 2 "$gw" 2>/dev/null || true)"
  rt="$(awk -F'/' '/rtt/ {print $5}' <<<"$out")"
  [[ -z "$rt" ]] && rt=0
  loss="$(awk -F',' '/packet loss/ {gsub(/%| /,""); print $(NF-1)}' <<<"$out")"
  [[ -z "$loss" ]] && loss=100
  echo "$rt" "$loss"
}

append_sample() {
  local ts="$1" outbound="$2" new="$3" lost="$4" tprev="$5" tprecommit="$6" rtt="$7" loss="$8"
  echo "$ts,$outbound,$new,$lost,$tprev,$tprecommit,$rtt,$loss" >>"$CSV_FILE"
  echo "$ts,$outbound,$new,$lost,$tprev,$tprecommit,$rtt,$loss" >>"$WIN_FILE"
}

trim_window() {
  local max_lines
  max_lines="$(lines_in_window)"
  local n
  n=$(wc -l < "$WIN_FILE" || echo 0)
  if (( n > max_lines )); then
    tail -n "$max_lines" "$WIN_FILE" > "${WIN_FILE}.new" && mv "${WIN_FILE}.new" "$WIN_FILE"
  fi
}

append_summary() {
  # compute aggregates from current window file
  local lines
  lines=$(grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$WIN_FILE" | wc -l | tr -d ' ')
  (( lines == 0 )) && return

  local from_ts to_ts
  from_ts="$(head -n 1 "$WIN_FILE" | cut -d',' -f1)"
  to_ts="$(tail -n 1 "$WIN_FILE" | cut -d',' -f1)"

  # sums & avgs
  # shellcheck disable=SC2016
  local sums avg_outbound avg_rtt avg_loss tot_new tot_lost tot_prev tot_precommit
  sums="$(awk -F',' '
    BEGIN{out=0;new=0;lost=0;prv=0;prc=0;rtt=0;los=0;cnt=0}
    /^[0-9]/ {out+=($2+0); new+=($3+0); lost+=($4+0); prv+=($5+0); prc+=($6+0); rtt+=($7+0); los+=($8+0); cnt++}
    END{printf "%d,%d,%d,%d,%d,%.6f,%.6f,%d", out,new,lost,prv,prc,rtt,los,cnt}
  ' "$WIN_FILE")"

  IFS=',' read -r s_out s_new s_lost s_prev s_precommit s_rtt s_loss s_cnt <<<"$sums"

  # integer-safe averages
  avg_outbound=$(python3 - <<PY
s_out=$s_out; s_cnt=$s_cnt
print("{:.3f}".format(s_out/s_cnt if s_cnt else 0))
PY
)
  avg_rtt=$(python3 - <<PY
s_rtt=$s_rtt; s_cnt=$s_cnt
print("{:.3f}".format(s_rtt/s_cnt if s_cnt else 0))
PY
)
  avg_loss=$(python3 - <<PY
s_loss=$s_loss; s_cnt=$s_cnt
print("{:.3f}".format(s_loss/s_cnt if s_cnt else 0))
PY
)
  tot_new="$s_new"
  tot_lost="$s_lost"
  tot_prev="$s_prev"
  tot_precommit="$s_precommit"

  echo "#SUMMARY,$from_ts,$to_ts,$s_cnt,$avg_outbound,$tot_new,$tot_lost,$tot_prev,$tot_precommit,$avg_rtt,$avg_loss" >>"$CSV_FILE"
}

# ---- main loop ----
ensure_csv_header
last_summary_epoch=$(date +%s)

while :; do
  ts="$(ts_now)"

  # snapshot peers & churn
  read -r outbound < <(get_peers_snapshot)
  read -r curr_ids < <(get_peers_snapshot | sed -n '2p')
  prev_ids="$(cat "$PREV_SET_FILE" || true)"
  read -r new lost < <(diff_sets "$prev_ids" "$curr_ids")
  echo "$curr_ids" > "$PREV_SET_FILE"

  # timeouts
  read -r tprev tprecommit < <(scan_timeouts)

  # gateway quality
  read -r rtt loss < <(gw_ping)

  append_sample "$ts" "$outbound" "$new" "$lost" "$tprev" "$tprecommit" "$rtt" "$loss"
  trim_window

  # summary timer
  now_epoch=$(date +%s)
  if (( now_epoch - last_summary_epoch >= WINDOW_SEC )); then
    append_summary
    last_summary_epoch="$now_epoch"
  fi

  sleep "$INTERVAL_SEC"
done