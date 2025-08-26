#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# distribute_commissions.sh (container, file-keyring, prompt-safe)
# ----------------------------------------------------------------------------
# - Queries use `docker exec -i` (no TTY) for clean JSON
# - Signing ops (tx/keys) use `docker exec -it` so passphrase prompts appear
# - KEYRING=file and HOME_DIR=/mnt/nvme/qubetics (change below if needed)
# - Withdraw runs before planning if --withdraw is set (no --yes)
# - In --only-plan, if FROM is an address (or FROM_ADDR is set), we skip keyring prompts
# - Proportional payouts; optional --export CSV
# ----------------------------------------------------------------------------

set -Eeuo pipefail

# ---------- Chain & environment ----------
VALOPER="qubeticsvaloper18llj8eqh9k9mznylk8svrcc63ucf7y2r4xkd8l"
CHAIN_ID="qubetics_9030-1"
NODE="${NODE:-tcp://127.0.0.1:26657}"
DENOM="${DENOM:-tics}"

DOCKER_NAME="${DOCKER_NAME:-validator-node}"
KEYRING="file"
HOME_DIR="${HOME_DIR:-/mnt/nvme/qubetics}"

# Distribution config
PERCENT="${PERCENT:-1.0}"            # 1.0 = 100% of balance (minus buffer) or set FIXED_POOL
FEE_BUFFER="${FEE_BUFFER:-500000}"   # keep this many tics for fees
MIN_PAYOUT="${MIN_PAYOUT:-1000}"     # drop dust payouts below this amount
GAS="${GAS:-auto}"
GAS_ADJUSTMENT="${GAS_ADJUSTMENT:-1.2}"
DRY_RUN="${DRY_RUN:-true}"
FIXED_POOL="${FIXED_POOL:-}"
EXPORT_PATH=""

WITHDRAW=false
ONLY_PLAN=false

# ---------- Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --withdraw) WITHDRAW=true; shift ;;
    --only-plan) ONLY_PLAN=true; shift ;;
    --export) EXPORT_PATH="${2:?--export needs a file path}"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

: "${FROM:?FROM must be your key name or bech32 address (e.g. FROM=main-wallet or FROM=qubetics1...)}"

# ---------- Helpers ----------
info(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }
err(){  echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

# Queries: no TTY
q()  { docker exec -i  "$DOCKER_NAME" qubeticsd "$@"; }
# Tx/keys: interactive TTY for passphrase prompt
qd() { docker exec -it "$DOCKER_NAME" qubeticsd "$@"; }

TXFLAGS_BASE=(--chain-id "$CHAIN_ID" --keyring-backend "$KEYRING" --home "$HOME_DIR" --node "$NODE" --gas "$GAS" --gas-adjustment "$GAS_ADJUSTMENT")
QFLAGS=(--node "$NODE")

# ---------- (1) Withdraw commission (if requested) ----------
if $WITHDRAW; then
  info "Withdrawing commission (will prompt for passphrase)..."
  if [[ "$DRY_RUN" == true ]]; then
    echo qubeticsd tx distribution withdraw-rewards "$VALOPER" --commission --from "$FROM" "${TXFLAGS_BASE[@]}"
  else
    qd tx distribution withdraw-rewards "$VALOPER" \
      --commission \
      --from "$FROM" \
      "${TXFLAGS_BASE[@]}"
  fi
fi

# ---------- (2) Fetch delegators ----------
info "Fetching delegators..."
page=$(q query staking delegations-to "$VALOPER" --limit 1000 -o json "${QFLAGS[@]}")
DELEG_JSON=$(jq -c '.delegation_responses
  | map({addr: .delegation.delegator_address, amount: ((.balance.amount // "0")|tonumber)})' <<<"$page")

TOTAL_STAKE=$(jq -r '[.[] | .amount] | add // 0' <<<"$DELEG_JSON")
COUNT=$(jq -r 'length' <<<"$DELEG_JSON")
if [[ "$TOTAL_STAKE" -le 0 || "$COUNT" -eq 0 ]]; then
  err "No delegators or total stake is zero."
  exit 1
fi
info "Delegators: $COUNT | Total stake: $TOTAL_STAKE $DENOM"

# ---------- (3) Resolve FROM / FROM_ADDR robustly ----------
# Allow the caller to provide FROM_ADDR to skip any keyring access
FROM_TX="$FROM"
if [[ -n "${FROM_ADDR:-}" ]]; then
  info "Using provided FROM_ADDR: $FROM_ADDR"
else
  if [[ "$ONLY_PLAN" == true && "$FROM" =~ ^qubetics1[0-9a-z]+$ ]]; then
    # Plan-only + FROM is an address: skip keyring ops entirely
    FROM_ADDR="$FROM"
  else
    if [[ "$FROM" =~ ^qubetics1[0-9a-z]+$ ]]; then
      # FROM is an address: try to map to key name (optional for sending later)
      FROM_ADDR="$FROM"
      # keys list may or may not prompt; we only need this name when sending
      MATCH_NAME=$(q keys list --keyring-backend "$KEYRING" --home "$HOME_DIR" -o json | jq -r --arg addr "$FROM" '.[] | select(.address==$addr) | .name' | head -n1 || true)
      [[ -n "$MATCH_NAME" && "$MATCH_NAME" != "null" ]] && FROM_TX="$MATCH_NAME"
    else
      # FROM is a key name: resolve address (will prompt)
      info "Resolving address for key: $FROM ..."
      FROM_ADDR=$(qd keys show "$FROM" -a --keyring-backend "$KEYRING" --home "$HOME_DIR")
    fi
  fi
fi
info "FROM address: $FROM_ADDR"

# ---------- (4) Balance and pool ----------
info "Querying spendable balance for $FROM_ADDR ..."
SPENDABLE=$(q query bank balances "$FROM_ADDR" -o json "${QFLAGS[@]}" \
  | jq -r --arg d "$DENOM" '[.balances[] | select(.denom==$d) | .amount|tonumber] | add // 0')

if [[ -n "$FIXED_POOL" ]]; then
  POOL="$FIXED_POOL"
else
  POOL=$(jq -nr --argjson bal "$SPENDABLE" --argjson pct "$PERCENT" --argjson buf "$FEE_BUFFER" \
    '((( $bal * $pct ) | floor) - $buf) | if . < 0 then 0 else . end')
fi
if ! jq -en --argjson x "$POOL" '$x > 0' >/dev/null; then
  err "Nothing to distribute. (POOL=$POOL; SPENDABLE=$SPENDABLE; FEE_BUFFER=$FEE_BUFFER; PERCENT=$PERCENT)"
  exit 1
fi
info "Spendable: $SPENDABLE $DENOM"
info "Distribution pool: $POOL $DENOM (spendable $SPENDABLE)"

# ---------- (5) Build plan ----------
PLAN=$(jq -c --argjson pool "$POOL" --argjson total "$TOTAL_STAKE" --arg min "$MIN_PAYOUT" '
  [ .[] | {addr, payout: ((( $pool * (.amount) ) / $total) | floor) } ]
  | map(select(.payout >= ($min|tonumber)))
' <<<"$DELEG_JSON")

N_PAY=$(jq -r 'length' <<<"$PLAN")
SUM_PAY=$(jq -r '[.[] | .payout] | add // 0' <<<"$PLAN")
LEFTOVER=$(jq -nr --argjson pool "$POOL" --argjson sum "$SUM_PAY" '$pool - $sum')

info "Eligible payouts: $N_PAY | Sum: $SUM_PAY $DENOM | Leftover: $LEFTOVER $DENOM"

# Optional CSV
if [[ -n "$EXPORT_PATH" ]]; then
  info "Exporting plan to $EXPORT_PATH ..."
  {
    echo "delegator,amount_${DENOM}"
    jq -r '.[] | "\( .addr),\( .payout)"' <<<"$PLAN"
    echo "TOTAL,$SUM_PAY"
  } > "$EXPORT_PATH"
fi

# Print table
printf "\n%-48s %20s\n" "Delegator" "Amount ($DENOM)"
printf "%-48s %20s\n" "-----------------------------------------------" "--------------------"
jq -r '.[] | "\( .addr) \( .payout)"' <<<"$PLAN" | while read -r addr amt; do
  printf "%-48s %20s\n" "$addr" "$amt"
done
printf "%-48s %20s\n\n" "TOTAL" "$SUM_PAY"

if $ONLY_PLAN; then
  info "Plan only. Exiting."
  exit 0
fi

# ---------- (6) Broadcast sends ----------
if [[ "$DRY_RUN" == true ]]; then
  info "Dry run mode — no transactions broadcast."
  exit 0
fi

# For sends, --from must refer to a key in the keyring. If FROM is an address and we
# couldn't map it to a key name earlier, warn clearly.
if [[ "$FROM_TX" =~ ^qubetics1[0-9a-z]+$ ]]; then
  err "--from looks like an address; please set FROM to your key name (e.g. FROM=main-wallet) for sending."
  exit 1
fi

info "Broadcasting transfers (will prompt for passphrase as needed)..."
i=0
jq -r '.[] | "\( .addr) \( .payout)"' <<<"$PLAN" | while read -r addr amt; do
  ((i++))
  info "[$i/$N_PAY] Sending ${amt}${DENOM} -> $addr"
  qd tx bank send "$FROM_TX" "$addr" "${amt}${DENOM}" "${TXFLAGS_BASE[@]}"
done

info "Done. Distributed $SUM_PAY $DENOM across $N_PAY delegators. Leftover: $LEFTOVER $DENOM"