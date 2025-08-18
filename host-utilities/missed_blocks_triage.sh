#!/usr/bin/env bash
# missed_blocks_triage.sh — run on the HOST; all qubeticsd calls use docker exec
set -euo pipefail

# === Adjust if needed ===
CNT="${CNT:-validator-node}"                          # container name
RPC="${RPC:-http://127.0.0.1:26657}"                  # local RPC
VALOPER="${VALOPER:-qubeticsvaloper18llj8eqh9k9mznylk8svrcc63ucf7y2r4xkd8l}"
HIN="${HIN:-/mnt/nvme/qubetics}"                      # DAEMON HOME **inside the container**
# ========================

echo "== Sync/Height/Lag =="
curl -s "$RPC/status" | jq -r '
  .result.sync_info as s |
  "height=\(s.latest_block_height) catching_up=\(s.catching_up) lag_s=\((now - (s.latest_block_time|fromdateiso8601))|floor)"'

echo; echo "== Peers =="
curl -s "$RPC/net_info" | jq -r '.result.n_peers'

echo; echo "== Validator set membership (are you in the set?) =="
VALCONS="$(docker exec -i "$CNT" sh -lc "qubeticsd tendermint show-address --home \"$HIN\"")"
VALCONS="$(echo -n "$VALCONS" | tr -d '\r\n')"
echo "valcons=$VALCONS"

curl -s "$RPC/validators" | jq -r --arg v "$VALCONS" '
  .result.validators[] | select(.address==$v) | {address, voting_power}'

echo; echo "== Slashing / signing info (missed blocks in window) =="
docker exec -i "$CNT" sh -lc "qubeticsd q slashing signing-info \"$VALCONS\" --node \"$RPC\"" 2>/dev/null | sed -n '1,120p'

echo; echo "== Node health =="
curl -s "$RPC/health"; echo

echo; echo "== Time sync (offset should be small, e.g. |offset| < 100ms) =="
( chronyc tracking 2>/dev/null || timedatectl 2>/dev/null ) | sed -n '1,20p'
