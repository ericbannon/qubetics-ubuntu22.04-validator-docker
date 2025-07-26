#========================================================================================================================================================
# SNAPSHOT DOWNLOAD AND RESTORATION
#========================================================================================================================================================

print_status "Starting snapshot download and restoration process..."

# Stop the service if it's running
if pgrep -x "qubeticsd" > /dev/null; then
  echo "Stopping existing qubeticsd process..."
  pkill -9 qubeticsd
  sleep 2
fi

# Define snapshot URL and filename
SNAPSHOT_URL="https://snapshots.ticsscan.com/mainnet-qubetics.zip"
SNAPSHOT_FILE="mainnet-qubetics.zip"


print_status "Downloading snapshot from $SNAPSHOT_URL..."

# Download snapshot with error checking
if command -v curl >/dev/null 2>&1; then
    curl -L "$SNAPSHOT_URL" -o "$SNAPSHOT_FILE"
elif command -v wget >/dev/null 2>&1; then
    wget "$SNAPSHOT_URL" -O "$SNAPSHOT_FILE"
else
    print_error "Neither curl nor wget is available for downloading snapshot"
    exit 1
fi

# Verify download
if [ ! -f "$SNAPSHOT_FILE" ]; then
    print_error "Failed to download snapshot"
    exit 1
fi

print_status "Snapshot downloaded successfully"

# Check if priv_validator_state.json exists before backing it up
if [ -f "$HOMEDIR/data/priv_validator_state.json" ]; then
    print_status "Backing up priv_validator_state.json..."
    mv "$HOMEDIR/data/priv_validator_state.json" "$HOMEDIR/priv_validator_state.json"
else
    print_warning "priv_validator_state.json not found, skipping backup"
fi

print_status "Resetting blockchain data..."
qubeticsd tendermint unsafe-reset-all --home "$HOMEDIR"

print_status "Extracting snapshot..."
unzip  "$SNAPSHOT_FILE" -d "$HOMEDIR/data/"

# Check if the backup exists before restoring
if [ -f "$HOMEDIR/priv_validator_state.json" ]; then
    print_status "Restoring priv_validator_state.json..."
    mv "$HOMEDIR/priv_validator_state.json" "$HOMEDIR/data/priv_validator_state.json"
else
    print_warning "Backup priv_validator_state.json not found, skipping restoration"
fi


print_status "Snapshot restoration completed successfully"

# Start the service
print_status "Starting qubeticschain service..."

# Optional: Ensure cosmovisor is in PATH
export PATH="$HOME/go/bin:$PATH"
export DAEMON_NAME=qubeticsd
export DAEMON_HOME="$HOMEDIR"
export DAEMON_ALLOW_DOWNLOAD_BINARIES=false
export DAEMON_RESTART_AFTER_UPGRADE=true
export DAEMON_LOG_BUFFER_SIZE=512
export UNSAFE_SKIP_BACKUP=false

# Start the node
exec cosmovisor run start \
  --home "$DAEMON_HOME" \
  --json-rpc.api eth,txpool,personal,net,debug,web3

print_status "Node setup with snapshot completed successfully!"
