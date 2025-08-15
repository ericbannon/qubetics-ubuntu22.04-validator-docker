#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-validator-node}"
VALOPER="${VALOPER:-qubeticsvaloper18llj8eqh9k9mznylk8svrcc63ucf7y2r4xkd8l}"
HOME_DIR="${HOME_DIR:-/mnt/nvme/qubetics}"
KEYRING="${KEYRING:-file}"

# --- find container if name differs ---
if ! docker ps --format '{{.Names}}' | grep -q -E "^${CONTAINER}$"; then
  CANDIDATE="$(docker ps --format '{{.Names}} {{.Image}}' | awk '/qubetics|tics-validator|cosmovisor|tendermint|comet/ {print $1; exit}')"
  [ -n "$CANDIDATE" ] && CONTAINER="$CANDIDATE"
fi

echo "Using container: ${CONTAINER}"
echo "Using VALOPER:   ${VALOPER}"
echo "Using HOME_DIR:  ${HOME_DIR} (keyring-backend=${KEYRING})"
echo

# --- basics ---
echo "== Host basics =="
date -Is; uname -a; uptime
echo
free -h; df -h "${HOME_DIR}" || true
echo

echo "== Time sync =="
if command -v chronyc >/dev/null 2>&1; then chronyc tracking; else echo "chrony not installed"; fi
timedatectl | sed -n '1,8p'
echo

echo "== Node health =="
if command -v vcgencmd >/dev/null 2>&1; then
  vcgencmd get_throttled || true
  vcgencmd measure_temp || true
else
  echo "vcgencmd not available"
fi
echo

echo "== Container status =="
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}' | awk -v c="$CONTAINER" 'NR==1 || $1==c'
docker inspect -f 'RestartCount={{.RestartCount}}  OOMKilled={{.State.OOMKilled}}' "$CONTAINER" 2>/dev/null || true
echo

# --- resolve RPC host port & container IP ---
HOST_RPC="http://127.0.0.1:26657"
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  HOST_PORT="$(docker inspect -f '{{range $p,$cfg := .NetworkSettings.Ports}}{{$p}} {{(index $cfg 0).HostPort}}{{"\n"}}{{end}}' "$CONTAINER" | awk '$1 ~ /26657/ {print $2; exit}')"
  [ -n "${HOST_PORT:-}" ] && HOST_RPC="http://127.0.0.1:${HOST_PORT}"
  CONT_IP="$(docker inspect -f '{{.NetworkSettings.IPAddress}}' "$CONTAINER" 2>/dev/null || echo "")"
else
  CONT_IP=""
fi
echo "Resolved RPC (host):      ${HOST_RPC}"
[ -n "$CONT_IP" ] && echo "Container IP (fallback): http://${CONT_IP}:26657"
echo

echo "== Node logs (last 30m, errors only) =="
docker logs "$CONTAINER" --since 30m 2>&1 | egrep -i 'panic|oom|killed process|consensus|precommit|prevote|timeout|failed|error' | tail -n 120 || true
echo

# helper: safe curl that doesn’t complain if we trim output
pcurl () { curl -sS --max-time 3 "$1" 2>/dev/null || echo "rpc unavailable"; }

echo "== RPC health (HOST → ${HOST_RPC}) =="
for ep in /health /status /net_info; do
  echo "=== ${ep} ==="
  pcurl "${HOST_RPC}${ep}" | head -c 2000 || true
  echo
done
echo

echo "== RPC health (INSIDE CONTAINER → 127.0.0.1:26657) =="
docker exec "$CONTAINER" sh -lc '
  set -e
  pcurl () { curl -sS --max-time 3 "$1" 2>/dev/null || echo "rpc unavailable"; }
  for ep in /health /status /net_info; do
    echo "=== $ep ==="
    pcurl "http://127.0.0.1:26657$ep" | head -c 2000 || true
    echo
  done
' || echo "exec into container failed"
echo

echo "== Keys at ${HOME_DIR}/keyring-${KEYRING} =="
docker exec "$CONTAINER" sh -lc "
  qubeticsd keys list \
    --home='${HOME_DIR}' \
    --keyring-backend='${KEYRING}' 2>/dev/null || echo 'keys list failed'
"
echo

# surface config: rpc bind & indexer
echo "== Config snippets (rpc laddr, tx indexer, pruning) =="
grep -nE '^[[:space:]]*laddr|^[[:space:]]*indexer[[:space:]]*=' "${HOME_DIR}/config/config.toml" 2>/dev/null || true
grep -nE '^[[:space:]]*(pruning|iavl-cache-size|min-retain-blocks)[[:space:]]*=' "${HOME_DIR}/config/app.toml" 2>/dev/null || true
# Explicitly report indexer status
INDEXER=$(awk -F= '/^[[:space:]]*indexer[[:space:]]*=/{gsub(/["[:space:]]/,"",$2);print $2}' "${HOME_DIR}/config/config.toml" 2>/dev/null || echo "")
[ -n "$INDEXER" ] && echo "Tx indexer: ${INDEXER} (set indexer=\"kv\" to enable q tx <hash>)"
echo

echo "== Validator key & chain view =="
docker exec "$CONTAINER" sh -lc "
  set -e
  NODE='${HOST_RPC}'
  echo '-- local validator pubkey/address --'
  (qubeticsd tendermint show-validator --home='${HOME_DIR}' 2>/dev/null || \
   qubeticsd comet show-validator --home='${HOME_DIR}' 2>/dev/null || \
   echo 'show-validator unavailable') | sed -n '1,3p'

  echo '-- status (synced?) --'
  curl -sS \"\${NODE}/status\" 2>/dev/null | sed -n '1,200p'

  echo '-- staking validator (on-chain) --'
  qubeticsd q staking validator '${VALOPER}' --node \"\${NODE}\" 2>/dev/null | sed -n '1,200p'
"
echo

echo "== Slashing: signing-info & params =="
docker exec "$CONTAINER" sh -lc "
  set -e
  NODE='${HOST_RPC}'
  CONSADDR=\$(curl -sS \"\${NODE}/status\" 2>/dev/null | sed -n 's/.*\"address\":\"\\([A-F0-9]\\+\\)\".*/\\1/p' | head -n1)
  [ -n \"\${CONSADDR}\" ] && echo CONSADDR=\${CONSADDR} || echo 'CONSADDR not parsed (install jq for nicer JSON parsing)'
  [ -n \"\${CONSADDR}\" ] && qubeticsd q slashing signing-info \"\${CONSADDR}\" --node \"\${NODE}\" 2>/dev/null | sed -n '1,160p' || true
  qubeticsd q slashing params --node \"\${NODE}\" 2>/dev/null | sed -n '1,160p' || true
"
echo

echo "== Kernel messages: OOM/USB/NVMe/power =="
dmesg | egrep -i 'out of memory|oom-killer|killed process|nvme|voltage|throttl|usb reset' | tail -n 200 || true
echo

echo "== Disk & CPU pressure =="
if ! command -v iostat >/dev/null 2>&1; then
  echo "Installing sysstat (for iostat)..."
  sudo apt-get update -y >/dev/null 2>&1 && sudo apt-get install -y sysstat >/dev/null 2>&1 || echo "sysstat install failed"
fi
iostat -xz 1 3 || true
docker stats --no-stream || true

# --- helper: safe self-delegate using your keyring/RPC ---

echo "--- End of triage ---"
