#!/bin/bash

# Your validator's consensus address (from priv_validator_key.json)
MY_ADDR="Your Validator Address"

# Number of recent blocks to check
NUM_BLOCKS=20

# Node RPC
NODE="http://localhost:26657"

# Get latest block height using jq (JSON output)
LATEST=$(qubeticsd status --node=$NODE | jq -r '.SyncInfo.latest_block_height')

if ! [[ "$LATEST" =~ ^[0-9]+$ ]]; then
  echo "❌ Failed to detect latest block height. Got: $LATEST"
  exit 1
fi

echo "🔍 Checking if validator $MY_ADDR proposed any of the last $NUM_BLOCKS blocks (latest: $LATEST)..."

FOUND=0

for ((i=0; i<$NUM_BLOCKS; i++)); do
  HEIGHT=$((LATEST - i))
  BLOCK_OUTPUT=$(qubeticsd query block $HEIGHT --node=$NODE | jq -r '.block.header.proposer_address')

  if [[ "$BLOCK_OUTPUT" == "$MY_ADDR" ]]; then
    echo "✅ Block $HEIGHT was proposed by YOU!"
    FOUND=1
  elif [[ -z "$BLOCK_OUTPUT" ]]; then
    echo "⚠️  Block $HEIGHT: proposer not found"
  else
    echo "⏳ Block $HEIGHT proposed by $BLOCK_OUTPUT"
  fi
done

if [[ $FOUND -eq 0 ]]; then
  echo "❌ Your validator has not proposed any of the last $NUM_BLOCKS blocks."
fi
