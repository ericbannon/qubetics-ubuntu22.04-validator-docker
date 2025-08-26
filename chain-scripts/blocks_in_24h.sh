#!/usr/bin/env bash
set -euo pipefail

RPC="${RPC:-http://localhost:26657}"

jq_time_to_epoch() { # read RFC3339 time on stdin -> epoch seconds
  jq -r -e '.result.block.header.time' | xargs -I{} date -u -d "{}" +%s
}

get_height() { curl -s "$RPC/status" | jq -r '.result.sync_info.latest_block_height' ; }
get_time_at() { # $1 = height -> epoch
  curl -s "$RPC/block?height=$1" | jq_time_to_epoch
}

# latest height/time
LATEST_H=$(get_height)
LATEST_T=$(curl -s "$RPC/status" | jq -r '.result.sync_info.latest_block_time' | xargs -I{} date -u -d "{}" +%s)

TARGET_T=$(date -u -d '24 hours ago' +%s)

# If clock weirdness:
if [[ -z "$LATEST_H" || "$LATEST_H" = "null" ]]; then
  echo "Couldn't get latest height"; exit 1
fi

# --- Exponential walk back until we cross the target time ---
low=1
high=$LATEST_H
h=$LATEST_H
step=1

t_at_h=$(get_time_at "$h")
if (( t_at_h < TARGET_T )); then
  # chain produces < 24h of history, so 24h ago is before genesis range
  echo "Blocks in last 24h: $(( LATEST_H - 1 ))"
  exit 0
fi

while (( h > 1 )); do
  prev=$h
  h=$(( h - step ))
  (( h < 1 )) && h=1
  t=$(get_time_at "$h")
  if (( t <= TARGET_T )); then
    # crossed the boundary: [h .. prev] straddles the target
    low=$h
    high=$prev
    break
  fi
  step=$(( step * 2 ))
done

# Safety if we never broke (all blocks within last 24h)
if (( low == 1 && high == LATEST_H && h == 1 )); then
  # Oldest block is still > target -> everything is within 24h
  echo "Blocks in last 24h: $LATEST_H"
  exit 0
fi

# --- Binary search to find the first height with time > TARGET_T ---
while (( low + 1 < high )); do
  mid=$(( (low + high) / 2 ))
  tm=$(get_time_at "$mid")
  if (( tm <= TARGET_T )); then
    low=$mid
  else
    high=$mid
  fi
done

# `high` is the first height strictly after TARGET_T,
# so blocks in last 24h = LATEST_H - low (or = LATEST_H - (high-1))
BLOCKS_24H=$(( LATEST_H - low ))
echo "$BLOCKS_24H"
