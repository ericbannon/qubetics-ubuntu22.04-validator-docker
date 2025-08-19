#!/usr/bin/env bash
set -euo pipefail

# Paths / toggles
if [ -f /mnt/nvme/qubetics/config/addrbook.json ]; then
  ADDRBOOK="/mnt/nvme/qubetics/config/addrbook.json"
else
  ADDRBOOK="${ADDRBOOK:-$HOME/.qubetics/config/addrbook.json}"
fi
RPC_LOCAL="${RPC_LOCAL:-http://127.0.0.1:26657}"
SKIP_ADDRBOOK="${SKIP_ADDRBOOK:-0}"   # 1 = skip probing addrbook
WHOIS_ON="${WHOIS_ON:-0}"             # 1 = try whois enrichment (slower)

# Your Top-10 by gossip
TOP10_IDS=( 86a47dc66fa1a4117fef560c799433d392e30d51
            1cb538b9950c4f3ce89848101e6698bbf68ad40c
            ad8e2053470a347d87f5125d54fe04d86155f7c4
            d8a4ba4a96989aeca33cd47b2becc35580ea474f
            41f8e8b5479374a21e69be09911a0c0dc6f41b23
            f874aca4075ce71b7e0fa62f882d7bb69aed9adc
            afd50019409285e303a332000e587b58584f56eb
            8db53566aa0b6447d73ad264aff918d59f0e20a4
            b2d55d190cd42de30182e80e1d65fd8bb05f7844
            65cb0de46806c3e50395110b84d22275a29150ca )

need() { command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }; }
need jq; need curl

is_top10() { local id="${1:-}"; for t in "${TOP10_IDS[@]}"; do [[ "$id" == "$t" ]] && { echo -n "Y"; return; }; done; echo -n "N"; }

asn_lookup() {
  [ "$WHOIS_ON" = "1" ] || { echo -n "-"; return; }
  command -v whois >/dev/null || { echo -n "-"; return; }
  local ip="${1:-}"
  whois -H "$ip" 2>/dev/null | awk -F': ' '
    tolower($1) ~ /originas|origin|aut-num|descr|netname|org-name|organization/ && $2 != "" {
      gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; if (++n==2) exit
    }' | paste -sd' / ' - 2>/dev/null || echo -n "-"
}

# Header (TSV)
printf "Source\tPeerID\tTop10\tMoniker\tIP\tPort\tAddrbookLastSuccess\tASN/Org\tRPC\n"

# --- 1) Current connections (authoritative monikers) ---
curl -s "${RPC_LOCAL}/net_info" \
| jq -c '.result.peers[]?' \
| while IFS= read -r line; do
    pid=$(jq -r '.node_info.id // empty' <<<"$line")
    mon=$(jq -r '.node_info.moniker // ""' <<<"$line")
    ip=$(jq -r '.remote_ip // ""' <<<"$line")
    port=$(jq -r '(.node_info.listen_addr | capture(":(?<p>[0-9]+)$").p) // "unknown"' <<<"$line")
    [ -z "$pid" ] && continue
    printf "net_info\t%s\t%s\t%s\t%s\t%s\t-\t%s\tlocal\n" \
      "$pid" "$(is_top10 "$pid")" "$mon" "$ip" "$port" "$(asn_lookup "$ip")"
  done

# --- 2) Addrbook scanning (robust per-entry parsing) ---
if [ "$SKIP_ADDRBOOK" != "1" ] && [ -f "$ADDRBOOK" ]; then
  jq -c '.addrs[]?' "$ADDRBOOK" \
  | while IFS= read -r line; do
      # Handle multiple shapes safely
      pid=$(jq -r '.id // .ip.id // .addr.id // empty' <<<"$line")
      ip=$(jq -r '.addr // .ip.ip // .ip // empty' <<<"$line")
      port=$(jq -r '.ip.port // .port // 26656' <<<"$line")
      last=$(jq -r '.last_success // .lastDialSuccess // "0001-01-01T00:00:00Z"' <<<"$line")
      [ -z "$pid" ] && continue
      [ -z "$ip" ]  && continue
      mon=$(curl -s --connect-timeout 1 --max-time 2 "http://${ip}:26657/status" \
            | jq -r '.result.node_info.moniker // empty' || true)
      if [ -z "$mon" ]; then mon="no-rpc"; rpc="closed"; else rpc="open"; fi
      printf "addrbook\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$pid" "$(is_top10 "$pid")" "$mon" "$ip" "$port" "$last" "$(asn_lookup "$ip")" "$rpc"
    done
fi
