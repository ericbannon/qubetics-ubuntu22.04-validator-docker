#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# distribute_commissions.sh (fail-fast version with bigint-safe math + CSV export)
# ----------------------------------------------------------------------------
# Redistribute a validator's commissions to delegators proportionally.
# Exits immediately on any error. Prints summary if all steps succeed.
# Optional: export payout plan to CSV via --export <file>.
# ----------------------------------------------------------------------------

set -Eeuo pipefail

# ---------- Defaults ----------
VALOPER="qubeticsvaloper18llj8eqh9k9mznylk8svrcc63ucf7y2r4xkd8l"
CHAIN_ID="qubetics_9030-1"
NODE="${NODE:-tcp://127.0.0.1:26657}"
DENOM="${DENOM:-tics}"
PERCENT="${PERCENT:-1.0}"
FEE_BUFFER="${FEE_BUFFER:-500000}"
MIN_PAYOUT="${MIN_PAYOUT:-1000}"
KEYRING="${KEYRING:-file}"
GAS="${GAS:-auto}"
GAS_ADJUSTMENT="${GAS_ADJUSTMENT:-1.2}"
DRY_RUN="${DRY_RUN:-true}"
FIXED_POOL="${FIXED_POOL:-}"
DOCKER_NAME="${DOCKER_NAME:-validator-node}"
EXCLUDE_FILE="${EXCLUDE_FILE:-}"
HOME_DIR="${HOME_DIR:-/mnt/nvme/qubetics}"
EXPORT_PATH=""   # set via --export <file>

WITHDRAW=false
USE_MULTISEND=false
ONLY_PLAN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --withdraw) WITHDRAW=true; shift ;;
    --use-multisend) USE_MULTISEND=true; shift ;;
    --no-dry-run) DRY_RUN=false; shift ;;
    --only-plan) ONLY_PLAN=true; shift ;;
    --export)
      if [[ $# -lt 2 ]]; then echo "--export requires a file path" >&2; exit 2; fi
      EXPORT_PATH="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

: "${FROM:?FROM (key name or address) is required}"

# ---------- Helpers ----------
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

run_q() {
  if [[ -n "$DOCKER_NAME" ]]; then
    # Use an interactive TTY for signing ops (tx/keys) so passphrase prompts work
    case "$1" in
      tx|keys)
        docker exec -it "$DOCKER_NAME" qubeticsd "$@"
        ;;
      *)
        docker exec -i "$DOCKER_NAME" qubeticsd "$@"
        ;;
    esac
  else
    qubeticsd "$@"
  fi
}

TXFLAGS=(--from "$FROM" --chain-id "$CHAIN_ID" --keyring-backend "$KEYRING" --home "$HOME_DIR" --yes --node "$NODE" --gas "$GAS" --gas-adjustment "$GAS_ADJUSTMENT")
QFLAGS=(--node "$NODE")
if [[ -n "${FEES:-}" ]]; then TXFLAGS+=(--fees "$FEES"); fi
if [[ -n "${GAS_PRICES:-}" ]]; then TXFLAGS+=(--gas-prices "$GAS_PRICES"); fi

FROM_ADDR="$FROM"
FROM_TX="$FROM"  # will be replaced with key name if FROM is an address
if [[ ! "$FROM" =~ ^qubetics1[0-9a-z]+$ ]]; then
  # FROM is a key name; resolve address
  FROM_ADDR=$(run_q keys show "$FROM" -a --keyring-backend "$KEYRING" --home "$HOME_DIR")
else
  # FROM looks like a bech32 address; find matching key name in keyring
  MATCH_NAME=$(run_q keys list --keyring-backend "$KEYRING" --home "$HOME_DIR" -o json | jq -r --arg addr "$FROM" '.[] | select(.address==$addr) | .name' | head -n1 || true)
  if [[ -n "$MATCH_NAME" && "$MATCH_NAME" != "null" ]]; then
    FROM_TX="$MATCH_NAME"
  else
    err "FROM is an address but no matching key in keyring (HOME=$HOME_DIR). Set FROM to your key name or set HOME_DIR correctly."
    exit 1
  fi
fi

# ---------- Withdraw commission ----------
if $WITHDRAW; then
  info "Withdrawing commission..."
  if [[ "$DRY_RUN" == true ]]; then
    # In dry-run, always echo the tx (even if --only-plan)
    echo qubeticsd tx distribution withdraw-rewards "$VALOPER" --commission "${TXFLAGS[@]}"
  else
    # When not dry-run, actually execute the withdraw even with --only-plan
    run_q tx distribution withdraw-rewards "$VALOPER" --commission --from "$FROM_TX" "${TXFLAGS[@]//--from "$FROM"/}"
  fi
fi

# ---------- Fetch delegators ----------
info "Fetching delegators..."
page=$(run_q query staking delegations-to "$VALOPER" --limit 1000 -o json "${QFLAGS[@]}")
DELEG_JSON=$(jq -c '.delegation_responses | map({addr: .delegation.delegator_address, amount: ((.balance.amount // "0")|tonumber)})' <<<"$page")
TOTAL_STAKE=$(jq -r '[.[] | .amount] | add // 0' <<<"$DELEG_JSON")
COUNT=$(jq -r 'length' <<<"$DELEG_JSON")
if [[ "$TOTAL_STAKE" -le 0 || "$COUNT" -eq 0 ]]; then
  err "No delegators or total stake is zero."
  exit 1
fi
info "Delegators: $COUNT | Total stake: $TOTAL_STAKE $DENOM"

# ---------- Get balance ----------
info "Querying spendable balance for $FROM_ADDR..."
SPENDABLE=$(run_q query bank balances "$FROM_ADDR" -o json "${QFLAGS[@]}" | jq -r --arg d "$DENOM" '[.balances[] | select(.denom==$d) | .amount|tonumber] | add // 0')

if [[ -n "$FIXED_POOL" ]]; then
  POOL="$FIXED_POOL"
else
  POOL=$(jq -nr --argjson bal "$SPENDABLE" --argjson pct "$PERCENT" --argjson buf "$FEE_BUFFER" '((( $bal * $pct ) | floor) - $buf) | if . < 0 then 0 else . end')
fi
# Use jq to evaluate > 0 to avoid bash integer limits on huge values
if ! jq -en --argjson x "$POOL" '$x > 0' >/dev/null; then
  err "Nothing to distribute. (POOL=$POOL; SPENDABLE=$SPENDABLE; FEE_BUFFER=$FEE_BUFFER; PERCENT=$PERCENT)"
  exit 1
fi
info "Spendable: $SPENDABLE $DENOM"
info "Distribution pool: $POOL $DENOM (spendable $SPENDABLE)"

# ---------- Build plan ----------
PLAN=$(jq -c --argjson pool "$POOL" --argjson total "$TOTAL_STAKE" --arg min "$MIN_PAYOUT" '
  [ .[] | {addr, payout: ((( $pool * (.amount) ) / $total) | floor) } ]
  | map(select(.payout >= ($min|tonumber)))
' <<<"$DELEG_JSON")

N_PAY=$(jq -r 'length' <<<"$PLAN")
SUM_PAY=$(jq -r '[.[] | .payout] | add // 0' <<<"$PLAN")
LEFTOVER=$(jq -nr --argjson pool "$POOL" --argjson sum "$SUM_PAY" '$pool - $sum')

info "Eligible payouts: $N_PAY | Sum: $SUM_PAY $DENOM | Leftover: $LEFTOVER $DENOM"

# ---------- Optional CSV export ----------
if [[ -n "$EXPORT_PATH" ]]; then
  info "Exporting plan to $EXPORT_PATH ..."
  {
    echo "delegator,amount_${DENOM}"
    jq -r '.[] | "\(.addr),\(.payout)"' <<<"$PLAN"
    echo "TOTAL,$SUM_PAY"
  } > "$EXPORT_PATH"
fi

# ---------- Pretty print plan ----------
printf "\n%-48s %20s\n" "Delegator" "Amount ($DENOM)"
printf "%-48s %20s\n" "-----------------------------------------------" "--------------------"
jq -r '.[] | "\(.addr) \(.payout)"' <<<"$PLAN" | while read -r addr amt; do
  printf "%-48s %20s\n" "$addr" "$amt"
done
printf "%-48s %20s\n\n" "TOTAL" "$SUM_PAY"

if $ONLY_PLAN; then
  info "Plan only. Exiting."
  exit 0
fi

# ---------- Broadcast (if not dry run) ----------
if [[ "$DRY_RUN" == true ]]; then
  info "Dry run mode — no transactions broadcast."
  exit 0
fi

info "Broadcasting transfers..."
i=0
jq -r '.[] | "\(.addr) \(.payout)"' <<<"$PLAN" | while read -r addr amt; do
  ((i++))
  info "[$i/$N_PAY] Sending ${amt}${DENOM} -> $addr"
  run_q tx bank send "$FROM_TX" "$addr" "${amt}${DENOM}" "${TXFLAGS[@]}"

done

info "Done. Distributed $SUM_PAY $DENOM across $N_PAY delegators. Leftover: $LEFTOVER $DENOM"
