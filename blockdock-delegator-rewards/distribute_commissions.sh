#!/usr/bin/env bash
set -euo pipefail

#############################################
# Config via environment variables
#############################################
BINARY="${BINARY:-qubeticsd}"
VALOPER="${VALOPER:?VALOPER (validator operator addr) is required}"
FROM_KEY="${FROM_KEY:?FROM_KEY (key name) is required}"
FROM_ADDR="${FROM_ADDR:?FROM_ADDR (wallet address) is required}"
HOME_DIR="${HOME_DIR:-$HOME/.qubeticsd}"
CHAIN_ID="${CHAIN_ID:?CHAIN_ID is required}"
NODE="${NODE:-tcp://localhost:26657}"
POOL_RESERVE_TICS="${POOL_RESERVE_TICS:-0}"   # in *base* denom units
KEYRING_BACKEND="${KEYRING_BACKEND:-file}"
KEYRING_PASS="${KEYRING_PASS:-}"

DENOM="${DENOM:-tics}"
GAS_LIMIT="${GAS_LIMIT:-200000}"
GAS_PRICES="${GAS_PRICES:-0.025${DENOM}}"

#############################################
# Helpers
#############################################

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_cmd jq
require_cmd bc

echo "[INFO] Validator:  $VALOPER"
echo "[INFO] From key:   $FROM_KEY"
echo "[INFO] From addr:  $FROM_ADDR"
echo "[INFO] Home dir:   $HOME_DIR"
echo "[INFO] Chain-ID:   $CHAIN_ID"
echo "[INFO] Node:       $NODE"
echo "[INFO] Pool reserve: $POOL_RESERVE_TICS $DENOM (base units)"

#############################################
# Query account_number & sequence
#############################################

echo
echo "[INFO] Querying account_number & sequence for $FROM_ADDR ..."

ACCOUNT_JSON="$(
  "$BINARY" q auth account "$FROM_ADDR" \
    --node "$NODE" \
    --chain-id "$CHAIN_ID" \
    --home "$HOME_DIR" \
    -o json
)"

ACCOUNT_NUMBER="$(
  echo "$ACCOUNT_JSON" | jq -r '
    .account_number // .base_account.account_number // .base_vesting_account.base_account.account_number // empty
  '
)"

SEQUENCE="$(
  echo "$ACCOUNT_JSON" | jq -r '
    .sequence // .base_account.sequence // .base_vesting_account.base_account.sequence // empty
  '
)"

[ -n "$ACCOUNT_NUMBER" ] || die "Could not parse account_number from auth account"
[ -n "$SEQUENCE" ]       || die "Could not parse sequence from auth account"

echo "[INFO] account_number: $ACCOUNT_NUMBER"
echo "[INFO] sequence:       $SEQUENCE"

NEXT_SEQUENCE="$SEQUENCE"

#############################################
# Query delegations
#############################################

echo
echo "[INFO] Querying delegations to $VALOPER ..."

DELEG_JSON="$(
  "$BINARY" q staking delegations-to "$VALOPER" \
    --node "$NODE" \
    --chain-id "$CHAIN_ID" \
    --home "$HOME_DIR" \
    --limit 1000000 \
    -o json
)"

DELEG_COUNT="$(echo "$DELEG_JSON" | jq '.delegation_responses | length')"
[ "$DELEG_COUNT" -gt 0 ] || die "No delegations found to $VALOPER"

echo
echo "[INFO] Delegator stake distribution:"
printf "  %-44s  %24s  %9s\n" "addr" "stake (tics)" "percent"
printf "  %-44s  %24s  %9s\n" "--------------------------------------------" "------------------------" "---------"

# Build arrays in bash + compute total_stake via bc
mapfile -t DELEG_LINES < <(
  echo "$DELEG_JSON" \
    | jq -r '.delegation_responses[] | "\(.delegation.delegator_address) \(.balance.amount)"'
)

TOTAL_STAKE="0"
declare -a ADDRS
declare -A STAKE

for line in "${DELEG_LINES[@]}"; do
  addr="${line%% *}"
  amount="${line##* }"   # big integer as string

  ADDRS+=("$addr")
  STAKE["$addr"]="$amount"

  TOTAL_STAKE="$(echo "$TOTAL_STAKE + $amount" | bc)"
done

# Pretty print table with percentages (for info only)
for addr in "${ADDRS[@]}"; do
  amount="${STAKE[$addr]}"
  # percent as float with 4 decimals (safe enough for display)
  percent="$(echo "scale=6; 100 * $amount / $TOTAL_STAKE" | bc)"
  # trim to 4 decimal places for display
  percent_disp="$(printf "%.4f" "$percent" 2>/dev/null || echo "$percent")"
  printf "  %-44s  %24s  %8s%%\n" "$addr" "$amount" "$percent_disp"
done

echo
echo "[INFO] Total stake: $TOTAL_STAKE $DENOM"

#############################################
# Query pool balance
#############################################

echo
echo "[INFO] Querying current balance for $FROM_ADDR ..."

BAL_JSON="$(
  "$BINARY" q bank balances "$FROM_ADDR" \
    --node "$NODE" \
    --chain-id "$CHAIN_ID" \
    --home "$HOME_DIR" \
    -o json
)"

POOL_BALANCE="$(
  echo "$BAL_JSON" \
    | jq -r --arg DENOM "$DENOM" '.balances[]? | select(.denom == $DENOM) | .amount' \
    | head -n1
)"

POOL_BALANCE="${POOL_BALANCE:-0}"

echo "[INFO] Current pool balance: $POOL_BALANCE $DENOM"

# Basic sanity
cmp_res="$(echo "$POOL_BALANCE - $POOL_RESERVE_TICS" | bc)"
if echo "$cmp_res" | grep -q '^-'; then
  die "Pool balance ($POOL_BALANCE) is less than reserve ($POOL_RESERVE_TICS)"
fi

POOL_DISTRIBUTABLE="$(echo "$POOL_BALANCE - $POOL_RESERVE_TICS" | bc)"

echo "[INFO] Pool amount to distribute (after reserve): $POOL_DISTRIBUTABLE $DENOM"

#############################################
# Compute per-delegator allocations (integer math)
#############################################

echo
echo "[INFO] Final pool allocation:"

declare -a PAYOUT_ADDRS
declare -a PAYOUT_AMOUNTS

ALLOCATED_SUM="0"

for addr in "${ADDRS[@]}"; do
  stake_amount="${STAKE[$addr]}"

  # payout = distributable * stake / total_stake (integer division)
  payout="$(echo "($POOL_DISTRIBUTABLE * $stake_amount) / $TOTAL_STAKE" | bc)"

  PAYOUT_ADDRS+=("$addr")
  PAYOUT_AMOUNTS+=("$payout")

  ALLOCATED_SUM="$(echo "$ALLOCATED_SUM + $payout" | bc)"
done

# Fix rounding leftover by adjusting the last entry
LEFTOVER="$(echo "$POOL_DISTRIBUTABLE - $ALLOCATED_SUM" | bc)"

if [ "$LEFTOVER" != "0" ]; then
  last_idx=$(( ${#PAYOUT_AMOUNTS[@]} - 1 ))
  fixed_amount="$(echo "${PAYOUT_AMOUNTS[$last_idx]} + $LEFTOVER" | bc)"
  PAYOUT_AMOUNTS[$last_idx]="$fixed_amount"
  ALLOCATED_SUM="$(echo "$ALLOCATED_SUM + $LEFTOVER" | bc)"
fi

printf "  %-44s  %20s\n" "addr" "amount (tics)"
printf "  %-44s  %20s\n" "--------------------------------------------" "--------------------"

for i in "${!PAYOUT_ADDRS[@]}"; do
  printf "  %-44s  %20s\n" "${PAYOUT_ADDRS[$i]}" "${PAYOUT_AMOUNTS[$i]}"
done

echo
echo "[INFO] Pool total:          $POOL_DISTRIBUTABLE"
echo "[INFO] Allocated sum:       $ALLOCATED_SUM"
echo "[INFO] Leftover (post-fix): $(echo "$POOL_DISTRIBUTABLE - $ALLOCATED_SUM" | bc)"

#############################################
# Confirm
#############################################

echo
read -r -p "[CONFIRM] Send these payouts from the pool now? [y/N] " ans
case "$ans" in
  y|Y|yes|YES) ;;
  *) echo "[INFO] Aborted by user."; exit 0 ;;
esac

#############################################
# Tx send helper (one-by-one, offline, manual seq)
#############################################

send_simple_tx() {
  local to_addr="$1"
  local amount_tics="$2"
  local seq="$3"

  echo
  echo "tics)  -> ${to_addr} (${amount_tics}${DENOM}) [seq=${seq}]"

  local result_json code txhash raw_log
  result_json="$(
    echo "$KEYRING_PASS" | "$BINARY" tx bank send \
      "$FROM_ADDR" \
      "$to_addr" \
      "${amount_tics}${DENOM}" \
      --from "$FROM_KEY" \
      --chain-id "$CHAIN_ID" \
      --home "$HOME_DIR" \
      --keyring-backend "$KEYRING_BACKEND" \
      --gas "$GAS_LIMIT" \
      --gas-prices "$GAS_PRICES" \
      --account-number "$ACCOUNT_NUMBER" \
      --sequence "$seq" \
      --offline \
      --broadcast-mode sync \
      -y \
      -o json 2>/dev/null || true
  )"

  code="$(echo "$result_json" | jq -r '.code // 0' 2>/dev/null || echo 0)"
  txhash="$(echo "$result_json" | jq -r '.txhash // empty' 2>/dev/null || echo "")"
  raw_log="$(echo "$result_json" | jq -r '.raw_log // empty' 2>/dev/null || echo "")"

  if [ "$code" != "0" ]; then
    echo "tics ] FAILED code=${code}"
    [ -n "$raw_log" ] && echo "       raw_log: ${raw_log}"
    [ -n "$txhash" ] && echo "       txhash:  ${txhash}"
    return 1
  fi

  echo "ticsO] Tx SUCCESS"
  [ -n "$txhash" ] && echo "[INFO] txhash: ${txhash}"
  return 0
}

#############################################
# Broadcast payouts
#############################################

FAIL_FILE="$(mktemp /tmp/payout_failures.XXXXXX)"
FAIL_COUNT=0

echo
echo "[INFO] Broadcasting ${#PAYOUT_ADDRS[@]} payouts (one-by-one, simple sync sends, manual sequence)..."

for i in "${!PAYOUT_ADDRS[@]}"; do
  to_addr="${PAYOUT_ADDRS[$i]}"
  amount="${PAYOUT_AMOUNTS[$i]}"
  idx=$(( i + 1 ))

  echo
  echo "tics)  [${idx}/${#PAYOUT_ADDRS[@]}] ${to_addr} (${amount}${DENOM})"
  echo "tics)  -> ${to_addr} (${amount}${DENOM}) [seq=${NEXT_SEQUENCE}]"

  if send_simple_tx "$to_addr" "$amount" "$NEXT_SEQUENCE"; then
    echo "ticsO] Tx succeeded for ${to_addr} ${amount}"
    NEXT_SEQUENCE=$(( NEXT_SEQUENCE + 1 ))
  else
    echo "ticsN] Tx FAILED for ${to_addr} ${amount}"
    echo "${to_addr} ${amount}" >> "$FAIL_FILE"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    # DO NOT increment NEXT_SEQUENCE on failure
  fi
done

echo
echo "[INFO] Done. All payouts attempted from current pool balance."
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "[WARN] ${FAIL_COUNT} payouts FAILED. Failed entries written to: ${FAIL_FILE}"
else
  echo "[INFO] All payouts succeeded."
  rm -f "$FAIL_FILE"
fi