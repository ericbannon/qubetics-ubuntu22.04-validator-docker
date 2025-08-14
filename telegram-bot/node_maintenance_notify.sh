#!/bin/bash

# === CONFIGURATION ===
TELEGRAM_BOT_TOKEN="<redacted>"
TELEGRAM_CHAT_ID="<redacted>"
DOCKER_NAME="validator-node"
NODE_NAME="Block Dock Validator-validator-node"
MAX_WAIT_TIME=300  # max seconds to wait for container to be healthy
CHECK_INTERVAL=5   # interval between health checks

# === TELEGRAM MESSAGE FUNCTION ===
send_telegram() {
  local message="$1"
  curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="$message" > /dev/null
}

# === 1. SEND MAINTENANCE NOTICE ===
send_telegram "⚙️ *Block Dock Validator Validator - Node Maintenance Notice*

🔄 Rebooting node container: \`$NODE_NAME\`
📦 Applying updates / restart sequence...
⏱️ Expected downtime: *~2–5 minutes*

No action needed. Your funds are safe 🛡️"

# === 3. WAIT FOR HEALTHY STATUS ===
elapsed=0
while [[ $elapsed -lt $MAX_WAIT_TIME ]]; do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$DOCKER_NAME" 2>/dev/null)

  # If no health check defined, fall back to "running" state
  if [[ -z "$status" || "$status" == "<no value>" ]]; then
    status=$(docker inspect -f '{{.State.Status}}' "$DOCKER_NAME")
    if [[ "$status" == "running" ]]; then
      break
    fi
  fi

  if [[ "$status" == "healthy" ]]; then
    break
  fi

  sleep "$CHECK_INTERVAL"
  ((elapsed+=CHECK_INTERVAL))
done

# === 4. SEND "BACK ONLINE" MESSAGE ===
if [[ "$status" == "healthy" || "$status" == "running" ]]; then
  send_telegram "✅ *Block Dock Validator is Back Online*

Container \`$NODE_NAME\` is *running and healthy* 🟢
Monitoring and node sync have resumed.

Thank you for your trust 🙌"
else
  send_telegram "❌ *Validator Node Restart Warning*

Container \`$NODE_NAME\` failed to reach a healthy state after *$MAX_WAIT_TIME seconds*.
Check logs and validator sync manually.

🔍 Use: \`docker logs $DOCKER_NAME\`"
fi