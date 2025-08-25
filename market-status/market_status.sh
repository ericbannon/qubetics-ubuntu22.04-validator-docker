#!/usr/bin/env bash
set -euo pipefail

OUT="/var/www/tics-blockdock/market.json"
TMP="${OUT}.tmp"

# 1) Latest price (public)
price=$(curl -s 'https://api.coinstore.com/api/v1/ticker/price' \
  | jq -r '.data[] | select(.symbol=="TICSUSDT") | .price' )

# 2) 24h volume (try market/tickers; if missing, fall back to kline)
raw_tickers=$(curl -s 'https://api.coinstore.com/api/v1/market/tickers' || true)
vol_quote=$(printf '%s' "$raw_tickers" \
  | jq -r '.. | objects | select(has("symbol") and .symbol=="TICSUSDT") | .volume' 2>/dev/null | head -n1)

# Fallback: estimate USD vol from daily kline (amount ~ base volume)
if [[ -z "${vol_quote:-}" || "${vol_quote}" == "null" ]]; then
  kline=$(curl -s 'https://api.coinstore.com/api/v1/market/kline/TICSUSDT?period=1day&size=1' || true)
  base_amt=$(printf '%s' "$kline" | jq -r '.data.item[0].amount // empty')
  if [[ -n "${price:-}" && -n "${base_amt:-}" ]]; then
    # Multiply base volume by last price to estimate USD volume
    vol_quote=$(python3 - <<PY
p = float("${price}")
a = float("${base_amt}")
print(f"{p*a:.8f}")
PY
)
  fi
fi

jq -n \
  --arg now "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg price_usd "${price:-}" \
  --arg vol_usd "${vol_quote:-}" \
'{
  generated_at: $now,
  price_usd: ($price_usd|tonumber? // null),
  volume_24h_usd: ($vol_usd|tonumber? // null),
  source: "coinstore"
}' > "$TMP" && mv "$TMP" "$OUT" && chmod 644 "$OUT"