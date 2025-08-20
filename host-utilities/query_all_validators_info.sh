#!/usr/bin/env bash
set -euo pipefail

# Config
CONTAINER="${CONTAINER:-validator-node}"
NODE_TCP="${NODE_TCP:-tcp://127.0.0.1:26657}"
NODE_HTTP="${NODE_HTTP:-http://127.0.0.1:26657}"
LIMIT=1000
OUT="validators_start_times.csv"

# Require jq
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

echo "operator_address,moniker,start_height,start_time_utc" > "$OUT"

# Get all validators (paged)
page=1
while :; do
  json=$(docker exec "$CONTAINER" qubeticsd q staking validators \
          --page $page --limit $LIMIT -o json 2>/dev/null || true)
  n=$(echo "${json:-}" | jq '.validators|length? // 0')
  (( n == 0 )) && break
  echo "$json" | jq -c '.validators[]' | while read -r v; do
    op=$(echo "$v" | jq -r '.operator_address')
    mon=$(echo "$v" | jq -r '.description.moniker' | tr ',\n' ' ')
    pk=$(echo "$v" | jq -c '{ "@type": .consensus_pubkey."@type", "key": .consensus_pubkey.key }')

    si=$(docker exec "$CONTAINER" qubeticsd query slashing signing-info "$pk" \
           --node "$NODE_TCP" -o json 2>/dev/null || true)

    H=$(echo "${si:-}" | jq -r '.val_signing_info.start_height // .start_height // empty')
    if [[ -n "$H" && "$H" =~ ^[0-9]+$ ]]; then
      T=$(curl -s "$NODE_HTTP/block?height=$H" | jq -r '.result.block.header.time // empty')
      echo "$op,$mon,$H,${T:-NA}" >> "$OUT"
    else
      echo "$op,$mon,NA,NA" >> "$OUT"
    fi
  done
  page=$((page+1))
done

echo "✅ Wrote $OUT"
