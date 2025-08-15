#!/bin/bash
set -euo pipefail
RPC="http://127.0.0.1:26657"

echo "=== P2P Health Report ==="
date
echo

# Pull once to avoid multiple RPC calls
JSON=$(curl -s "$RPC/net_info")

# 1) Totals + inbound/outbound (handles multiple schemas)
echo "$JSON" | jq '
  # Normalize peers to objects (some nodes return JSON strings)
  (.result.peers // []) as $raw
  | ($raw | map( if type=="string" then (try fromjson catch {}) else . end )) as $peers
  | ($peers | length) as $t
  # Outbound if any of these flags are true
  | ($peers
     | map(
         ( .is_outbound // false )
         or ( .connection_status.Outbound // false )
         or ( .connection_status.outbound // false )
         or ( .Outbound // false )
       )
     | map(select(.==true)) | length) as $out
  | {total:$t, outbound:$out, inbound:($t - $out)}
'
echo

# 2) Top 10 peers by average receive rate (graceful if fields missing)
echo "Top 10 peers by gossip receive rate (bytes/sec):"
echo "$JSON" | jq -r '
  (.result.peers // []) 
  | map( if type=="string" then (try fromjson catch {}) else . end )
  | map({
      id: (.node_info.id // .NodeInfo.id // "unknown"),
      recv_rate: (.connection_status.RecvMonitor.AvgRate // 0)
    })
  | sort_by(.recv_rate) | reverse
  | .[:10]
  | map("\(.id)\t\(.recv_rate)") | .[]
'
echo

# 3) Inactive peers (either Recv or Send marked inactive)
echo "Inactive peers (Recv or Send inactive):"
echo "$JSON" | jq -r '
  (.result.peers // [])
  | map( if type=="string" then (try fromjson catch {}) else . end )
  | map({
      id: (.node_info.id // .NodeInfo.id // "unknown"),
      recv_active: (.connection_status.RecvMonitor.Active // true),
      send_active: (.connection_status.SendMonitor.Active // true)
    })
  | map(select(.recv_active==false or .send_active==false))
  | if length==0 then "None" else .[] end
'
