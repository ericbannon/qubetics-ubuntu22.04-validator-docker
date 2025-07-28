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
#### remount.sh
* ✅ Unmounts disk, removes files, and remounts your SSD partition

#### setup_rpi5_fan.sh (If using an RP5)
* ✅ Ubuntu does not include the RPI5 fan configurations by default 
* ✅ Installes the needed configurations for Ubuntu

#### network-speed-test
* ✅ Runs a quick utility container to check your network speed on your validator node

### Optional Configuration: set-cpu-performance
*  ✅ Configures performance for all cores on your host system

##### Create a systemd service:
```
sudo nano /etc/systemd/system/cpugov.service --> 

[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/set-cpu-performance.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target

```

##### Create an execution script
```
sudo nano /usr/local/bin/set-cpu-performance.sh
```

```
#!/bin/bash
sleep 9
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  echo performance > "$cpu/cpufreq/scaling_governor"
done
```
```
sudo chmod +x /usr/local/bin/set-cpu-performance.sh
```

##### Create udev performance rules to make sure it stays on reboot
```
sudo nano /etc/udev/rules.d/99-cpufreq-performance.rules
```

```
SUBSYSTEM=="cpu", KERNEL=="cpu[0-9]*", ACTION=="add", RUN+="/usr/bin/bash -c 'echo performance > /sys/devices/system/cpu/%k/cpufreq/scaling_governor'"
```

```
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=cpu
```

##### Mask ondemand so it disables on reboot

```
sudo systemctl mask ondemand
```

##### Enable and start the service:

```
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable cpugov.service
sudo systemctl start cpugov.service
```