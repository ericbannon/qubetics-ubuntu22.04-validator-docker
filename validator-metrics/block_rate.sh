#!/bin/bash

LOG_FILE="/mnt/nvme/qubetics/cosmovisor.log"
LINES=5000

echo "📊 Analyzing last $LINES log lines for block rate..."

# Extract timestamps and calculate block rate per minute
tail -n "$LINES" "$LOG_FILE" \
  | grep 'height=' \
  | awk '{
      split($1, ts, "T")
      split(ts[2], time, ":")
      minute = time[1] ":" time[2]
      count[minute]++
  }
  END {
      for (m in count)
          printf "🕒 %s — Block rate per minute: %d\n", m, count[m]
  }' | sort

