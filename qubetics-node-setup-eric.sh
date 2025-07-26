#!/bin/bash
set -e

# Basic paths
BINARY="qubeticsd"
INSTALL_PATH="/usr/local/bin/"
HOMEDIR="/mnt/nvme/qubetics"
CONFIG=$HOMEDIR/config/config.toml
APP_TOML=$HOMEDIR/config/app.toml
CLIENT=$HOMEDIR/config/client.toml
GENESIS=$HOMEDIR/config/genesis.json
TMP_GENESIS=$HOMEDIR/config/tmp_genesis.json

# Environment variables for Cosmovisor
export DAEMON_NAME=qubeticsd
export DAEMON_HOME=$HOMEDIR
export DAEMON_ALLOW_DOWNLOAD_BINARIES=false
export DAEMON_RESTART_AFTER_UPGRADE=true
export DAEMON_LOG_BUFFER_SIZE=512
export UNSAFE_SKIP_BACKUP=false
export PATH="$INSTALL_PATH:$PATH"

# Increase open file limit
ulimit -n 16384

# Check and install binary
if [ -f "$PWD/ubuntu22.04build/$BINARY" ]; then
  cp "$PWD/ubuntu22.04build/$BINARY" "$INSTALL_PATH"
  chmod +x "${INSTALL_PATH}${BINARY}"
  echo "$BINARY installed successfully at $INSTALL_PATH"
else
  echo "Binary not found at expected path."
  exit 1
fi

# Prompt for node moniker
read -rp "Enter node moniker: " MONIKER

# Remove old config if requested
if [ -d "$HOMEDIR" ]; then
  echo "Found existing node config at $HOMEDIR"
  read -rp "Overwrite it? [y/N]: " overwrite
else
  overwrite="y"
fi

if [[ "$overwrite" =~ ^[Yy]$ ]]; then
  rm -rf "$HOMEDIR"
  mkdir -p "$HOMEDIR"
  echo "Old configuration wiped. Starting fresh."

  # Initialize node
  $BINARY config keyring-backend os --home "$HOMEDIR"
  $BINARY config chain-id qubetics_9030-1 --home "$HOMEDIR"
  $BINARY init "$MONIKER" -o --chain-id qubetics_9030-1 --home "$HOMEDIR"
  $BINARY keys add bob --keyring-backend os --algo eth_secp256k1 --home "$HOMEDIR"

  # Update genesis
  jq '.app_state["staking"]["params"]["bond_denom"]="tics"' "$GENESIS" >"$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"
  jq '.app_state["gov"]["deposit_params"]["min_deposit"][0]["denom"]="tics"' "$GENESIS" >"$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"
  jq '.app_state["mint"]["params"]["mint_denom"]="tics"' "$GENESIS" >"$TMP_GENESIS" && mv "$TMP_GENESIS" "$GENESIS"

  # Overwrite with actual genesis if provided
  if [ -f "$PWD/genesis.json" ]; then
    cp "$PWD/genesis.json" "$GENESIS"
  fi

  $BINARY validate-genesis --home "$HOMEDIR"

  # Configure peers and ports
  sed -i 's/localhost/0.0.0.0/g' "$CONFIG" "$APP_TOML" "$CLIENT"
  sed -i 's/:26660/0.0.0.0:26660/g' "$CONFIG"
  sed -i 's/seeds = ""/seeds = ""/' "$CONFIG"
  sed -i 's/prometheus = false/prometheus = true/' "$CONFIG"
  sed -i 's/enabled = false/enabled = true/g' "$APP_TOML"
  sed -i 's/minimum-gas-prices = "0tics"/minimum-gas-prices = "0.25tics"/' "$APP_TOML"
  sed -i 's/enable-unsafe-cors = false/enable-unsafe-cors = true/g' "$APP_TOML"

  # Print validator info
  echo "=================================================================="
  echo "Tendermint Key: $($BINARY tendermint show-validator --home $HOMEDIR)"
  echo "Node ID: $($BINARY tendermint show-node-id --home $HOMEDIR)"
  echo "Address: $($BINARY keys show bob --home $HOMEDIR --keyring-backend os -a)"
  echo "=================================================================="
fi

# Initialize Cosmovisor directories
cosmovisor init "$INSTALL_PATH$BINARY"

# Start node via Cosmovisor in background with logging
echo "Starting Cosmovisor..."
cosmovisor run start \
  --home "$DAEMON_HOME" \
  --json-rpc.api eth,txpool,personal,net,debug,web3 \
  >> "$DAEMON_HOME/cosmovisor.log" 2>&1 &
disown

echo "✅ Cosmovisor started and logging to $DAEMON_HOME/cosmovisor.log"