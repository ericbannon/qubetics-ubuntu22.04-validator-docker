RPC=127.0.0.1:26657
VALHEX=$(curl -s http://$RPC/status | jq -r '.result.validator_info.address' | tr a-z A-Z)
L=$(curl -s http://$RPC/status | jq -r '.result.sync_info.latest_block_height'); N=200; MIS=0
for h in $(seq $L -1 $((L-N+1))); do
  got=$(curl -s "http://$RPC/commit?height=$h" | jq -r --arg V "$VALHEX" \
       '[.result.signed_header.commit.signatures[]?|select(.validator_address==$V)]|length')
  [ "$got" = 0 ] && MIS=$((MIS+1))
done
echo "Signed: $((N-MIS)) / $N  |  Missed: $MIS"
