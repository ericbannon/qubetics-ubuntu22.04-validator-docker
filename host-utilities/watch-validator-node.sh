#!/usr/bin/env bash
set -euo pipefail

CONTAINER="validator-node"
STARTUP="/home/admin/scripts/validator-startup.sh"
STATE="/run/validator-node-watch/laststart"  # systemd creates/owns this dir
MIN_GAP=20                                    # seconds between runs to avoid duplicates

# wait until docker is ready
until docker info >/dev/null 2>&1; do sleep 2; done

# stream only start/restart for this container
docker events \
  --format '{{.Time}} {{.Action}} {{.ID}}' \
  --filter "container=${CONTAINER}" \
  --filter "event=start" \
  --filter "event=restart" \
| while read -r ts action id; do
    now="$(date +%s)"
    last="$(cat "$STATE" 2>/dev/null || echo 0)"
    # simple debounce (docker may emit start+start or restart+start)
    if (( now - last < MIN_GAP )); then
      continue
    fi
    echo "$now" > "$STATE"

    echo "[$(date)] container=${CONTAINER} action=${action} id=${id} -> running startup"
    /bin/bash "$STARTUP" || echo "validator-startup.sh exited non-zero"
  done