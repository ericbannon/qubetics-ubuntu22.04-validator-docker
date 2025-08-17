#!/bin/sh
# One-time IO check (with WAL growth) – waits INTERVAL seconds, then prints results

DATA_DIR="/mnt/nvme/qubetics"                 # adjust if needed
WAL_DIR="/mnt/nvme/qubetics/data/cs.wal"      # change if your WAL path differs
MOUNT_POINT="/mnt/nvme"
CONTAINER_NAME="validator-node"
INTERVAL=60

# Determine block device for the mount (portable)
BLKDEV=$(df "$MOUNT_POINT" | awk 'NR==2 {print $1}' | sed 's#/dev/##')

bytes_of() {
  p="$1"
  if [ -d "$p" ]; then du -sb "$p" 2>/dev/null | awk '{print $1}'; else echo 0; fi
}

# Start snapshot
start_data=$(bytes_of "$DATA_DIR")
start_wal=$(bytes_of "$WAL_DIR")
start_wr=$(awk -v d="$BLKDEV" '$3==d {print $10}' /proc/diskstats)
start_ts=$(date +%s)

echo "Measuring for ${INTERVAL}s…"
sleep "$INTERVAL"

# End snapshot
end_data=$(bytes_of "$DATA_DIR")
end_wal=$(bytes_of "$WAL_DIR")
end_wr=$(awk -v d="$BLKDEV" '$3==d {print $10}' /proc/diskstats)
end_ts=$(date +%s)

# Compute
dt=$((end_ts - start_ts))
delta_data=$((end_data - start_data))
delta_wal=$((end_wal - start_wal))
wr_kBps=$(( (end_wr - start_wr) * 512 / 1024 / (dt>0?dt:1) ))

fs_line=$(df -h "$MOUNT_POINT" | awk 'NR==2 {print $3" used / "$4" free ("$5")"}')
docker_blk=$(docker stats --no-stream --format '{{.BlockIO}}' "$CONTAINER_NAME" 2>/dev/null | awk '{print $1}')

# Print
echo "=== IO check ==="
echo "Data dir growth:   $((delta_data/1024/1024)) MiB in ${dt}s"
echo "WAL dir growth:    $((delta_wal/1024/1024)) MiB in ${dt}s  (${WAL_DIR})"
echo "Filesystem usage:  $fs_line"
echo "Device writes:     ${wr_kBps} kB/s"
echo "Docker Block I/O:  $docker_blk (cumulative)"
