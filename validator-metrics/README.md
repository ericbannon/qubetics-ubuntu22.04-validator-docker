# 📈 Qubetics Block Rate Monitor

A lightweight Bash script to calculate the average block production rate of a Qubetics validator over the past 10 minutes, using your local `cosmovisor.log`.

---

## ✅ Features

Runs for 3 Minutes on the current log stream for quick execution:

```
📡 Watching block production for 3 minutes...
⏳ Start time: Tue Jul 29 14:42:02 UTC 2025
```

- Parses timestamps like `7:46AM` from log lines
- Matches lines containing **`executed`** (one per block)
- Filters blocks based on real timestamps — no assumptions about block time
- Strips ANSI color codes for accurate parsing
- Outputs block count and average blocks per minute

---

## 🗂 Requirements

- **OS**: Linux (tested on Ubuntu 22.04)
- **Log path**: `/mnt/nvme/qubetics/cosmovisor.log`
- **Dependencies**: `bash`, `awk`, `date`, `tail` (all standard)

---

## 🚀 Usage

```bash
chmod +x block_rate.sh
./block_rate.sh
```

## 📤 Example Output
```
📊 Analyzing block rate over the last 10 minutes...
🧱 Block count (last 10 minutes): 295
⏱️ Block rate per minute: 29
```