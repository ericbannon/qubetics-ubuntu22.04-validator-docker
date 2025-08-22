# ⚡ Qubetics Validator – Optimized Config (Lean Profile)

This profile is tuned for **validators that prioritize block signing** under high network load (e.g. the daily 07:19 UTC airdrop floods).  

**Why this helps:**

* ⏱️ Reduced Consensus Lag → tighter timeouts prevent long stalls
* 💾 Less Disk I/O → pruning + no tx indexer = smoother commits
* 🌐 Stable Networking → outbound peer cap avoids churn storms
* 🛡️ Resilient to Floods → validator spends CPU on signing, not relaying spam

**NOTE:**

This Lean profile is recommended for production validators. Explorers, RPC nodes, and analytics nodes should not use this profile (they require tx indexing + longer state retention)
---

## 🔧 Config Overview

The **Lean profile** is focused on validator reliability.  
It makes the following changes to `config.toml` and `app.toml`:

### `config.toml` (Consensus / P2P / RPC)

#### Summary of Enhancements

##### P2P
* max_num_inbound_peers = 24, max_num_outbound_peers = 12, max_num_peers = 36
* send_rate/recv_rate = 10 MiB/s
* peer_gossip_sleep_duration = "80ms", peer_query_maj23_sleep_duration = "1.5s"
* max_packet_msg_payload_size = 1024
* handshake_timeout = "10s", dial_timeout = "3s", persistent_peers_max_dial_period = "20s"
* flush_throttle_timeout = "25ms", allow_duplicate_ip = true

1. Keeps you well‑connected on a ~40‑peer net but avoids excessive per‑peer goroutine load.
2. Less chatty than 10ms, still responsive; reduces wakeups on a small core budget.
3. Avoids giant packets hogging a core on serialization.
4. Fail fast on flappers; churn keeps moving.
5. Smoother send buffering; helpful if several peers share NAT.


##### Consensus
* timeout_commit = "2s" (from 6s), with propose/pre‑vote/pre‑commit tuned for steady cadence
* create_empty_blocks = false

1. Cuts useless consensus churn between bursts.
2. This raises TPS without pushing too hard on cores used

##### RPC
* rpc.max_open_connections = 1024

1. Limits FD overcommit.

##### Mempool
* version stays = "v0" for raw throughput
* size = 10000, cache_size = 16000
* max_txs_bytes = 512 MiB (balanced for memory on a small box)
* ttl-num = 0, ttl-duration = "0s"

### `app.toml` (Application Layer)

This configuration file controls the **application-level settings** of the Qubetics validator, including pruning, mempool limits, API exposure, and minimum gas prices.  

It is tuned for the **Lean Profile**, optimized for block signing stability under heavy network load.

#### Summary of Enhancements

⚠️ **Disclaimer**

This app.toml profile is optimized for validators that only need to sign blocks reliably.
It trades off query functionality and historical data retention.
Use it only if validator performance is your priority.

##### Mempool
```
[mempool]
max-txs = 2000
```

* Caps the app-side mempool at 2000 transactions
* Prevents unbounded growth inside the Cosmos SDK layer
* Matches the consensus mempool limit for consistency


##### Pruning

pruning = "custom", pruning-keep-recent = "2000", pruning-keep-every = "0", pruning-interval = "50"

* Pruning tightened to keep on‑disk churn sane:

##### API & gRPC
```
[api]
swagger = false

[grpc-web]
enable = false

[grpc]
# Enable defines if the gRPC server should be enabled.
enable = true
```

* Swagger disabled for lighter runtime footprint
* grpc.enable = true → lightweight, efficient local monitoring possible
* grpc-web.enable = false → reduces surface area, saves a bit of CPU, keeps validator lean

##### Minimum Gas Price

```
minimum-gas-prices = "0.025tics"
```

* Rejects 0-fee spam transactions from entering the mempool
* Ensures validator resources aren’t wasted processing junk txs

##### Snapshots

Snapshots off for pure performance runs: snapshot-interval = 0, snapshot-keep-recent = 2