## Useful Host Utilities

### Auto-boot Disaster Recovery & Auto-Upgrade Rebuilds

#### autoexec-docker.sh
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

### Other Utilities

#### network-speed-test
* ✅ Runs a quick utility container to check your network speed on your validator node

#### Auto-upgrades to new version of qubeticd

* ✅ qubetics_upgrade.sh handles automatic upgrades to newer version of qubeticds. This will be fully managed through updated Dockerfile configurations and rollouts, but this provides an example of how it is done under the hood.