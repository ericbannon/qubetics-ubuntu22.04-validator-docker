#!/bin/bash
# Qubetics missed block alert with Telegram notification

HOME_DIR="/mnt/nvme/qubetics"
THRESHOLD=2000  # alert when missed blocks >= this number
CHECK_INTERVAL=60  # seconds
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

send_alert() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="$message" >/dev/null
}

while true; do
    MISSED=$(qubeticsd query slashing signing-info \
        $(qubeticsd tendermint show-validator --home "$HOME_DIR") \
        --home "$HOME_DIR" \
        --output json 2>/dev/null \
        | jq -r .missed_blocks_counter)

    if [[ -n "$MISSED" ]]; then
        echo "$(date) - Missed blocks: $MISSED"
        if (( MISSED >= THRESHOLD )); then
            send_alert "⚠ Qubetics Validator Alert: Missed blocks counter is $MISSED (>= $THRESHOLD)! Home: $HOME_DIR"
        fi
    else
        echo "$(date) - ERROR: Could not fetch missed blocks"
    fi

    sleep "$CHECK_INTERVAL"
done
