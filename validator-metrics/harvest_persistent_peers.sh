#!/usr/bin/env bash
# Harvest stable outbound peers over time and build a persistent_peers string.
# Defaults: 10 minutes total, sample every 20s, select top 10.

set -euo pipefail

RPC="${RPC:-http://localhost:26657}"
DURATION_SEC="${DURATION_SEC:-600}"   # total time (10 min)
INTERVAL_SEC="${INTERVAL_SEC:-20}"    # sample period
TOP="${TOP:-10}"                      # how many to keep
OUT="${OUT:-/tmp/peers_seen.txt}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
need curl; need jq; need awk; need date

rm -f "$OUT"
samples=0
echo "Sampling outbound peers for $DURATION_SEC s every $INTERVAL_SEC s… (RPC=$RPC)"
end=$(( $(date +%s) + DURATION_SEC ))
while [ "$(date +%s)" -lt "$end" ]; do
  ts=$(date +%FT%T)
  curl -sf "$RPC/net_info" \
  | jq -r '
      .result.peers[]
      | select(.is_outbound==true)
      | "\(.node_info.id)@\(.remote_ip):\((.node_info.listen_addr | capture(":(?<p>[0-9]+)$").p // "26656"))"
    ' 2>/dev/null \
  | sort -u | sed "s/^/$ts /" >> "$OUT" || true
  samples=$((samples+1))
  sleep "$INTERVAL_SEC"
done

echo
echo "=== Results (samples: $samples) ==="

# Build counts per peer
cut -d' ' -f2- "$OUT" | sort | uniq -c | sort -k1,1nr > /tmp/peer_counts.txt

# Pretty table: hits, rate, peer
awk -v S="$samples" '
  BEGIN{ printf "%-5s %-6s  %s\n", "hits", "rate%", "peer" }
  { rate = (100.0*$1)/S; printf "%-5d %6.1f  %s\n", $1, rate, $2 }
' /tmp/peer_counts.txt

echo
echo "=== Top '"$TOP"' peers by stability ==="
head -n "$TOP" /tmp/peer_counts.txt \
| awk '{print $2}' \
| awk 'BEGIN{ORS=""; print "persistent_peers = \""} {if(NR>1)print ","; printf "%s",$0} END{print "\""}'

echo
echo "(Raw samples in: '"$OUT"')"

