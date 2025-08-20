# 1) Live peer count + list
curl -s 127.0.0.1:26657/net_info | jq -r .result.n_peers
curl -s 127.0.0.1:26657/net_info \
  | jq -r '.result.peers[] | "\(.node_info.id) \(.remote_ip) \(.node_info.moniker)"'

# 2) Confirm outbound-only & discovery
grep -E "max_num_outbound_peers|max_num_inbound_peers|pex|seed_mode" /mnt/nvme/qubetics/config/config.toml

# 3) Confirm your sticky peers are set
grep -E "persistent_peers|unconditional_peer_ids" /mnt/nvme/qubetics/config/config.toml
