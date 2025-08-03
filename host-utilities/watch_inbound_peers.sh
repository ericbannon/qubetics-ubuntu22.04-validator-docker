#!/bin/bash

# File to track previous peer count
STATE_FILE="/tmp/inbound_peer_state"

# Query the current inbound peer count
inbound=$(curl -s http://localhost:26657/net_info | jq '[.result.peers[] | select(.is_outbound == false)] | length')

# Read previous state
prev=$(cat "$STATE_FILE" 2>/dev/null || echo "0")

# Log time and status
timestamp=$(date "+%Y-%m-%d %H:%M:%S")
echo "$timestamp - Inbound peers: $inbound"

# Trigger on first inbound peer
if [[ "$inbound" -gt 0 && "$prev" -eq 0 ]]; then
    echo "$timestamp - 🎉 FIRST INBOUND PEER DETECTED!" | tee -a ~/inbound_peer_log.txt
fi

# Update state file
echo "$inbound" > "$STATE_FILE"
