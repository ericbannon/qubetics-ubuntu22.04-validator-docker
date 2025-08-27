# ⚡ Qubetics Validator – Optimized Config (Lean Profile)

This document consolidates the **optimized settings** for running a Qubetics validator or full node.  
It covers both **`app.toml`** (application layer) and **`config.toml`** (consensus & networking) with explanations for performance, stability, and security.

# `config.toml` (Consensus / P2P / RPC)

---

## 🏗️ Core Settings

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `proxy_app` | `tcp://0.0.0.0:26658` | ABCI app connection (Cosmos SDK). |
| `moniker` | `bannon-validator-x8` | Node identifier. |
| `block_sync` | `true` | Enable fast block sync. |
| `db_backend` | `goleveldb` | Efficient embedded DB backend. |
| `db_dir` | `data` | Database storage directory. |
| `log_level` | `info` | Standard logging level. |
| `log_format` | `plain` | Simpler log formatting. |

---

## 🌐 RPC Server

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `laddr` | `tcp://127.0.0.1:26657` | RPC only exposed locally for security. |
| `cors_allowed_origins` | `['*']` | Wide CORS (disable/lock down if public). |
| `grpc_max_open_connections` | `900` | High concurrent connection support. |
| `max_open_connections` | `1024` | Protects against resource exhaustion. |
| `experimental_close_on_slow_client` | `true` | Drops slow clients to protect performance. |
| `timeout_broadcast_tx_commit` | `10s` | Standard transaction commit timeout. |
| `pprof_laddr` | `127.0.0.1:6060` | Local profiling endpoint. |

---

## 🔗 P2P Network

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `laddr` | `tcp://0.0.0.0:26656` | Public P2P listener. |
| `external_address` | `tcp://73.3.165.55:26656` | Node’s advertised external IP. |
| `persistent_peers` | `65cb0de4…; f874aca4…; 41f8e8b5…; ad8e2053…` | Stable peers for connectivity. |
| `addr_book_strict` | `false` | Allows looser peer validation. |
| `max_num_inbound_peers` | `24` | Balance inbound peer load. |
| `max_num_outbound_peers` | `12` | Limit outbound dial attempts. |
| `unconditional_peer_ids` | `65cb0de4…, f874aca4…` | Always connect to these peers. |
| `persistent_peers_max_dial_period` | `20s` | Faster retries on persistent peers. |
| `send_rate` / `recv_rate` | `10 MB/s` | Bandwidth caps per peer. |
| `pex` | `true` | Enable peer exchange. |
| `allow_duplicate_ip` | `true` | Allow multiple peers from same IP (useful for testnets). |

---

## 🧮 Mempool

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `version` | `v0` | Legacy, stable mempool. |
| `type` | `flood` | Broadcast style mempool. |
| `recheck` | `false` | Skip rechecks for efficiency. |
| `size` | `2000` | Max txs in mempool. |
| `max_txs_bytes` | `256MB` | Cap on total mempool size. |
| `cache_size` | `50000` | Large cache for fast tx lookup. |
| `max_tx_bytes` | `512KB` | Per-transaction limit. |
| `experimental_max_gossip_connections_to_persistent_peers` | `6` | Extra gossip scaling. |
| `experimental_max_gossip_connections_to_non_persistent_peers` | `10` | Wider gossip fan-out. |

---

## ⏱️ Consensus

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `timeout_propose` | `2s` | Time to propose a block. |
| `timeout_prevote` | `1s` | Time for prevote step. |
| `timeout_precommit` | `1s` | Time for precommit step. |
| `timeout_commit` | `6s` | Time for commit step. |
| `create_empty_blocks` | `false` | Do not create empty blocks. |
| `peer_gossip_sleep_duration` | `10ms` | Fast consensus gossiping. |

---

## 📦 State Sync & Block Sync

- **State Sync** → disabled (manual snapshots preferred).  
- **Block Sync** → enabled (`v0`).  

---

## 🗄️ Storage

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `discard_abci_responses` | `true` | Saves disk by discarding ABCI responses. |

---

## 🔍 Indexing

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `tx_index.indexer` | `null` | Disables tx indexing (saves disk/CPU). |

---

## 📊 Instrumentation

| Parameter | Value |
|-----------|-------|
| `prometheus` | `true` |
| `prometheus_listen_addr` | `127.0.0.1:26660` |
| `namespace` | `cometbft` |

Exposed only on localhost for safety.  


# `app.toml` (Application Layer)

This configuration file controls the **application-level settings** of the Qubetics validator, including pruning, mempool limits, API exposure, and minimum gas prices.  

It is tuned for the **Lean Profile**, optimized for block signing stability under heavy network load.

---

## ⚡ Application Settings (`app.toml`)

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `minimum-gas-prices` | `0.025tics` | Prevents spam by requiring a base fee. |
| `pruning` | `custom` | Custom pruning for optimal disk usage. |
| `pruning-keep-recent` | `2000` | Retain last 2000 blocks for queries. |
| `pruning-keep-every` | `0` | Do not keep older historical states. |
| `pruning-interval` | `50` | Run pruning every 50 blocks. |
| `halt-height` / `halt-time` | `0` | No forced halts. |
| `min-retain-blocks` | `0` | Allow default Tendermint retention. |
| `inter-block-cache` | `true` | Speeds up intra-block processing. |
| `iavl-cache-size` | `781250` | Larger IAVL cache for better performance. |
| `iavl-disable-fastnode` | `false` | Keep fastnode indexing enabled. |
| `iavl-lazy-loading` | `false` | Ensure full state is always loaded. |
| `indexer` | `null` | Disables tx/block event indexer to save disk/IO. |
| `snapshot-interval` | `0` | No snapshots created. |
| `snapshot-keep-recent` | `2` | Keep only 2 recent snapshots if enabled. |

---

# app.toml summary of optimizations

## 📊 Telemetry
- Telemetry completely **disabled** (Prometheus/Grafana can be enabled if needed).  

## 🌐 API
- REST API & Swagger **disabled** for security.  
- If enabled: bound to `1317`, supports up to 1000 connections, but uses **unsafe CORS** (not safe for public).  

## 🧩 Rosetta
- **Disabled** (for exchanges/explorers).  
- If enabled, update `denom-to-suggest` from `uatom` → `tics`.  

## 🛰️ gRPC
- **Enabled** at `0.0.0.0:9090` (wallets/relayers use this).  
- gRPC-Web **disabled**.  

## 🔗 State Sync
- State sync **snapshots disabled**.  

## 🗄️ Store & Streamers
- **No active streamers**.  
- File streamer is defined but inactive.  

## 🧮 Mempool
- Large mempool: up to **10k txs / 512 MB**.  
- Stable `v0` mempool version.  
- No TTLs: txs remain until included.  

## ⚙️ EVM
- Tracer off.  
- No gas cap (`max-tx-gas-wanted=0`).  

## 🔌 JSON-RPC
- **Disabled**.  
- If enabled: eth, net, web3 modules; gas cap 25M; metrics exposed at `:6065`.  
- Security: unprotected txs + insecure unlock **disabled**.  

## 🔒 TLS
- Not configured (TLS should be handled by reverse proxy like Caddy/Nginx).  

## 🧠 MemIAVL
- **Disabled**.  
- Falls back to stable disk-backed IAVL.  
