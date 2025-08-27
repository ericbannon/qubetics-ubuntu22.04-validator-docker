# ⚡ Qubetics Validator – Optimized Config (Lean Profile)

This document consolidates the **optimized settings** for running a Qubetics validator or full node.  
It covers both **`app.toml`** (application layer) and **`config.toml`** (consensus & networking) with explanations for performance, stability, and security.

---

## 🛠 Validator Configuration (`config.toml`)

This is a sample configuration for running a **Qubetics validator node** (`bannon-validator-x8`).  
It’s tuned for reliability, open RPC access, and strong peer connectivity.  

### ⚙️ Why These Settings Are Optimized

This configuration balances **performance, security, and network reliability** for running a Qubetics validator:

- **Open RPC (0.0.0.0:26657)** → allows external monitoring and client queries, while still keeping TLS and reverse-proxy security optional.  
- **High connection limits (1024 RPC, 80 inbound / 40 outbound peers)** → ensures the node can handle heavy traffic and maintain strong connectivity.  
- **Flood mempool mode with 5,000 tx capacity** → prioritizes fast gossip and transaction propagation, preventing bottlenecks in high-throughput scenarios.  
- **Consensus timeouts (3s propose / 6s commit)** → tuned for timely block production without excessive delays, reducing the risk of forks.  
- **Persistent peer list pre-loaded** → boosts reliability and guarantees the node has known, trusted connections on startup.  
- **Prometheus metrics enabled** → makes the node observable for monitoring, alerting, and Grafana dashboards.  
- **Block sync enabled, state sync disabled by default** → prioritizes data consistency and stability (state sync can be enabled if rapid bootstrapping is required).  

Overall, this setup is **validator-ready**: stable, performant, and observable out-of-the-box, while leaving room for customization depending on your environment.  

---

### 🔎 Detailed Breakdown

- **Core Settings**  
  - `proxy_app = "tcp://0.0.0.0:26658"` → connects CometBFT to the ABCI application  
  - `moniker = "bannon-validator-x8"` → human-readable validator name  
  - `db_backend = "goleveldb"` → default storage backend  
  - `log_level = "info"` → balanced logging output  

- **RPC Service** (`tcp://0.0.0.0:26657`)  
  - Open CORS & safe method/headers for external queries  
  - Handles up to **1024 concurrent connections**  
  - Includes profiling endpoint at `127.0.0.1:6060`  

- **P2P Networking**  
  - Public address: `tcp://73.3.165.55:26656`  
  - Pre-configured with a robust list of persistent peers  
  - Allows **80 inbound** and **40 outbound peers**  
  - Duplicate IPs allowed (better connectivity for testnets)  

- **Mempool**  
  - Mode: **flood** (fast gossip)  
  - Size: **5000 txs** / 256 MB total  
  - Max single tx size: **1 MB**  

- **Consensus**  
  - Propose timeout: **3s** with fine-grained deltas  
  - Commit timeout: **6s**  
  - Empty blocks enabled  

- **Block Sync & State Sync**  
  - `blocksync` enabled with version `v0`  
  - `statesync` disabled (manual config required if needed)  

- **Instrumentation**  
  - Prometheus metrics enabled at `127.0.0.1:26660`  
  - Namespace: `cometbft`  

---

### 📋 Quick Reference Table

| Section        | Key Setting / Value | Notes |
|----------------|---------------------|-------|
| **Core**       | `moniker = "bannon-validator-x8"` | Validator name |
|                | `db_backend = "goleveldb"` | Storage backend |
| **RPC**        | `laddr = "tcp://0.0.0.0:26657"` | RPC endpoint |
|                | `max_open_connections = 1024` | Connection limit |
| **P2P**        | `external_address = "tcp://73.3.165.55:26656"` | Public P2P address |
|                | `max_num_inbound_peers = 80` | Peers allowed inbound |
|                | `max_num_outbound_peers = 40` | Peers allowed outbound |
| **Mempool**    | `type = "flood"` | Gossip mode |
|                | `size = 5000` | Max txs in pool |
|                | `max_tx_bytes = 1048576` | Max tx size (1 MB) |
| **Consensus**  | `timeout_propose = "3s"` | Proposal timeout |
|                | `timeout_commit = "6s"` | Commit timeout |
| **Blocksync**  | `version = "v0"` | Block sync enabled |
| **Statesync**  | `enable = false` | Disabled |
| **Metrics**    | `prometheus = true` | Enabled |
|                | `prometheus_listen_addr = "127.0.0.1:26660"` | Metrics port |

---

⚡ **Tip:** Adjust `persistent_peers` and `external_address` as needed for your deployment.  
For public validators, secure RPC behind a reverse proxy (e.g. Nginx with TLS).  


## ⚙️ Application Configuration (`app.toml`)

This configuration controls how the application layer of your **Qubetics validator** runs.  
It’s optimized for **efficient pruning, stable APIs, and high throughput transaction handling**.  

---

### 🔎 Detailed Breakdown

- **Core Settings**  
  - `minimum-gas-prices = "0.025tics"` → protects against spam by requiring a small fee.  
  - `pruning = "custom"` with **keep-recent = 2000** → saves storage by pruning old blocks while keeping a useful history window.  
  - `inter-block-cache = true` → improves performance by caching results between blocks.  
  - `iavl-cache-size = 781250` → tuned for large state performance.  
  - `snapshot-interval = 0` → snapshotting disabled (can be enabled for faster state sync if needed).  

- **Telemetry**  
  - Disabled by default → reduces overhead unless observability is explicitly required.  

- **API (REST)**  
  - `enable = false` by default for security.  
  - Configured to listen on `0.0.0.0:1317` with **1,000 max connections** if enabled.  
  - `enabled-unsafe-cors = true` for open testing environments.  

- **gRPC**  
  - Enabled on `0.0.0.0:9090`.  
  - Supports **large message sizes** (up to 2 GB send).  
  - gRPC-Web (`9091`) disabled by default.  

- **State Sync / Store**  
  - State sync snapshots disabled → focuses on full sync stability.  
  - Store streamers available but not configured.  

- **Mempool**  
  - Supports **2,000 txs max** with size up to **1 GB total**.  
  - High cache size (10,000) ensures quick lookups.  
  - TTL disabled (no expiration).  

- **EVM / JSON-RPC**  
  - JSON-RPC (8545/8546) disabled by default → hardened security.  
  - API includes `eth, net, web3` if enabled.  
  - `gas-cap = 25,000,000` and `txfee-cap = 1` prevent abuse.  

- **TLS**  
  - Certificate and key path left empty → use reverse proxy (e.g. Nginx) for HTTPS.  

- **MemiAVL**  
  - Disabled by default → avoids experimental features unless explicitly needed.  

---

### 📋 Quick Reference Table

| Section        | Key Setting / Value | Notes |
|----------------|---------------------|-------|
| **Core**       | `minimum-gas-prices = "0.025tics"` | Anti-spam fee floor |
|                | `pruning = custom (2000 / interval 50)` | Efficient disk usage |
|                | `inter-block-cache = true` | Performance boost |
| **API**        | `address = 0.0.0.0:1317` | REST endpoint (disabled by default) |
|                | `max-open-connections = 1000` | API connection cap |
| **gRPC**       | `enable = true` | Enabled by default |
|                | `address = 0.0.0.0:9090` | Main gRPC |
|                | `max-send-msg-size = 2GB` | Large tx support |
| **Mempool**    | `max-txs = 2000` | Max transactions |
|                | `max_txs_bytes = 1GB` | Pool size cap |
|                | `cache_size = 10000` | Faster lookups |
| **EVM / RPC**  | `enable = false` | JSON-RPC disabled (secure default) |
|                | `api = eth,net,web3` | Supported APIs if enabled |
|                | `gas-cap = 25,000,000` | Prevents gas abuse |
| **Telemetry**  | `enabled = false` | Off by default |
| **TLS**        | `certificate-path = ""` | Use external reverse proxy |
| **Snapshots**  | `interval = 0` | Disabled |

---

### 🚀 Why These Settings Are Optimized

- **Gas floor & pruning** → stops spam while saving disk space.  
- **Inter-block & IAVL caching** → boosts validator performance under heavy load.  
- **API & JSON-RPC disabled by default** → secure baseline, can be enabled selectively.  
- **Generous gRPC limits** → supports high-throughput validators without choking.  
- **Mempool tuned large** → ensures high transaction capacity without dropping valid txs.  
- **Telemetry & experimental features off** → keeps footprint lean unless explicitly needed.  

👉 Overall, this config is **production-ready** with security defaults, performance boosts, and extensibility for monitoring or APIs when required.  