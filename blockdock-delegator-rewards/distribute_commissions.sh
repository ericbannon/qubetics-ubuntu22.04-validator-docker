#!/usr/bin/env bash
set -euo pipefail

#############################################
# Config (env)
#############################################
BINARY="${BINARY:-qubeticsd}"

VALOPER="${VALOPER:?VALOPER required}"
FROM_KEY="${FROM_KEY:?FROM_KEY required}"
FROM_ADDR="${FROM_ADDR:?FROM_ADDR required}"

HOME_DIR="${HOME_DIR:-$HOME/.qubeticsd}"
CHAIN_ID="${CHAIN_ID:?CHAIN_ID required}"
NODE="${NODE:-tcp://localhost:26657}"

POOL_RESERVE_TICS="${POOL_RESERVE_TICS:-0}"

KEYRING_BACKEND="${KEYRING_BACKEND:-file}"
KEYRING_PASS="${KEYRING_PASS:-}"

DENOM="${DENOM:-tics}"
GAS_LIMIT="${GAS_LIMIT:-200000}"
GAS_PRICES="${GAS_PRICES:-0.025${DENOM}}"

TX_WAIT_TRIES="${TX_WAIT_TRIES:-120}"
TX_WAIT_SLEEP="${TX_WAIT_SLEEP:-2}"

#############################################
# Helpers
#############################################
die() { echo "[ERROR] $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing $1"; }

require_cmd jq
require_cmd bc

#############################################
# Account state
#############################################
echo "[INFO] Validator:  $VALOPER"
echo "[INFO] From key:   $FROM_KEY"
echo "[INFO] From addr:  $FROM_ADDR"
echo "[INFO] Home dir:   $HOME_DIR"
echo "[INFO] Chain-ID:   $CHAIN_ID"
echo "[INFO] Node:       $NODE"
echo "[INFO] Reserve:    $POOL_RESERVE_TICS $DENOM (base units)"
echo "[INFO] Tx wait:    tries=$TX_WAIT_TRIES sleep=${TX_WAIT_SLEEP}s"

echo
echo "[INFO] Querying account number & sequence..."

ACCOUNT_JSON="$(
  "$BINARY" q auth account "$FROM_ADDR" \
    --node "$NODE" \
    --home "$HOME_DIR" \
    -o json
)"

ACCOUNT_NUMBER="$(echo "$ACCOUNT_JSON" | jq -r '..|.account_number?|select(.)' | head -n1)"
SEQUENCE="$(echo "$ACCOUNT_JSON" | jq -r '..|.sequence?|select(.)' | head -n1)"

[ -n "$ACCOUNT_NUMBER" ] || die "account_number missing"
[ -n "$SEQUENCE" ] || die "sequence missing"

NEXT_SEQUENCE="$SEQUENCE"

echo "[INFO] account_number=$ACCOUNT_NUMBER"
echo "[INFO] starting sequence=$NEXT_SEQUENCE"

#############################################
# Delegations
#############################################
echo
echo "[INFO] Querying delegations to $VALOPER ..."

DELEG_JSON="$(
  "$BINARY" q staking delegations-to "$VALOPER" \
    --node "$NODE" \
    --home "$HOME_DIR" \
    --limit 1000000 \
    -o json
)"

mapfile -t DELEG_LINES < <(
  echo "$DELEG_JSON" | jq -r '.delegation_responses[] | "\(.delegation.delegator_address) \(.balance.amount)"'
)

[ "${#DELEG_LINES[@]}" -gt 0 ] || die "No delegations"

declare -a ADDRS
declare -A STAKE
TOTAL_STAKE=0

for l in "${DELEG_LINES[@]}"; do
  addr="${l%% *}"
  amt="${l##* }"
  ADDRS+=("$addr")
  STAKE["$addr"]="$amt"
  TOTAL_STAKE="$(echo "$TOTAL_STAKE + $amt" | bc)"
done

echo "[INFO] Delegators:  ${#ADDRS[@]}"
echo "[INFO] Total stake: $TOTAL_STAKE $DENOM"

#############################################
# Pool balance
#############################################
echo
echo "[INFO] Querying pool balance for $FROM_ADDR ..."

BAL_JSON="$(
  "$BINARY" q bank balances "$FROM_ADDR" \
    --node "$NODE" \
    --home "$HOME_DIR" \
    -o json
)"

POOL_BALANCE="$(
  echo "$BAL_JSON" | jq -r --arg d "$DENOM" '.balances[]?|select(.denom==$d)|.amount' | head -n1
)"
POOL_BALANCE="${POOL_BALANCE:-0}"

POOL_DISTRIBUTABLE="$(echo "$POOL_BALANCE - $POOL_RESERVE_TICS" | bc)"
[ "$(echo "$POOL_DISTRIBUTABLE >= 0" | bc)" -eq 1 ] || die "Insufficient balance: pool=$POOL_BALANCE reserve=$POOL_RESERVE_TICS"

echo "[INFO] Pool balance:       $POOL_BALANCE $DENOM"
echo "[INFO] Pool reserve:       $POOL_RESERVE_TICS $DENOM"
echo "[INFO] Pool distributable: $POOL_DISTRIBUTABLE $DENOM"

#############################################
# Compute payouts
#############################################
echo
echo "[INFO] Computing payouts (pro-rata)..."

declare -a PAYOUT_ADDRS
declare -a PAYOUT_AMOUNTS
ALLOCATED=0

for a in "${ADDRS[@]}"; do
  p="$(echo "($POOL_DISTRIBUTABLE * ${STAKE[$a]}) / $TOTAL_STAKE" | bc)"
  PAYOUT_ADDRS+=("$a")
  PAYOUT_AMOUNTS+=("$p")
  ALLOCATED="$(echo "$ALLOCATED + $p" | bc)"
done

LEFTOVER="$(echo "$POOL_DISTRIBUTABLE - $ALLOCATED" | bc)"
if [ "$LEFTOVER" != "0" ]; then
  last=$(( ${#PAYOUT_AMOUNTS[@]} - 1 ))
  PAYOUT_AMOUNTS[$last]="$(echo "${PAYOUT_AMOUNTS[$last]} + $LEFTOVER" | bc)"
  ALLOCATED="$(echo "$ALLOCATED + $LEFTOVER" | bc)"
  LEFTOVER="$(echo "$POOL_DISTRIBUTABLE - $ALLOCATED" | bc)"
fi

#############################################
# Preview table
#############################################
echo
echo "[INFO] Preview (stake, percent, payout):"
printf "  %-44s  %22s  %10s  %22s\n" "addr" "stake($DENOM)" "percent" "payout($DENOM)"
printf "  %-44s  %22s  %10s  %22s\n" "--------------------------------------------" "----------------------" "---------" "----------------------"

for idx in "${!ADDRS[@]}"; do
  addr="${ADDRS[$idx]}"
  stake="${STAKE[$addr]}"
  payout="${PAYOUT_AMOUNTS[$idx]}"

  # percent with 6 decimals (display-only)
  percent="$(echo "scale=8; 100 * $stake / $TOTAL_STAKE" | bc)"
  percent_disp="$(printf "%.6f" "$percent" 2>/dev/null || echo "$percent")"

  printf "  %-44s  %22s  %9s%%  %22s\n" "$addr" "$stake" "$percent_disp" "$payout"
done

echo
echo "[INFO] Summary:"
echo "[INFO] Pool distributable: $POOL_DISTRIBUTABLE"
echo "[INFO] Allocated sum:      $ALLOCATED"
echo "[INFO] Leftover:           $LEFTOVER"

[ "$LEFTOVER" = "0" ] || die "Internal math error: leftover should be 0 after fix"

#############################################
# Inclusion wait
#############################################
wait_for_inclusion() {
  local tx="$1"
  for ((i=1;i<=TX_WAIT_TRIES;i++)); do
    if out="$("$BINARY" q tx "$tx" --node "$NODE" -o json 2>/dev/null)"; then
      h="$(echo "$out" | jq -r '.height // empty')"
      c="$(echo "$out" | jq -r '.code // 0')"
      if [ -n "$h" ] && [ "$h" != "0" ] && [ "$c" = "0" ]; then
        echo "[INFO] Included at height $h"
        return 0
      fi
      if [ -n "$h" ] && [ "$h" != "0" ] && [ "$c" != "0" ]; then
        echo "[ERROR] Included but failed: height=$h code=$c"
        echo "$out" | jq -r '.raw_log // empty' | sed 's/^/[ERROR] raw_log: /'
        return 1
      fi
    fi
    echo "[INFO] Waiting for inclusion ($i/$TX_WAIT_TRIES): $tx"
    sleep "$TX_WAIT_SLEEP"
  done
  echo "[ERROR] Inclusion timeout: $tx"
  return 1
}

#############################################
# Send tx (manual seq) and wait for inclusion
#############################################
send_tx() {
  local to="$1" amt="$2" seq="$3"

  echo
  echo "[SEND] $to ${amt}${DENOM} seq=$seq"

  local result code txh raw
  result="$(
    printf '%s\n' "$KEYRING_PASS" | "$BINARY" tx bank send \
      "$FROM_ADDR" "$to" "${amt}${DENOM}" \
      --from "$FROM_KEY" \
      --chain-id "$CHAIN_ID" \
      --node "$NODE" \
      --home "$HOME_DIR" \
      --keyring-backend "$KEYRING_BACKEND" \
      --gas "$GAS_LIMIT" \
      --gas-prices "$GAS_PRICES" \
      --account-number "$ACCOUNT_NUMBER" \
      --sequence "$seq" \
      --broadcast-mode sync \
      -y -o json 2>&1
  )"

  if ! echo "$result" | jq -e . >/dev/null 2>&1; then
    echo "[ERROR] non-JSON tx output:"
    echo "$result"
    return 1
  fi

  code="$(echo "$result" | jq -r '.code // 0')"
  txh="$(echo "$result" | jq -r '.txhash // empty')"
  raw="$(echo "$result" | jq -r '.raw_log // empty')"

  if [ "$code" != "0" ] || [ -z "$txh" ]; then
    echo "[ERROR] CheckTx failed code=$code"
    [ -n "$raw" ] && echo "[ERROR] raw_log: $raw"
    echo "$result"
    return 1
  fi

  echo "[INFO] txhash=$txh"
  wait_for_inclusion "$txh"
}

#############################################
# Execute payouts
#############################################
echo
read -r -p "[CONFIRM] Broadcast payouts with inclusion wait? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "[INFO] Aborted."; exit 0; }

echo
echo "[INFO] Broadcasting ${#PAYOUT_ADDRS[@]} payouts (sync + wait-for-inclusion + manual sequence)..."

for i in "${!PAYOUT_ADDRS[@]}"; do
  send_tx "${PAYOUT_ADDRS[$i]}" "${PAYOUT_AMOUNTS[$i]}" "$NEXT_SEQUENCE"
  NEXT_SEQUENCE=$((NEXT_SEQUENCE + 1))
done

echo
echo "[INFO] ALL PAYOUTS INCLUDED SUCCESSFULLY"