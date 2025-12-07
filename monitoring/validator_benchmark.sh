#!/usr/bin/env bash
# Comprehensive validator performance benchmark for debian-tics
# Usage:  chmod +x validator_benchmark.sh
#         ./validator_benchmark.sh | tee validator-benchmark-$(date +%F).log

set -euo pipefail

### --------- helpers ---------

banner() {
  echo
  echo "=================================================================="
  echo ">>> $1"
  echo "=================================================================="
}

need_cmd() {
  local cmd="$1" pkg="${2:-}"
  if ! command -v "$cmd" &>/dev/null; then
    echo "!! MISSING: '$cmd' (install with: sudo apt-get install -y ${pkg:-$cmd})"
    return 1
  fi
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

### --------- environment detection ---------

NODE_NAME="$(hostname)"
CORES="$(nproc || echo "unknown")"
IFACE="enp3s0"   # your tuned NIC
GW_IP="$(ip route 2>/dev/null | awk '/default via/{print $3; exit}' || true)"

echo "Node:        $NODE_NAME"
echo "Cores:       $CORES"
echo "Interface:   $IFACE"
echo "Gateway IP:  ${GW_IP:-unknown}"
echo

### --------- SECTION 1: NETWORK LATENCY & JITTER ---------

banner "SECTION 1: Network latency & jitter"

# 1.1 LAN ping (router)
if [ -n "${GW_IP:-}" ]; then
  echo "--- [1.1] LAN latency (to router $GW_IP, 200 pings) ---"
  ping -c 200 "$GW_IP" || echo "LAN ping failed"
else
  echo "!! Could not detect default gateway; skipping LAN ping."
fi

# 1.2 WAN ping (Cloudflare)
echo
echo "--- [1.2] WAN latency (to 1.1.1.1, 200 pings) ---"
ping -c 200 1.1.1.1 || echo "WAN ping failed"

# 1.3 Optional MTR (if installed)
if need_cmd mtr mtr-tiny; then
  echo
  echo "--- [1.3] MTR to 1.1.1.1 (short run) ---"
  sudo mtr -rwzc 50 1.1.1.1 || echo "mtr failed (may require sudo)"
else
  echo
  echo "!! Skipping mtr (route visualization) – install with: sudo apt-get install -y mtr-tiny"
fi

### --------- SECTION 2: LOCAL THROUGHPUT (IPERF3 LOOPBACK) ---------

banner "SECTION 2: Local TCP stack throughput (loopback iperf3)"

if need_cmd iperf3 iperf3; then
  echo "--- [2.1] iperf3 127.0.0.1, 4 parallel streams, 10 seconds ---"
  # run server once (-1) in the background
  iperf3 -s -1 > /tmp/iperf3-server.log 2>&1 &
  SERVER_PID=$!
  sleep 1
  iperf3 -c 127.0.0.1 -P 4 -t 10 || echo "iperf3 loopback test failed"
  wait "$SERVER_PID" || true

  echo
  echo "Note: This measures kernel TCP stack performance, not NIC/link limits."
  echo "For LAN link tests, run iperf3 between NUC and another machine on the LAN."
else
  echo "!! Skipping iperf3 tests – install with: sudo apt-get install -y iperf3"
fi

### --------- SECTION 3: DISK PERFORMANCE (NVMe) ---------

banner "SECTION 3: Disk performance (NVMe, fio)"

FIO_TARGET_DIR="/mnt/nvme"
[ -d "$FIO_TARGET_DIR" ] || FIO_TARGET_DIR="/tmp"
FIO_FILE="$FIO_TARGET_DIR/fio-validator-benchfile"

if need_cmd fio fio; then
  echo "Using fio test file: $FIO_FILE"
  echo

  echo "--- [3.1] Sequential read (2 GiB, 1 MiB blocks, depth 32) ---"
  fio --name=seqread \
      --filename="$FIO_FILE" \
      --rw=read \
      --bs=1M \
      --size=2G \
      --iodepth=32 \
      --numjobs=1 \
      --direct=1 \
      --time_based=0

  echo
  echo "--- [3.2] Sequential write (2 GiB, 1 MiB blocks, depth 32) ---"
  fio --name=seqwrite \
      --filename="$FIO_FILE" \
      --rw=write \
      --bs=1M \
      --size=2G \
      --iodepth=32 \
      --numjobs=1 \
      --direct=1 \
      --time_based=0

  echo
  echo "--- [3.3] Random RW (70/30, 4k, depth 64, 4 jobs, 1 GiB) ---"
  fio --name=randrw7030 \
      --filename="$FIO_FILE" \
      --rw=randrw \
      --rwmixread=70 \
      --bs=4k \
      --size=1G \
      --iodepth=64 \
      --numjobs=4 \
      --direct=1 \
      --time_based=0

  echo
  echo "Cleaning up fio test file..."
  rm -f "$FIO_FILE" || true
else
  echo "!! Skipping disk tests – install with: sudo apt-get install -y fio"
fi

### --------- SECTION 4: CPU BENCHMARKS ---------

banner "SECTION 4: CPU benchmarks (sysbench)"

if need_cmd sysbench sysbench; then
  THREADS="$CORES"
  echo "Using $THREADS threads."

  echo
  echo "--- [4.1] CPU prime calculation, 10 seconds ---"
  sysbench cpu \
    --threads="$THREADS" \
    --time=10 run

  echo
  echo "--- [4.2] Thread scheduler / context-switch test, 10 seconds ---"
  sysbench threads \
    --threads="$THREADS" \
    --time=10 run
else
  echo "!! Skipping CPU tests – install with: sudo apt-get install -y sysbench"
fi

### --------- SECTION 5: MEMORY THROUGHPUT ---------

banner "SECTION 5: Memory throughput (sysbench)"

if command -v sysbench &>/dev/null; then
  THREADS="$CORES"
  echo "Using $THREADS threads."

  echo
  echo "--- [5.1] Memory read/write throughput ---"
  sysbench memory \
    --threads="$THREADS" \
    --time=10 run
else
  echo "!! Skipping memory tests – sysbench not installed."
fi

### --------- SECTION 6: VALIDATOR HEALTH ---------

banner "SECTION 6: Qubetics validator node health"

if need_cmd curl curl; then
  echo "--- [6.1] Tendermint sync info ---"
  if command -v jq &>/dev/null; then
    curl -s localhost:26657/status | jq '.result.sync_info' || echo "Error querying /status"
  else
    echo "jq not installed; raw /status output:"
    curl -s localhost:26657/status || echo "Error querying /status"
    echo
    echo "!! Install jq for nicer JSON: sudo apt-get install -y jq"
  fi

  echo
  echo "--- [6.2] Peer count ---"
  if command -v jq &>/dev/null; then
    curl -s localhost:26657/net_info | jq '.result.n_peers' || echo "Error querying /net_info"
  else
    curl -s localhost:26657/net_info || echo "Error querying /net_info"
  fi

  echo
  echo "--- [6.3] Tendermint /health ---"
  curl -s localhost:26657/health || echo "Error querying /health"
else
  echo "!! curl not found – cannot query node RPC locally."
fi

### --------- DONE ---------

banner "Benchmark complete"

echo "Tip:"
echo "  Run with:   ./validator_benchmark.sh | tee validator-benchmark-\$(date +%F).log"
echo "  Share that log (or a summarized version) with delegators as your performance report."
