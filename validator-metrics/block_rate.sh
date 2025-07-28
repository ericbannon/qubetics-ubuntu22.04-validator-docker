#!/bin/bash

LOG_FILE="/mnt/nvme/qubetics/cosmovisor.log"
WINDOW_MINUTES=10

echo "📊 Analyzing block rate over the last $WINDOW_MINUTES minutes..."

now=$(date +%s)
start_time=$((now - WINDOW_MINUTES * 60))
today=$(date +%Y-%m-%d)

block_count=$(awk -v today="$today" -v start="$start_time" -v now="$now" '
function strip_ansi(str) {
  gsub(/\x1b\[[0-9;]*m/, "", str)
  return str
}
{
  line = strip_ansi($0)
  if (tolower(line) ~ /executed/) {
    split(line, fields, " ")
    time_str = fields[1]
    full_ts = today " " time_str

    cmd = "date -d \"" full_ts "\" +%s"
    cmd | getline epoch
    close(cmd)

    if (epoch >= start && epoch <= now) {
      count++
    }
  }
}
END {
  print count+0
}
' "$LOG_FILE")

rate_per_minute=$(( block_count / WINDOW_MINUTES ))

echo "🧱 Block count (last $WINDOW_MINUTES minutes): $block_count"
echo "⏱️ Block rate per minute: $rate_per_minute"
