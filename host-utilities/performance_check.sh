#!/usr/bin/env bash
set -euo pipefail

# ======================= CONFIG =======================
CONTAINER="${CONTAINER:-validator-node}"
VALOPER="${VALOPER:-qubeticsvaloper18llj8eqh9k9mznylk8svrcc63ucf7y2r4xkd8l}"
HOME_DIR="${HOME_DIR:-/mnt/nvme/qubetics}"
KEYRING="${KEYRING:-file}"
# Optional REST API (if enabled in app.toml: api.enable = true)
HOST_API_DEFAULT="http://127.0.0.1:1317"
# ======================================================

have() { command -v "$1" >/dev/null 2>&1; }

# ---------- helpers ----------
pcurl () { curl -sS --max-time "${2:-3}" "$1" 2>/dev/null || echo "rpc unavailable"; }

# jq-less JSON tiny extractors (best-effort; avoid -P for busybox grep)
json_bool () { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\(true\|false\)" 2>/dev/null | head -n1 | awk -F: '{gsub(/[[:space:]]*/,"",$2); print $2}' || true; }
json_string () { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null | head -n1 | sed -E 's/.*"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true; }
json_number () { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"?[0-9]+\"?" 2>/dev/null | head -n1 | awk -F: '{gsub(/[^0-9]/,"",$2); print $2}' || true; }

# Parse RFC3339 time safely (returns epoch or 0)
to_epoch () { date -d "$1" +%s 2>/dev/null || echo 0; }

# ---------- discover container if name differs ----------
if ! docker ps --format '{{.Names}}' | grep -q -E "^${CONTAINER}$"; then
  CANDIDATE="$(docker ps --format '{{.Names}} {{.Image}}' | awk '/qubetics|tics-validator|cosmovisor|tendermint|comet/ {print $1; exit}')"
  [ -n "$CANDIDATE" ] && CONTAINER="$CANDIDATE"
fi

echo "Using container: ${CONTAINER}"
echo "Using VALOPER:   ${VALOPER}"
echo "Using HOME_DIR:  ${HOME_DIR} (keyring-backend=${KEYRING})"
echo

# ---------- basics ----------
echo "== Host basics =="
date -Is; uname -a; uptime
echo
free -h; df -h "${HOME_DIR}" || true
echo

echo "== Time sync =="
if have chronyc; then chronyc tracking; else echo "chrony not installed"; fi
timedatectl | sed -n '1,8p'
echo

echo "== Node health =="
if have vcgencmd; then
  vcgencmd get_throttled || true
  vcgencmd measure_temp || true
else
  echo "vcgencmd not available"
fi
echo

echo "== Container status =="
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}' | awk -v c="$CONTAINER" 'NR==1 || $1==c'
OOMKILLED="$(docker inspect -f '{{.State.OOMKilled}}' "$CONTAINER" 2>/dev/null || echo "n/a")"
echo "OOMKilled=${OOMKILLED}"
echo

# ---------- resolve RPC/REST on host & inside container ----------
HOST_RPC="http://127.0.0.1:26657"
HOST_API="${HOST_API_DEFAULT}"
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  HOST_PORT="$(docker inspect -f '{{range $p,$cfg := .NetworkSettings.Ports}}{{$p}} {{(index $cfg 0).HostPort}}{{"\n"}}{{end}}' "$CONTAINER" | awk '$1 ~ /26657/ {print $2; exit}')"
  API_PORT="$(docker inspect -f '{{range $p,$cfg := .NetworkSettings.Ports}}{{$p}} {{(index $cfg 0).HostPort}}{{"\n"}}{{end}}' "$CONTAINER" | awk '$1 ~ /1317/ {print $2; exit}')"
  [ -n "${HOST_PORT:-}" ] && HOST_RPC="http://127.0.0.1:${HOST_PORT}"
  [ -n "${API_PORT:-}" ] && HOST_API="http://127.0.0.1:${API_PORT}"
  CONT_IP="$(docker inspect -f '{{.NetworkSettings.IPAddress}}' "$CONTAINER" 2>/dev/null || echo "")"
else
  CONT_IP=""
fi
echo "Resolved RPC (host):      ${HOST_RPC}"
[ -n "$CONT_IP" ] && echo "Container IP (fallback): http://${CONT_IP}:26657"
echo

# ---------- logs ----------
echo "== Node logs (last 30m, errors only) =="
ERRS_LAST30="$(docker logs "$CONTAINER" --since 30m 2>&1 | egrep -i 'panic|oom|killed process|consensus|precommit|prevote|timeout|failed|error' | tail -n 120 || true)"
echo "${ERRS_LAST30}"
echo

# ---------- quick RPC probes ----------
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

# ---------- config snippets ----------
echo "== Config snippets (rpc laddr, tx indexer, pruning) =="
grep -nE '^[[:space:]]*laddr|^[[:space:]]*indexer[[:space:]]*=' "${HOME_DIR}/config/config.toml" 2>/dev/null || true
grep -nE '^[[:space:]]*(pruning|iavl-cache-size|min-retain-blocks)[[:space:]]*=' "${HOME_DIR}/config/app.toml" 2>/dev/null || true
INDEXER="$(awk -F= '/^[[:space:]]*indexer[[:space:]]*=/{gsub(/["[:space:]]/,"",$2);print $2}' "${HOME_DIR}/config/config.toml" 2>/dev/null || echo "")"
[ -n "$INDEXER" ] && echo "Tx indexer: ${INDEXER} (set indexer=\"kv\" to enable q tx <hash>)"
echo

# ---------- show-validator ----------
echo "== Validator key & chain view =="
docker exec "$CONTAINER" sh -lc "
  set -e
  (qubeticsd tendermint show-validator --home='${HOME_DIR}' 2>/dev/null || \
   qubeticsd comet show-validator --home='${HOME_DIR}' 2>/dev/null || \
   echo 'show-validator unavailable') | sed -n '1,3p'
" || true
echo

# ---------- status JSON: host → container fallback ----------
STATUS_RAW="$(pcurl "${HOST_RPC}/status" 5)"
if echo "$STATUS_RAW" | grep -qi 'rpc unavailable'; then
  STATUS_RAW="$(docker exec "$CONTAINER" sh -lc 'curl -sS --max-time 5 http://127.0.0.1:26657/status' 2>/dev/null || echo "")"
fi

echo "-- status (synced?) --"
[ -n "$STATUS_RAW" ] && echo "$STATUS_RAW" | sed -n '1,200p' || echo "no status JSON"
echo

# ---------- staking validator: try CLI JSON → CLI text → REST API ----------
VAL_JSON="$(docker exec "$CONTAINER" sh -lc "qubeticsd q staking validator '${VALOPER}' --node '${HOST_RPC}' -o json 2>/dev/null" || true)"
VAL_TEXT=""
if [ -z "$VAL_JSON" ]; then
  VAL_TEXT="$(docker exec "$CONTAINER" sh -lc "qubeticsd q staking validator '${VALOPER}' --node '${HOST_RPC}' 2>/dev/null" || true)"
fi
# REST API try (modern + legacy) if reachable
if [ -z "$VAL_JSON" ] && [ -n "${HOST_API:-}" ]; then
  for _PATH in \
    "/cosmos/staking/v1beta1/validators/${VALOPER}" \
    "/staking/validators/${VALOPER}"
  do
    API_JSON="$(pcurl "${HOST_API}${_PATH}" 5 || true)"
    if echo "$API_JSON" | grep -q '"jailed"'; then
      VAL_JSON="$API_JSON"
      break
    fi
  done
fi

echo "-- staking validator (on-chain) --"
if [ -n "$VAL_JSON" ]; then
  echo "$VAL_JSON" | head -n 50
else
  echo "$VAL_TEXT" | sed -n '1,200p'
fi
echo

echo "== Slashing: signing-info & params =="
CONSADDR="$(echo "${STATUS_RAW}" | grep -o '"address":"[A-F0-9]\+"' | head -n1 | cut -d: -f2 | tr -d '"' || true)"
[ -n "${CONSADDR:-}" ] && echo "CONSADDR=${CONSADDR}" || echo "CONSADDR not parsed (install jq for nicer JSON parsing)"
docker exec "$CONTAINER" sh -lc "
  set -e
  NODE='${HOST_RPC}'
  [ -n '${CONSADDR}' ] && qubeticsd q slashing signing-info '${CONSADDR}' --node \"\${NODE}\" 2>/dev/null | sed -n '1,160p' || true
  qubeticsd q slashing params --node \"\${NODE}\" 2>/dev/null | sed -n '1,160p' || true
" || true
echo

echo "== Kernel messages: OOM/USB/NVMe/power =="
dmesg | egrep -i 'out of memory|oom-killer|killed process|nvme|voltage|throttl|usb reset' | tail -n 200 || true
echo

echo "== Disk & CPU pressure =="
if ! have iostat; then
  echo "Installing sysstat (for iostat)..."
  sudo apt-get update -y >/dev/null 2>&1 && sudo apt-get install -y sysstat >/dev/null 2>&1 || echo "sysstat install failed"
fi
IOSTAT_RAW="$(iostat -dx 1 2 2>/dev/null || true)"
echo "$IOSTAT_RAW"
docker stats --no-stream || true

# ====================== SUMMARY PREP ======================
# Defaults (safe for set -u)
NETID="unknown"; HEIGHT="unknown"; CATCHING_UP="unknown"; NPEERS="unknown"
VAL_JAILED="unknown"; VAL_STATUS="unknown"; VAL_TOKENS="unknown"; VAL_COMMISSION="unknown"
ERR_COUNT="${ERR_COUNT:-0}"

# --- /status & /net_info (prefer jq; otherwise robust grep) ---
NETINFO_RAW="$(pcurl "${HOST_RPC}/net_info" 5)"
if echo "$NETINFO_RAW" | grep -qi 'rpc unavailable'; then
  NETINFO_RAW="$(docker exec "$CONTAINER" sh -lc 'curl -sS --max-time 5 http://127.0.0.1:26657/net_info' 2>/dev/null || echo "")"
fi

if have jq && [ -n "$STATUS_RAW" ]; then
  NETID="$(echo "$STATUS_RAW"   | jq -r '.result.node_info.network // .default_node_info.network // .node_info.network // "unknown"')"
  HEIGHT="$(echo "$STATUS_RAW"  | jq -r '.result.sync_info.latest_block_height // .sync_info.latest_block_height // "unknown"')"
  CATCHING_UP="$(echo "$STATUS_RAW" | jq -r '.result.sync_info.catching_up // .sync_info.catching_up // "unknown"')"
else
  NETID="$(echo "$STATUS_RAW"  | json_string "network")"; NETID="${NETID:-unknown}"
  HEIGHT="$(echo "$STATUS_RAW" | json_number "latest_block_height")"; HEIGHT="${HEIGHT:-unknown}"
  # try direct bool
  CU_RAW="$(echo "$STATUS_RAW" | json_bool "catching_up")"
  if [ -n "$CU_RAW" ]; then
    CATCHING_UP="$CU_RAW"
  else
    # Heuristic fallback: compute lag from latest_block_time
    LBT="$(echo "$STATUS_RAW" | json_string "latest_block_time")"
    if [ -n "$LBT" ]; then
      NOW_E=$(date +%s)
      LBT_E=$(to_epoch "$LBT")
      if [ "$LBT_E" -gt 0 ]; then
        LAG=$(( NOW_E - LBT_E ))
        if [ "$LAG" -gt 90 ]; then CATCHING_UP="true"; else CATCHING_UP="false"; fi
      fi
    fi
    CATCHING_UP="${CATCHING_UP:-unknown}"
  fi
fi

# --- FINAL newline/pretty-print safe CatchingUp override ---
if [ "$CATCHING_UP" = "unknown" ] && [ -n "$STATUS_RAW" ]; then
  ONE_LINE_STATUS="$(printf '%s' "$STATUS_RAW" | tr -d '\n')"
  CATCHING_UP="$(printf '%s' "$ONE_LINE_STATUS" \
    | grep -o '"catching_up"[[:space:]]*:[[:space:]]*\(true\|false\)' \
    | head -n1 | sed 's/.*://; s/[[:space:]]//g')"
  CATCHING_UP="${CATCHING_UP:-unknown}"
  if [ "$CATCHING_UP" = "unknown" ]; then
    LBT="$(printf '%s' "$ONE_LINE_STATUS" | sed -n 's/.*"latest_block_time"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    if [ -n "$LBT" ]; then
      NOW_E=$(date +%s); LBT_E=$(date -d "$LBT" +%s 2>/dev/null || echo 0)
      if [ "$LBT_E" -gt 0 ]; then
        LAG=$(( NOW_E - LBT_E ))
        [ "$LAG" -gt 90 ] && CATCHING_UP="true" || CATCHING_UP="false"
      fi
    fi
  fi
fi

# Peers
if have jq && [ -n "$NETINFO_RAW" ]; then
  NPEERS="$(echo "$NETINFO_RAW" | jq -r '.result.n_peers // .n_peers // "unknown"')"
else
  NPEERS="$(echo "$NETINFO_RAW" | json_number "n_peers")"; NPEERS="${NPEERS:-unknown}"
fi

# --- Validator (prefer JSON; fallback to text; optional REST) ---
if [ -n "$VAL_JSON" ]; then
  if have jq; then
    VAL_JAILED="$(echo "$VAL_JSON"     | jq -r '..|.jailed? // empty' | head -n1)"; VAL_JAILED="${VAL_JAILED:-unknown}"
    VAL_STATUS="$(echo "$VAL_JSON"     | jq -r '..|.status? // empty' | head -n1)"; VAL_STATUS="${VAL_STATUS:-unknown}"
    VAL_TOKENS="$(echo "$VAL_JSON"     | jq -r '..|.tokens? // empty' | head -n1)"; VAL_TOKENS="${VAL_TOKENS:-unknown}"
    VAL_COMMISSION="$(echo "$VAL_JSON" | jq -r '..|.commission_rates? // empty | .rate? // empty' | head -n1)"; VAL_COMMISSION="${VAL_COMMISSION:-unknown}"
  else
    ONE_LINE_VAL="$(printf '%s' "$VAL_JSON" | tr -d '\n')"
    VAL_JAILED="$(printf '%s' "$ONE_LINE_VAL" | grep -o '"jailed"[[:space:]]*:[[:space:]]*\(true\|false\)' | head -n1 | sed 's/.*://;s/[[:space:]]//g')"
    VAL_STATUS="$(printf '%s' "$ONE_LINE_VAL" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    VAL_TOKENS="$(printf '%s' "$ONE_LINE_VAL" | grep -o '"tokens"[[:space:]]*:[[:space:]]*"*[0-9]+"' | head -n1 | tr -dc '0-9')"
    VAL_COMMISSION="$(printf '%s' "$ONE_LINE_VAL" | sed -n 's/.*"rate"[[:space:]]*:[[:space:]]*"\([0-9.]\+\)".*/\1/p')"
    VAL_JAILED="${VAL_JAILED:-unknown}"; VAL_STATUS="${VAL_STATUS:-unknown}"
  fi
else
  # Parse text output
  if [ -n "$VAL_TEXT" ]; then
    VAL_JAILED="$(echo "$VAL_TEXT" | awk -F': *' 'tolower($1)~/^jailed/{print tolower($2)}' | head -n1)"
    VAL_STATUS="$(echo "$VAL_TEXT" | awk -F': *' 'tolower($1)~/^status/{print $2}' | head -n1)"
    VAL_TOKENS="$(echo "$VAL_TEXT" | awk -F': *' 'tolower($1)~/^tokens/{print $2}' | head -n1)"
    VAL_COMMISSION="$(echo "$VAL_TEXT" | awk -F': *' 'tolower($1)~/rate/{print $2}' | head -n1)"
    VAL_JAILED="${VAL_JAILED:-unknown}"; VAL_STATUS="${VAL_STATUS:-unknown}"
    VAL_TOKENS="${VAL_TOKENS:-unknown}"; VAL_COMMISSION="${VAL_COMMISSION:-unknown}"
  fi
fi

# Normalize & heuristic (BONDED ⇒ not jailed)
VAL_JAILED="${VAL_JAILED:-unknown}"
VAL_STATUS="${VAL_STATUS:-unknown}"
if [ "$VAL_JAILED" = "unknown" ] && echo "$VAL_STATUS" | grep -qi 'bonded'; then
  VAL_JAILED="false"
fi

# --- Error count from last 30m ---
ERR_COUNT=0
if [ -n "${ERRS_LAST30}" ]; then
  ERR_COUNT="$(echo "${ERRS_LAST30}" | grep -Eci 'panic|oom|killed process|consensus|precommit|prevote|timeout|failed|error' || true)"
fi

# --- Time sync summary (chrony optional) ---
TIME_SUMMARY="chrony or parsing not available"
if have chronyc; then
  TS="$(chronyc tracking 2>/dev/null || true)"
  if [ -n "$TS" ]; then
    STRAT="$(echo "$TS" | awk -F': *' '/^Stratum/{print $2}')"
    REF="$(echo "$TS"   | awk -F': *' '/^Ref time/{print $2}')"
    SYS="$(echo "$TS"   | awk -F': *' '/^System time/{print $2}')"
    RMS="$(echo "$TS"   | awk -F': *' '/^RMS offset/{print $2}')"
    SKEW="$(echo "$TS"  | awk -F': *' '/^Skew/{print $2}')"
    TIME_SUMMARY=$(
      printf "Stratum=%s\nRef time (UTC)=%s\nSystem time=%s\nRMS offset=%s\nSkew=%s\n" \
        "${STRAT:-unknown}" "${REF:-unknown}" "${SYS:-unknown}" "${RMS:-unknown}" "${SKEW:-unknown}"
    )
  fi
fi

# --- Docker stats (robust JSON; fallback) ---
CPU_USAGE="unknown"; MEM_USAGE="unknown"; MEM_PCT="unknown"; NET_IO="unknown"; BLOCK_IO="unknown"; PIDS="unknown"
if have jq; then
  STATS_JSON="$(docker stats --no-stream --format '{{json .}}' "$CONTAINER" 2>/dev/null || true)"
  if [ -n "$STATS_JSON" ]; then
    CPU_USAGE="$(echo "$STATS_JSON"  | jq -r '.CPUPerc // "unknown"')"
    MEM_USAGE="$(echo "$STATS_JSON"  | jq -r '.MemUsage // "unknown"')"
    MEM_PCT="$(echo "$STATS_JSON"    | jq -r '.MemPerc // "unknown"')"
    NET_IO="$(echo "$STATS_JSON"     | jq -r '.NetIO // "unknown"')"
    BLOCK_IO="$(echo "$STATS_JSON"   | jq -r '.BlockIO // "unknown"')"
    PIDS="$(echo "$STATS_JSON"       | jq -r '.PIDs // "unknown"')"
  fi
else
  LINE="$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}' "$CONTAINER" 2>/dev/null || echo "")"
  IFS='|' read -r CPU_USAGE MEM_USAGE MEM_PCT NET_IO BLOCK_IO PIDS <<< "$LINE"
  CPU_USAGE=${CPU_USAGE:-unknown}; MEM_USAGE=${MEM_USAGE:-unknown}; MEM_PCT=${MEM_PCT:-unknown}
  NET_IO=${NET_IO:-unknown}; BLOCK_IO=${BLOCK_IO:-unknown}; PIDS=${PIDS:-unknown}
fi
# Normalize memory when limit is 0B
if echo "$MEM_USAGE" | grep -q '/ 0B'; then
  MEM_USAGE_PRETTY="$(echo "$MEM_USAGE" | sed 's|/ 0B|/ no-limit|')"
  MEM_PCT_PRETTY="n/a"
else
  MEM_USAGE_PRETTY="$MEM_USAGE"
  MEM_PCT_PRETTY="$MEM_PCT"
fi

# --- iostat summary (robust) ---
if have iostat; then
  IOSTAT_RAW="$(iostat -dx 1 2 2>/dev/null || true)"
  IOSTAT_SUMMARY="$(
    awk '
      $1=="Device:" { block_start=NR }
      { lines[NR]=$0 }
      END {
        if (block_start) {
          for (i=block_start; i<=NR; i++) print lines[i]
        }
      }
    ' <<<"$IOSTAT_RAW" | sed '1d' | awk "NF>0" | head -n 12
  )"
  if [ -z "$IOSTAT_SUMMARY" ]; then
    IOSTAT_SUMMARY="$(iostat -d 1 2 2>/dev/null | tail -n +4 | head -n 10)"
  fi
  [ -z "$IOSTAT_SUMMARY" ] && IOSTAT_SUMMARY="No disk data parsed"
else
  IOSTAT_SUMMARY="iostat not installed"
fi

# CPU hot flag
CPU_HOT=""
if echo "$CPU_USAGE" | grep -Eo '[0-9.]+' >/dev/null; then
  CPU_VAL="$(echo "$CPU_USAGE" | grep -Eo '[0-9.]+' | head -n1)"
  awk "BEGIN{exit !($CPU_VAL>250)}" || true
  if [ $? -eq 0 ]; then CPU_HOT=" (high)"; fi
fi

# ===================== SUMMARY REPORT =====================
echo
echo "==================== Summary Report ===================="
echo "Container: ${CONTAINER}"
echo "  - OOMKilled:    ${OOMKILLED}"
echo
echo "Chain Info:"
echo "  - Network:     ${NETID}"
echo "  - Height:      ${HEIGHT}"
echo "  - CatchingUp:  ${CATCHING_UP}"
echo "  - Peers:       ${NPEERS}"
echo
echo "Validator Info:"
echo "  - Address:     ${VALOPER}"
echo "  - Status:      ${VAL_STATUS}"
echo "  - Jailed:      ${VAL_JAILED}"
echo "  - Voting Power: ${VAL_TOKENS}"
echo "  - Commission:  ${VAL_COMMISSION}"
echo
echo "Errors (last 30m):"
echo "  - Count:       ${ERR_COUNT}"
if [ "${ERR_COUNT}" -gt 0 ]; then
  echo "  - Recent sample:"
  echo "${ERRS_LAST30}" | tail -n 5 | sed 's/^/    /'
fi
echo
echo "Time Sync:"
if [ -n "${TIME_SUMMARY}" ]; then
  echo "${TIME_SUMMARY}" | sed 's/^/  - /'
else
  echo "  - chrony or parsing not available"
fi
echo
echo "Performance:"
echo "  - CPU (container): ${CPU_USAGE}${CPU_HOT}"
echo "  - MEM (container): ${MEM_USAGE_PRETTY} (${MEM_PCT_PRETTY})"
echo "  - NET I/O:         ${NET_IO}"
echo "  - Block I/O:       ${BLOCK_IO}"
echo "  - PIDs:            ${PIDS}"
echo "  - Disk util (iostat):"
echo "${IOSTAT_SUMMARY}" | sed 's/^/    /'
echo

# ---------------- Health Grade ----------------
GRADE="✅ Healthy"
is_true() { [ "$1" = "true" ] || [ "$1" = "True" ] || [ "$1" = "TRUE" ]; }

if is_true "${VAL_JAILED}"; then
  GRADE="❌ Critical"
elif [ "${CATCHING_UP}" = "true" ]; then
  GRADE="❌ Critical"
elif is_true "${OOMKILLED}"; then
  GRADE="⚠️ Warning"
elif [ "${ERR_COUNT}" -gt 5 ]; then
  GRADE="⚠️ Warning"
fi

echo "Overall Health: ${GRADE}"
echo "================== End Summary =================="

# Optional exit code for alerting:
# [ "$GRADE" = "❌ Critical" ] && exit 2 || exit 0