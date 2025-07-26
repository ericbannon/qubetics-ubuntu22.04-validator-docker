#!/bin/bash

set -e  # Exit on error

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Functions
print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Environment variables (adjust if necessary)
export DAEMON_NAME=qubeticsd
export DAEMON_HOME=/mnt/nvme/qubetics
export DAEMON_ALLOW_DOWNLOAD_BINARIES=false
export DAEMON_RESTART_AFTER_UPGRADE=true
export DAEMON_LOG_BUFFER_SIZE=512
export UNSAFE_SKIP_BACKUP=false

print_status "Starting snapshot download and restoration process..."

# Stop any running cosmovisor process
if pgrep -x "$DAEMON_NAME" >/dev/null; then
  print_status "Stopping existing $DAEMON_NAME process..."
  pkill -9 "$DAEMON_NAME"
  sleep 2
fi

# Snapshot config
SNAPSHOT_URL="https://snapshots.ticsscan.com/mainnet-qubetics.zip"
SNAPSHOT_FILE="mainnet-qubetics.zip"

print_status "Downloading snapshot from $SNAPSHOT_URL..."

# Download
if command -v curl >/dev/null 2>&1; then
  curl -L "$SNAPSHOT_URL" -o "$SNAPSHOT_FILE"
elif command -v wget >/dev/null 2>&1; then
  wget "$SNAPSHOT_URL" -O "$SNAPSHOT_FILE"
else
  print_error "Neither curl nor wget available"
  exit 1
fi

# Verify
if [ ! -f "$SNAPSHOT_FILE" ]; then
  print_error "Snapshot download failed"
  exit 1
fi

print_status "Snapshot downloaded successfully"

# Backup validator state
if [ -f "$DAEMON_HOME/data/priv_validator_state.json" ]; then
  print_status "Backing up priv_validator_state.json"
  mv "$DAEMON_HOME/data/priv_validator_state.json" "$DAEMON_HOME/priv_validator_state.json"
else
  print_warning "priv_validator_state.json not found"
fi

# Reset state using Cosmovisor wrapper
print_status "Resetting blockchain state..."
cosmovisor run tendermint unsafe-reset-all --home "$DAEMON_HOME"

# Unzip
print_status "Extracting snapshot..."
unzip "$SNAPSHOT_FILE" -d "$DAEMON_HOME"
rm "$SNAPSHOT_FILE"

# Restore validator state
if [ -f "$DAEMON_HOME/priv_validator_state.json" ]; then
  print_status "Restoring priv_validator_state.json"
  mv "$DAEMON_HOME/priv_validator_state.json" "$DAEMON_HOME/data/priv_validator_state.json"
else
  print_warning "Backup priv_validator_state.json not found"
fi

# Restart node
print_status "Starting Cosmovisor in background..."
nohup cosmovisor run start \
  --home "$DAEMON_HOME" \
  --json-rpc.api eth,txpool,personal,net,debug,web3 \
  >> "$DAEMON_HOME/cosmovisor.log" 2>&1 &
disown

print_status "Node started and syncing. Logs: $DAEMON_HOME/cosmovisor.log"
