#!/usr/bin/env bash
set -euo pipefail

# Tendermint RPC (validator node)
RPC="${RPC:-http://localhost:26657}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <height1> [height2 ...]"
  echo "Example: $0 2572150 2572160 2572170"
  exit 1
fi

echo "[INFO] Using RPC: $RPC"
echo

for H in "$@"; do
  echo "===== HEIGHT $H ====="

  # --- Fetch validator set at this height ---
  vals_json=$(curl -sf "$RPC/validators?height=$H&per_page=300" 2>/dev/null || echo "")
  if [[ -z "$vals_json" ]]; then
    echo "  [ERROR] Could not fetch /validators for height $H"
    echo
    continue
  fi

  # Build array of {address, voting_power}
  vals=$(echo "$vals_json" | jq '.result.validators | map({address, voting_power: (.voting_power | tonumber)})')

  total_power=$(echo "$vals" | jq '[.[].voting_power] | add')
  val_count=$(echo "$vals" | jq 'length')

  # --- Fetch commit for this height ---
  commit_json=$(curl -sf "$RPC/commit?height=$H" 2>/dev/null || echo "")
  if [[ -z "$commit_json" ]]; then
    echo "  [ERROR] Could not fetch /commit for height $H"
    echo
    continue
  fi

  # Extract all validator addresses that actually signed this block
  signers=$(echo "$commit_json" | jq '
    .result.signed_header.commit.signatures[]
    | select(.block_id_flag == 2)
    | .validator_address
    ' | jq -s '.')

  signer_count=$(echo "$signers" | jq 'length')

  # Compute total voting power of signers by joining signers with vals
  signed_power=$(jq -n --argjson vals "$vals" --argjson signers "$signers" '
    # map of address -> voting_power
    ($vals | map({ (.address): .voting_power }) | add) as $m
    # sum power for all signer addresses that exist in the map
    | ($signers | map($m[.] // 0) | add)
  ')

  # Compute 2/3 threshold & percentage
  two_thirds=$(echo "$total_power" | awk '{printf "%.0f", ($1 * 2 / 3)}')
  pct=$(echo "$signed_power $total_power" | awk '{printf "%.2f", (100.0 * $1 / $2)}')

  status="NOT_OK"
  if (( signed_power >= two_thirds )); then
    status="OK_2_3_REACHED"
  fi

  echo "  Validators in set       : $val_count"
  echo "  Total voting power      : $total_power"
  echo "  Signers in commit       : $signer_count"
  echo "  Signed voting power     : $signed_power"
  echo "  2/3 threshold           : $two_thirds"
  echo "  Signed % of total power : ${pct}%"
  echo "  Status                  : $status"
  echo

done
