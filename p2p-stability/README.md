### p2p_health.sh

Checks current p2p health

### peer_scan.sh

FInd the top 10 peers, and analyzes them for persistent peer reccomendations

### harvest_persistent_peers.sh

Samples a 10 minute window to see the top 10 most active peers for helping configure persinstent peer settings in config.toml

## p2p_churn.sh

```INTERVAL_SEC=5 SUMMARY_SEC=30 ./p2p_churn.sh```

Live samples appended to: /tmp/netstab.csv (epoch, ts, outbound, new, lost, timeout_prevote, timeout_precommit, gw_rtt_ms, gw_loss_pct, window_sec)

A rolling summary printed every SUMMARY_SEC and appended to: /tmp/netstab_summary.csv.

Summary TL:DR will include:

* Peer stability → how many peers you usually keep, and whether they’re flapping.
* Churn → how frequently peers connect/disconnect.
* Consensus timeouts (optional) → if the node is struggling with prevotes/precommits.
* Network quality → how stable/fast your gateway latency is.