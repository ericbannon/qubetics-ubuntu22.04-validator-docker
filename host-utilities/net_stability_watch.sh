#!/usr/bin/env bash
# net_stability_watch.sh
# Checks peer churn, consensus timeouts, and gateway health over time.

set -euo pipefail

RPC="${RPC:-http://localhost:26657}"
CN="${CN:-validator-node}"
LOG="${LOG:-/mnt/nvme/qubetics/cosmovisor.log}"

INTERVAL="${INTERVAL:-5}"   # seconds between samples
DURATION="${DURATION:-600}" # total seconds (10 min)

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
need curl; need jq; need docker; need awk; need ping

echo "Watching for $DURATION s (every $INTERVAL s). RPC=$RPC CN=$CN LOG=$LOG"
CSV="/tmp/netstab.csv"
echo "ts,outbound,new,lost,timeout_prevote,timeout_precommit,gw_rtt_ms,gw_loss_pct" > "$CSV"

start_ts=$(date +%s)
elapsed=0
samples=0
total_new=0
total_lost=0
prev_ids=""

# default gateway (host)
GW="$(ip route | awk '/^default/ {print $3; exit}')"

while [ "$elapsed" -lt "$DURATION" ]; do
  ts="$(date +%FT%T)"

  # peers
  ni="$(curl -sf "$RPC/net_info")"
  outbound="$(echo "$ni" | jq '[.result.peers[]|select(.is_outbound==true)]|length')"
  ids="$(echo "$ni" | jq -r '.result.peers[]|select(.is_outbound==true)|.node_info.id' | sort || true)"

  # churn (diff previous vs current)
  new="$(comm -13 <(printf '%s\n' $prev_ids 2>/dev/null) <(printf '%s\n' $ids 2>/dev/null) | wc -l | tr -d ' ')"
  lost="$(comm -23 <(printf '%s\n' $prev_ids 2>/dev/null) <(printf '%s\n' $ids 2>/dev/null) | wc -l | tr -d ' ')"
  prev_ids="$ids"
  total_new=$((total_new + new))
  total_lost=$((total_lost + lost))

  # consensus timeouts (last 200 lines)
  tprev="$(docker exec -i "$CN" sh -lc "tail -n 200 '$LOG' 2>/dev/null | grep -c 'RoundStepPrevoteWait' || true")"
  tprec="$(docker exec -i "$CN" sh -lc "tail -n 200 '$LOG' 2>/dev/null | grep -c 'RoundStepPrecommitWait' || true")"

  # gateway ping (3 pings, quick read)
  if [ -n "${GW:-}" ]; then
    PSTATS="$(ping -c 3 -w 3 "$GW" 2>/dev/null || true)"
    RTT="$(echo "$PSTATS" | awk -F'/' '/rtt|round-trip/ {print $5}')"
    LOSS="$(echo "$PSTATS" | awk -F', *' '/packets transmitted/ {print $3}' | tr -dc "0-9.")"
  else
    RTT="NA"; LOSS="NA"
  fi

  printf "%s,%s,%s,%s,%s,%s,%s,%s\n" \
    "$ts" "$outbound" "$new" "$lost" "$tprev" "$tprec" "${RTT:-NA}" "${LOSS:-NA}" | tee -a "$CSV" >/dev/null

  samples=$((samples+1))
  sleep "$INTERVAL"
  elapsed=$(( $(date +%s) - start_ts ))
done

# summary
churn_per_min=$(awk -v t=$((total_new+total_lost)) -v e="$elapsed" 'BEGIN{ if(e>0) printf "%.2f", (t/(e/60.0)); else print "0.00"; }')
echo
echo "=== Summary ==="
echo "Samples:          $samples  (every ${INTERVAL}s for ~${elapsed}s)"
echo "Total new peers:  $total_new"
echo "Total lost peers: $total_lost"
echo "Churn/min:        $churn_per_min"
echo "CSV written to:   $CSV"

