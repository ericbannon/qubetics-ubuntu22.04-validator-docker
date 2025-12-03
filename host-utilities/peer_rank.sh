#!/usr/bin/env bash
# Usage: bash ./bench_peers.sh peers.txt
# Output columns (TSV):
# tcp_ms_avg  tcp_ok/3  rpc_ms  rpc_ok  catching_up  lag  moniker  peer

PFILE="${1:-peers.txt}"
[[ -f "$PFILE" ]] || { echo "No such file: $PFILE" >&2; exit 1; }

TRIES=3
TCP_TIMEOUT=1
RPC_TIMEOUT=1

now_ns() {
  date +%s%N 2>/dev/null || python3 - <<'PY'
import time; print(int(time.time()*1e9))
PY
}

tcp_try() {
  local ip="$1" port="$2"
  local start end
  start="$(now_ns)"
  if timeout "$TCP_TIMEOUT" bash -lc "</dev/tcp/$ip/$port" 2>/dev/null \
     || (command -v nc >/dev/null && timeout "$TCP_TIMEOUT" nc -z "$ip" "$port" >/dev/null 2>&1); then
    end="$(now_ns)"; echo $(( (end - start) / 1000000 ))
  else
    echo 9999
  fi
}

# Get our local head height once, if available
MYH="$(curl -m 0.7 -s http://127.0.0.1:26657/status | jq -r '.result.sync_info.latest_block_height // 0' 2>/dev/null || echo 0)"
[[ "$MYH" =~ ^[0-9]+$ ]] || MYH=0

echo -e "tcp_ms_avg\ttcp_ok/3\trpc_ms\trpc_ok\tcatching_up\tlag\tmoniker\tpeer"

processed=0
while IFS= read -r peer || [[ -n "$peer" ]]; do
  # skip blank/space-only lines
  [[ "$peer" =~ ^[[:space:]]*$ ]] && continue
  ((processed++))

  ip="${peer#*@}"; ip="${ip%:*}"

  # TCP timings
  ok=0; sum=0
  for _ in 1 2 3; do
    ms="$(tcp_try "$ip" 26656)"
    [[ "$ms" -lt 9999 ]] && ((ok++))
    ((sum+=ms))
    sleep 0.15
  done
  avg=$(( sum / TRIES ))

  # RPC status (optional)
  rpc_ok="no"; rpc_ms="-"; catching="n/a"; lag="n/a"; moniker="n/a"
  start="$(now_ns)"
  status="$(curl -m "$RPC_TIMEOUT" -s "http://$ip:26657/status" || true)"
  if [[ -n "$status" ]]; then
    end="$(now_ns)"; rpc_ms=$(( (end - start) / 1000000 ))
    rpc_ok="yes"
    moniker="$(jq -r '.result.node_info.moniker // "n/a"' <<<"$status" 2>/dev/null || echo n/a)"
    catching="$(jq -r '.result.sync_info.catching_up // "n/a"' <<<"$status" 2>/dev/null || echo n/a)"
    bh="$(jq -r '.result.sync_info.latest_block_height // 0' <<<"$status" 2>/dev/null || echo 0)"
    if [[ "$MYH" =~ ^[0-9]+$ && "$bh" =~ ^[0-9]+$ && "$MYH" -gt 0 && "$bh" -gt 0 ]]; then
      lag=$(( MYH - bh ))
    fi
  fi

  echo -e "${avg}\t${ok}/3\t${rpc_ms}\t${rpc_ok}\t${catching}\t${lag}\t${moniker}\t${peer}"
done < "$PFILE"

# If nothing printed, say so (helps debugging)
[[ $processed -eq 0 ]] && echo "NO PEERS READ — check file/path/encoding" >&2