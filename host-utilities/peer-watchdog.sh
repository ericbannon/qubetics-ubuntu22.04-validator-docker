#!/usr/bin/env bash
set -euo pipefail

# peer_stability_sample.sh — sample peers & churn, then summarize
# Usage (defaults): DUR=60 INT=30 /root/peer_stability_sample.sh
DUR="${DUR:-60}"          # minutes to sample
INT="${INT:-30}"          # seconds between samples

OUT_DIR="/mnt/nvme"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_CSV="$OUT_DIR/peer_log_${STAMP}.csv"
OUT_SUM="$OUT_DIR/peer_log_${STAMP}.summary.txt"

TMP_PREV="$(mktemp /tmp/peers.prev.XXXXXX)"
TMP_CUR="$(mktemp /tmp/peers.cur.XXXXXX)"
TMP_NET="/tmp/net_info.json"

# deps
command -v curl >/dev/null || { echo "curl not found"; exit 1; }
command -v jq   >/dev/null || { echo "jq not found"; exit 1; }

echo "ts,n_peers,joins,leaves" > "$OUT_CSV"

end=$(( $(date +%s) + DUR*60 ))
while [ "$(date +%s)" -lt "$end" ]; do
  ts="$(date -Is)"
  if curl -s 127.0.0.1:26657/net_info > "$TMP_NET"; then
    count=$(jq '.result.peers | length' "$TMP_NET")
    jq -r '.result.peers[].node_info.id' "$TMP_NET" | sort > "$TMP_CUR"
    joins=0; leaves=0
    if [ -s "$TMP_PREV" ]; then
      joins=$(comm -13 "$TMP_PREV" "$TMP_CUR" | wc -l)
      leaves=$(comm -23 "$TMP_PREV" "$TMP_CUR" | wc -l)
    fi
    echo "$ts,$count,$joins,$leaves" >> "$OUT_CSV"
    mv "$TMP_CUR" "$TMP_PREV"
  fi
  sleep "$INT"
done

# Summary
awk -F, 'NR>1 {n++; s+=$2; ss+=$2*$2; if(min==""||$2<min)min=$2; if(max==""||$2>max)max=$2; tj+=$3; tl+=$4}
END{
  if(n>0){
    avg=s/n; var=(ss/n)-(avg*avg); if(var<0)var=0; sd=sqrt(var);
    printf("Samples: %d\nAverage peers: %.2f\nMin peers: %d\nMax peers: %d\nStd dev: %.2f\nTotal joins: %d\nTotal leaves: %d\n",
           n, avg, min, max, sd, tj, tl)
  } else {print "No samples"}
}' "$OUT_CSV" | tee "$OUT_SUM"

# Optional: keep a latest pointers
ln -sf "$(basename "$OUT_CSV")" "$OUT_DIR/peer_log_latest.csv"
ln -sf "$(basename "$OUT_SUM")" "$OUT_DIR/peer_log_latest.summary.txt"
