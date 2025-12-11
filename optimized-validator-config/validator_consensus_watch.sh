#!/usr/bin/env bash
set -euo pipefail

# ================================
# Config (override via env if you want)
# ================================
LOCAL_RPC="${LOCAL_RPC:-http://localhost:26657}"   # where your validator talks
REMOTE_RPC="${REMOTE_RPC:-$LOCAL_RPC}"             # where to read blocks from (can be sentry)
POLL_INTERVAL="${POLL_INTERVAL:-1}"                # seconds between polls
WARN_DELAY="${WARN_DELAY:-4}"                      # seconds (yellow)
CRIT_DELAY="${CRIT_DELAY:-7}"                      # seconds (red)
MAX_MISSED_WARN="${MAX_MISSED_WARN:-1}"            # warn when >= this many in a row
MAX_MISSED_CRIT="${MAX_MISSED_CRIT:-3}"            # crit when >= this many in a row

# ================================
# Colors
# ================================
if command -v tput >/dev/null 2>&1; then
  RED=$(tput setaf 1 || true)
  YELLOW=$(tput setaf 3 || true)
  GREEN=$(tput setaf 2 || true)
  CYAN=$(tput setaf 6 || true)
  BOLD=$(tput bold || true)
  RESET=$(tput sgr0 || true)
else
  RED=""; YELLOW=""; GREEN=""; CYAN=""; BOLD=""; RESET=""
fi

# ================================
# Helper: convert RFC3339 -> ms since epoch
# ================================
to_ms() {
  # date -u -d works on Ubuntu
  date -u -d "$1" +%s%3N
}

now_ms() {
  date -u +%s%3N
}

# ================================
# Detect validator consensus address
# ================================
MY_ADDR="${MY_ADDR:-}"

if [[ -z "${MY_ADDR}" ]]; then
  echo "[INFO] Detecting validator consensus address from ${LOCAL_RPC}/status ..."
  MY_ADDR=$(curl -s "${LOCAL_RPC}/status" | jq -r '.result.validator_info.address // empty')
fi

if [[ -z "${MY_ADDR}" || "${MY_ADDR}" == "null" ]]; then
  echo "[ERROR] Could not detect validator_info.address from ${LOCAL_RPC}/status"
  echo "        Ensure this node is a validator, OR set MY_ADDR env var explicitly."
  exit 1
fi

echo "[INFO] Using validator consensus address: ${BOLD}${MY_ADDR}${RESET}"

# ================================
# Starting height (next block)
# ================================
LATEST=$(curl -s "${REMOTE_RPC}/status" | jq -r '.result.sync_info.latest_block_height // "0"')
if [[ "${LATEST}" == "null" || -z "${LATEST}" ]]; then
  echo "[ERROR] Could not get latest_block_height from ${REMOTE_RPC}/status"
  exit 1
fi

START_HEIGHT=$((LATEST + 1))
echo "[INFO] Starting live watch from height ${BOLD}${START_HEIGHT}${RESET} (future blocks only)"
echo

MISSED_STREAK=0

# ================================
# Main loop
# ================================
while true; do
  CURR_LATEST=$(curl -s "${REMOTE_RPC}/status" | jq -r '.result.sync_info.latest_block_height // "0"')
  if [[ "${CURR_LATEST}" == "null" || -z "${CURR_LATEST}" ]]; then
    sleep "${POLL_INTERVAL}"
    continue
  fi

  while [[ "${START_HEIGHT}" -le "${CURR_LATEST}" ]]; do
    H="${START_HEIGHT}"

    BLOCK_JSON=$(curl -s "${REMOTE_RPC}/block?height=${H}")
    if [[ -z "${BLOCK_JSON}" ]]; then
      echo "[WARN] Could not fetch block at height ${H}"
      break
    fi

    HEADER_TIME=$(jq -r '.result.block.header.time' <<<"${BLOCK_JSON}")
    PROPOSER=$(jq -r '.result.block.header.proposer_address' <<<"${BLOCK_JSON}")

    # commit + signatures
    COMMIT_JSON=$(curl -s "${REMOTE_RPC}/commit?height=${H}")
    if [[ -z "${COMMIT_JSON}" ]]; then
      echo "[WARN] Could not fetch commit at height ${H}"
      break
    fi

    # signatures present in commit (those with a validator_address)
    SIG_ADDRESSES=$(jq -r '.result.signed_header.commit.signatures[] 
      | select(.validator_address != null) 
      | .validator_address' <<<"${COMMIT_JSON}" || true)

    SIG_COUNT=$(wc -w <<<"${SIG_ADDRESSES}" | tr -d ' ')
    if [[ -z "${SIG_COUNT}" ]]; then SIG_COUNT=0; fi

    # optional: count validators for this height (for %)
    VAL_JSON=$(curl -s "${REMOTE_RPC}/validators?height=${H}&per_page=300" || echo "")
    VAL_COUNT=$(jq -r '.result.validators | length' <<<"${VAL_JSON}" 2>/dev/null || echo "0")

    # did WE sign?
    SIGNED="no"
    if grep -q "${MY_ADDR}" <<<"${SIG_ADDRESSES}"; then
      SIGNED="yes"
    fi

    # compute delay (now - header_time)
    NOW_MS=$(now_ms)
    HEADER_MS=$(to_ms "${HEADER_TIME}")
    DELTA_MS=$((NOW_MS - HEADER_MS))
    DELTA_SEC=$(awk "BEGIN { printf \"%.2f\", ${DELTA_MS}/1000 }")

    # classify delay severity
    SEVERITY=""
    COLOR_DELAY="${GREEN}"
    if (( $(awk 'BEGIN { print ('"${DELTA_SEC}"' > '"${CRIT_DELAY}"') }') )); then
      SEVERITY="CRIT"
      COLOR_DELAY="${RED}"
    elif (( $(awk 'BEGIN { print ('"${DELTA_SEC}"' > '"${WARN_DELAY}"') }') )); then
      SEVERITY="WARN"
      COLOR_DELAY="${YELLOW}"
    fi

    # track missed streak
    if [[ "${SIGNED}" == "yes" ]]; then
      MISSED_STREAK=0
    else
      MISSED_STREAK=$((MISSED_STREAK + 1))
    fi

    # percent of validators that signed (rough proxy for +2/3)
    PCT="?"
    if [[ "${VAL_COUNT}" -gt 0 ]]; then
      PCT=$(awk "BEGIN { printf \"%.1f\", (${SIG_COUNT}*100)/${VAL_COUNT} }")
    fi

    # ================================
    # Output line
    # ================================
    NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    SIGN_COLOR="${RED}"
    [[ "${SIGNED}" == "yes" ]] && SIGN_COLOR="${GREEN}"

    echo "${NOW_ISO} height=${BOLD}${H}${RESET} proposer=${PROPOSER} "\
"signed=${SIGN_COLOR}${SIGNED}${RESET} delay=${COLOR_DELAY}${DELTA_SEC}s${RESET} "\
"sigs=${SIG_COUNT}/${VAL_COUNT} (~${PCT}%)"

    # ================================
    # Alerts
    # ================================
    if [[ "${SIGNED}" == "no" ]]; then
      if (( MISSED_STREAK >= MAX_MISSED_CRIT )); then
        echo "  ${RED}!!! CRIT: missed ${MISSED_STREAK} blocks in a row !!!${RESET}"
      elif (( MISSED_STREAK >= MAX_MISSED_WARN )); then
        echo "  ${YELLOW}!! WARN: missed ${MISSED_STREAK} block(s) in a row !!${RESET}"
      else
        echo "  ${YELLOW}Note: missed vote at height ${H}${RESET}"
      fi
    fi

    if [[ "${SEVERITY}" == "CRIT" ]]; then
      echo "  ${RED}!!! CRIT: high delay ${DELTA_SEC}s (>${CRIT_DELAY}s threshold) !!!${RESET}"
    elif [[ "${SEVERITY}" == "WARN" ]]; then
      echo "  ${YELLOW}!! WARN: delay ${DELTA_SEC}s (>${WARN_DELAY}s threshold) !!${RESET}"
    fi

    echo

    START_HEIGHT=$((START_HEIGHT + 1))
  done

  sleep "${POLL_INTERVAL}"
done
