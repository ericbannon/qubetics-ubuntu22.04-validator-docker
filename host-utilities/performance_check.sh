# Adjust only if needed:
CONTAINER="validator-node"
VALOPER="qubeticsvaloper18llj8eqh9k9mznylk8svrcc63ucf7y2r4xkd8l"

# Try to auto-detect container if the default isn't found
if ! docker ps --format '{{.Names}}' | grep -q -E "^${CONTAINER}$"; then
  CANDIDATE="$(docker ps --format '{{.Names}} {{.Image}}' | awk '/qubetics|tics-validator|cosmovisor|tendermint|comet/ {print $1; exit}')"
  [ -n "$CANDIDATE" ] && CONTAINER="$CANDIDATE"
fi
echo "Using container: ${CONTAINER}"
echo "Using VALOPER:   ${VALOPER}"

echo "== Host basics =="
date -Is; uname -a; uptime
echo
free -h; df -h /mnt/nvme || true
echo

echo "== Time sync =="
if command -v chronyc >/dev/null 2>&1; then
  chronyc tracking
else
  echo "chrony not installed"
fi
timedatectl | sed -n '1,8p'
echo

echo "== Node health =="
if command -v vcgencmd >/dev/null 2>&1; then
  vcgencmd get_throttled
  vcgencmd measure_temp
else
  echo "vcgencmd not available"
fi
echo

echo "== Container status =="
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}' | sed -n '1,200p' | grep -E "^${CONTAINER}\b" || echo "container not found"
docker inspect -f 'RestartCount={{.RestartCount}}  OOMKilled={{.State.OOMKilled}}' "$CONTAINER" 2>/dev/null || true
echo

echo "== Node logs (last 30m, errors only) =="
docker logs "$CONTAINER" --since 30m 2>&1 | egrep -i 'panic|oom|killed process|consensus|precommit|prevote|timeout|failed|error' | tail -n 120 || true
echo

echo "== RPC health (/health /status /net_info) =="
docker exec "$CONTAINER" sh -lc '
  H=127.0.0.1:26657
  for ep in /health /status /net_info ; do
    echo "=== $ep ==="
    if command -v curl >/dev/null 2>&1; then curl -s "$H$ep" || echo "rpc unavailable";
    elif command -v wget >/dev/null 2>&1; then wget -qO- "$H$ep" || echo "rpc unavailable";
    else echo "no curl/wget"; fi
  done
' 2>/dev/null || echo "exec into container failed"
echo

echo "== Validator key & chain view =="
docker exec "$CONTAINER" sh -lc '
  # show local validator pubkey/address
  echo "== local validator pubkey/address =="
  (qubeticsd tendermint show-validator 2>/dev/null || qubeticsd comet show-validator 2>/dev/null || echo "show-validator unavailable") | sed -n "1,3p"
  # status address (may need jq but we fall back to plain output)
  if command -v jq >/dev/null 2>&1; then
    echo "== status validator address =="
    qubeticsd status 2>/dev/null | jq -r ".ValidatorInfo.Address"
  else
    echo "install jq for nicer output (optional)"; qubeticsd status 2>/dev/null | sed -n "1,80p"
  fi
  echo "== chain sees for VALOPER =="
  if command -v jq >/dev/null 2>&1; then
    qubeticsd q staking validator '"$VALOPER"' -o json 2>/dev/null | jq -r ".consensus_pubkey,.jailed"
  else
    qubeticsd q staking validator '"$VALOPER"' 2>/dev/null | sed -n "1,80p"
  fi
' || true
echo

echo "== Slashing: your signing info & params =="
docker exec "$CONTAINER" sh -lc '
  if command -v jq >/dev/null 2>&1; then
    CONSADDR=$(qubeticsd status 2>/dev/null | jq -r ".ValidatorInfo.Address")
    echo "CONSADDR=$CONSADDR"
  else
    CONSADDR=""
    echo "CONSADDR (jq not available; skipped extract)"
  fi
  [ -n "$CONSADDR" ] && qubeticsd q slashing signing-info "$CONSADDR" 2>/dev/null || true
  qubeticsd q slashing params 2>/dev/null | sed -n "1,120p" || true
' || true
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
echo "--- End of triage ---"