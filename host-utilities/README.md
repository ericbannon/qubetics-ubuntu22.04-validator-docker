## Useful Host Utilities

### Auto-boot Disaster Recovery & Auto-Upgrade Rebuilds

#### validator-startup.sh
* ✅ Starts your Docker container on reboot
* ✅ Starts Cosmovisor with retries
* ✅ Checks for both fatal errors and successful block execution
* ✅ Tails the logs to confirm re-syncing is healthy 

Note: include the startup-logs.sh script in your bash_profile to tail the output of the reboot script for success and failures upon SSH after reboot

#### validator-reboot.service
* ✅ A systemd service to auto-launch the reboot-starts.sh script

```
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable validator-reboot.service
sudo systemctl start validator-reboot.service
``` 

### performance_check.sh

Runs a series of performance checks on your node including syncing status, CPU/MEM/DISK IO data, and network bottlenecks as well as validator stats and time syncs. Prints simple summary report

### check_missed_range.sh

Checks the last 100 block heights to confirm NIL, ABSENT, IN_SET, NOT_IN_SET details.

### missed_block_analysis

**Usage**

Examines your commit for specified block height to confirm NIL, ABSENT, IN_SET, NOT_IN_SET and signing details for troubleshooting or confirming correct missed_block_counters seen. 

```
./missed_block_analysis -H <block-height>
```

### net_stability_watch.sh

Polls the cosmovisor.log for 10 minutes to detect network stability issues, timeouts and flapping

### io_watch.sh

Single-run check: wait 60 s, then prints the growth, FS usage, device I/O, and Docker’s counter.

### telegram-bot folder

Includes auto update TG messages script examples, node maintenance notifications, and more