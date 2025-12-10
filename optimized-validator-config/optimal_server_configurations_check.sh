#!/usr/bin/env bash
# Qubetics Validator One-Command Audit
# Run as:  sudo ./validator_audit.sh

set -u  # (no -e so we can continue on errors)

### ───────────────────────────
### CONFIG – ADJUST IF NEEDED
### ───────────────────────────
CONTAINER_NAME="validator-node"
DAEMON_HOME="/mnt/nvme/qubetics"
VALIDATOR_IMAGE="bannimal/tics-validator-node:v1.0.2"

NVME_DEV="nvme0n1"         # your main NVMe device
NIC_NAME="enp3s0"          # your main network interface
EXPECTED_CPUSET="0-7"      # CPUs reserved for the container
EXPECTED_CPU_COUNT="8"
EXPECTED_IRQ_CPUSET="8-15" # CPUs that should handle NIC IRQs
EXPECTED_SCHEDULER="none"
EXPECTED_NR_REQUESTS="1023"

### ───────────────────────────
### COLOR HELPERS
### ───────────────────────────
if command -v tput >/dev/null 2>&1; then
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  RED=$(tput setaf 1)
  BLUE=$(tput setaf 4)
  BOLD=$(tput bold)
  RESET=$(tput sgr0)
else
  GREEN=""; YELLOW=""; RED=""; BLUE=""; BOLD=""; RESET=""
fi

ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; }
info() { echo -e "${BLUE}[INFO]${RESET} $*"; }

### ───────────────────────────
### PRECHECK TOOLS
### ───────────────────────────
need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required command: $1"
    MISSING=1
  fi
}

MISSING=0
need_cmd docker
need_cmd curl
need_cmd jq
need_cmd ps
need_cmd awk

if [[ $MISSING -ne 0 ]]; then
  fail "Install missing commands above and re-run."
  exit 1
fi

echo
echo "${BOLD}=== QUBETICS VALIDATOR AUDIT START ===${RESET}"
echo

### ───────────────────────────
### DOCKER / CONTAINER CHECKS
### ───────────────────────────
info "Checking Docker and container: ${CONTAINER_NAME}"

if ! docker info >/dev/null 2>&1; then
  fail "Docker daemon not available."
else
  ok "Docker daemon is running."
fi

if ! docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  fail "Container '$CONTAINER_NAME' does not exist."
else
  ok "Container '$CONTAINER_NAME' exists."

  state=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
  if [[ "$state" == "running" ]]; then
    ok "Container state: running"
  else
    warn "Container state: $state (expected 'running')"
  fi

  cpuset=$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
  if [[ "$cpuset" == "$EXPECTED_CPUSET" ]]; then
    ok "Container cpuset-cpus = $cpuset"
  else
    warn "Container cpuset-cpus = '$cpuset' (expected '$EXPECTED_CPUSET')"
  fi

  nanocpus=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$CONTAINER_NAME" 2>/dev/null || echo "0")
  # NanoCPUs = EXPECTED_CPU_COUNT * 1e9
  EXPECTED_NANOS=$(( EXPECTED_CPU_COUNT * 1000000000 ))
  if [[ "$nanocpus" -eq "$EXPECTED_NANOS" ]]; then
    ok "Container NanoCPUs = $nanocpus (≈ ${EXPECTED_CPU_COUNT} CPUs)"
  else
    warn "Container NanoCPUs = $nanocpus (expected ≈ $EXPECTED_NANOS for ${EXPECTED_CPU_COUNT} CPUs)"
  fi

  mem=$(docker inspect -f '{{.HostConfig.Memory}}' "$CONTAINER_NAME" 2>/dev/null || echo "0")
  memswap=$(docker inspect -f '{{.HostConfig.MemorySwap}}' "$CONTAINER_NAME" 2>/dev/null || echo "0")
  info "Container Memory limit = $mem bytes, MemorySwap = $memswap bytes"

  netmode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
  if [[ "$netmode" == "host" ]]; then
    ok "Container is using host networking."
  else
    warn "Container network mode = '$netmode' (expected 'host')"
  fi
fi

echo

### ───────────────────────────
### SYSCTL / KERNEL TUNING
### ───────────────────────────
info "Checking sysctl kernel/network tuning"

check_sysctl() {
  local key="$1"
  local expected="$2"
  local val
  val=$(sysctl -n "$key" 2>/dev/null || echo "missing")
  if [[ "$val" == "$expected" ]]; then
    ok "sysctl $key = $val"
  else
    warn "sysctl $key = '$val' (expected '$expected')"
  fi
}

check_sysctl net.core.default_qdisc fq
check_sysctl net.ipv4.tcp_congestion_control bbr
check_sysctl fs.file-max 2097152
check_sysctl net.core.netdev_max_backlog 65536
check_sysctl vm.swappiness 10
check_sysctl vm.max_map_count 262144
check_sysctl net.core.rmem_max 268435456
check_sysctl net.core.wmem_max 268435456

echo

### ───────────────────────────
### NVMe DISK SETTINGS
### ───────────────────────────
info "Checking NVMe device: $NVME_DEV"

if [[ -e "/sys/block/${NVME_DEV}/queue/scheduler" ]]; then
  sched=$(cat "/sys/block/${NVME_DEV}/queue/scheduler")
  if echo "$sched" | grep -q "\[${EXPECTED_SCHEDULER}\]"; then
    ok "NVMe scheduler = $sched (expected [$EXPECTED_SCHEDULER])"
  else
    warn "NVMe scheduler = $sched (expected [$EXPECTED_SCHEDULER])"
  fi
else
  fail "NVMe scheduler path not found: /sys/block/${NVME_DEV}/queue/scheduler"
fi

if [[ -e "/sys/block/${NVME_DEV}/queue/nr_requests" ]]; then
  nr=$(cat "/sys/block/${NVME_DEV}/queue/nr_requests")
  if [[ "$nr" == "$EXPECTED_NR_REQUESTS" ]]; then
    ok "NVMe nr_requests = $nr"
  else
    warn "NVMe nr_requests = $nr (expected $EXPECTED_NR_REQUESTS)"
  fi
else
  fail "NVMe nr_requests path not found: /sys/block/${NVME_DEV}/queue/nr_requests"
fi

echo

### ───────────────────────────
### IRQ / NIC AFFINITY
### ───────────────────────────
info "Checking IRQ affinity for NIC: $NIC_NAME"

if systemctl is-active --quiet irqbalance; then
  warn "irqbalance is ACTIVE (recommended to disable for strict pinning)."
else
  ok "irqbalance is not active."
fi

nic_irqs=$(grep "$NIC_NAME" /proc/interrupts 2>/dev/null | awk '{print $1}' | sed 's/://')
if [[ -z "$nic_irqs" ]]; then
  warn "No IRQs found for NIC '$NIC_NAME' in /proc/interrupts."
else
  for irq in $nic_irqs; do
    aff=$(cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || echo "unknown")
    if [[ "$aff" == "$EXPECTED_IRQ_CPUSET" ]]; then
      ok "IRQ $irq for $NIC_NAME has affinity $aff (expected $EXPECTED_IRQ_CPUSET)"
    else
      warn "IRQ $irq for $NIC_NAME has affinity $aff (expected $EXPECTED_IRQ_CPUSET)"
    fi
  done
fi

echo

### ───────────────────────────
### VALIDATOR PROCESS / CPU PIN
### ───────────────────────────
info "Checking qubeticsd process CPU placement"

PID_Q=$(pgrep -x qubeticsd || pidof qubeticsd || echo "")
if [[ -z "$PID_Q" ]]; then
  warn "qubeticsd process not found on host (might be only inside container)."
else
  psr=$(ps -o psr= -p "$PID_Q" 2>/dev/null || echo "?")
  ok "Host qubeticsd PID=$PID_Q currently running on CPU#${psr}"
fi

# Also check inside container if possible
if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  PID_IN=$(docker exec "$CONTAINER_NAME" sh -lc 'pidof qubeticsd 2>/dev/null' || echo "")
  if [[ -n "$PID_IN" ]]; then
    ps_line=$(docker exec "$CONTAINER_NAME" sh -lc "ps -o pid,psr,cmd -p $PID_IN | tail -n 1")
    ok "Inside container: $ps_line"
  else
    warn "No qubeticsd PID found inside container."
  fi
fi

echo

### ───────────────────────────
### BASIC RPC / P2P HEALTH
### ───────────────────────────
info "Checking Tendermint RPC & P2P"

STATUS_JSON=$(curl -sf localhost:26657/status 2>/dev/null || echo "")
if [[ -z "$STATUS_JSON" ]]; then
  fail "Could not fetch /status from localhost:26657."
else
  latest_height=$(echo "$STATUS_JSON" | jq -r '.result.sync_info.latest_block_height // "0"')
  catching_up=$(echo "$STATUS_JSON" | jq -r '.result.sync_info.catching_up // "true"')
  ok "Latest block height: $latest_height"
  if [[ "$catching_up" == "false" ]]; then
    ok "Node is NOT catching up (in sync)."
  else
    warn "Node is still catching up."
  fi
fi

CONFIG_TOML="$DAEMON_HOME/config/config.toml"
if [[ -f "$CONFIG_TOML" ]]; then
  max_in=$(grep -E '^max_num_inbound_peers' "$CONFIG_TOML" | head -n1 | awk -F= '{gsub(/ /,"",$2); print $2}')
  if [[ "$max_in" == "0" ]]; then
    ok "max_num_inbound_peers = 0 (good for validator behind sentry)."
  else
    warn "max_num_inbound_peers = $max_in (consider 0 for strict sentry model)."
  fi
else
  warn "config.toml not found at $CONFIG_TOML"
fi

NET_JSON=$(curl -sf localhost:26657/net_info 2>/dev/null || echo "")
if [[ -z "$NET_JSON" ]]; then
  warn "Could not fetch /net_info from localhost:26657."
else
  n_peers=$(echo "$NET_JSON" | jq -r '.result.n_peers // "0"' 2>/dev/null || echo "0")
  info "Current connected peers: $n_peers"

  inbound_count=$(echo "$NET_JSON" | jq '[.result.peers[]? | select(.is_outbound == false)] | length')
  if [[ "$inbound_count" -gt 0 ]]; then
    warn "There are $inbound_count inbound peers connected (validator should ideally have 0)."
  else
    ok "No inbound peers detected (all outbound)."
  fi
fi

echo
echo "${BOLD}=== QUBETICS VALIDATOR AUDIT COMPLETE ===${RESET}"
echo "Review WARN/FAIL entries above for anything to fix."
