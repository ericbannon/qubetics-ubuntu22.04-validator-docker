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

#### Consensus
```
[consensus]
timeout_propose     = "2s"
timeout_prevote     = "1s"
timeout_precommit   = "1s"
timeout_commit      = "1s"
skip_timeout_commit = false
```

* Faster consensus steps
* Keeps validator responsive when blocks are slow to propose

#### Mempool
```
[mempool]
size          = 2000
cache_size    = 50000
max_tx_bytes  = 524288        # 512 KiB
max_txs_bytes = 268435456     # 256 MiB
recheck       = false
```

* Caps gossip to reduce CPU spikes during spam floods
* Keeps enough headroom for valid txs without overwhelming RAM

#### TX Indexer
```
[tx-index]
indexer = "null"
```
* Disables tx indexing → lighter disk I/O at commit
* Use kv only if you need q tx <hash> or explorer queries

#### P2P
```
pex = true
```

* Still discover peers if persistent peers drop
* Outbound peers capped to 20–30 for stability
* Inbound peers optional (disable if running with sentries)

### `app.toml` (Application Layer)

This configuration file controls the **application-level settings** of the Qubetics validator, including pruning, mempool limits, API exposure, and minimum gas prices.  

It is tuned for the **Lean Profile**, optimized for block signing stability under heavy network load.

### Key Settings

⚠️ **Disclaimer**

This app.toml profile is optimized for validators that only need to sign blocks reliably.
It trades off query functionality and historical data retention.
Use it only if validator performance is your priority.

#### Mempool
```
[mempool]
max-txs = 2000
```

* Caps the app-side mempool at 2000 transactions
* Prevents unbounded growth inside the Cosmos SDK layer
* Matches the consensus mempool limit for consistency

#### Pruning

```
[pruning]
pruning             = "custom"
pruning-keep-recent = "100"
pruning-keep-every  = "0"
pruning-interval    = "10"
```

* Keeps only the last 100 states
* Prunes aggressively every 10 blocks
* Minimizes disk growth on NVMe storage
* Best for validators only (not archival or analytics nodes)

#### API & gRPC
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

#### Minimum Gas Price

```
minimum-gas-prices = "0.025tics"
```

* Rejects 0-fee spam transactions from entering the mempool
* Ensures validator resources aren’t wasted processing junk txs