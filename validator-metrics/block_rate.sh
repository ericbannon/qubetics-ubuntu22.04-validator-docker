#!/bin/bash

LOG_FILE="/mnt/nvme/qubetics/cosmovisor.log"
DURATION_MINUTES=3

echo "📡 Watching block production for $DURATION_MINUTES minutes..."
echo "⏳ Start time: $(date)"

block_count=$(timeout ${DURATION_MINUTES}m tail -n0 -F "$LOG_FILE" 2>/dev/null | awk '
function strip_ansi(str) {
  gsub(/\x1b\[[0-9;]*m/, "", str)
  return str
}
{
  line = strip_ansi($0)
  if (tolower(line) ~ /executed/) {
    count++
  }
}
END {
  print count+0
}
')

rate_per_minute=$(( block_count / DURATION_MINUTES ))

echo
echo "✅ Done watching at: $(date)"
echo "🧱 Block count: $block_count"
echo "📈 Average block rate: $rate_per_minute blocks per minute"