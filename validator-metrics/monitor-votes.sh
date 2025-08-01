#!/bin/bash
LOG_FILE="/mnt/nvme/qubetics/cosmovisor.log" # adjust if different

echo "🔍 Monitoring for block proposal & missed vote activity..."
echo "Log file: $LOG_FILE"
echo "Timestamp: $(date)"
echo

# Show live filtered logs
tail -n 1000 -F "$LOG_FILE" | grep --line-buffered -Ei "propos|missed|vote"