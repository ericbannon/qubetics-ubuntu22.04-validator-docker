RPC=127.0.0.1:26657
VALHEX=$(curl -s http://$RPC/status | jq -r '.result.validator_info.address' | tr a-z A-Z)

# how many blocks to check
N=200

# latest height
L=$(curl -s http://$RPC/status | jq -r '.result.sync_info.latest_block_height')

# start height (don’t go below 1)
START=$(( L - N + 1 ))
[ "$START" -lt 1 ] && START=1

MIS=0
for h in $(seq "$L" -1 "$START"); do
  got=$(curl -s "http://$RPC/commit?height=$h" | jq -r --arg V "$VALHEX" \
       '[.result.signed_header.commit.signatures[]?|select(.validator_address==$V)]|length')
        [ "$got" -gt 0 ] && echo "$h ✅ signed" || echo "$h ❌ missed"

done

TOTAL=$((L - START + 1))
SIGNED=$((TOTAL - MIS))
PCT=$(awk "BEGIN { if ($TOTAL>0) printf \"%.2f\", ($SIGNED/$TOTAL)*100; else print 0 }")

echo "Checked last $TOTAL blocks (heights $START..$L)"
echo "Signed: $SIGNED / $TOTAL  (${PCT}%)  |  Missed: $MIS"