# range: last 300 blocks (adjust as you like)
RPC=http://localhost:26657
MYHEXU=$(curl -s $RPC/status | jq -r '.result.validator_info.address' | tr '[:lower:]' '[:upper:]')
END=$(curl -s $RPC/status | jq -r .result.sync_info.latest_block_height)
START=$((END-200))

echo "Scanning $START..$END for your commits…"
for h in $(seq $START $END); do
  flag=$(curl -s "$RPC/commit?height=$h" \
    | jq -r --arg MY "$MYHEXU" '
        .result.signed_header.commit.signatures
        | map(select((.validator_address | ascii_upcase)==$MY))[0].block_id_flag // "NA"')
  case "$flag" in
    2) : ;;                       # COMMIT (good) - print nothing
    3) echo "$h  NIL" ;;          # voted NIL
    1) echo "$h  ABSENT" ;;       # missed
    *) echo "$h  NOT_IN_SET/NA" ;;# not in set or unknown
  esac
done
