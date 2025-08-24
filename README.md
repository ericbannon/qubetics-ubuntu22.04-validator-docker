# qubetics-ubuntu22.04-validator-docker 📦

## Description
This is a working example of a Dockerized deployment that leverages Ubuntu 22.04 to run the Qubetics Mainnet Validator Node on any cloud environment, or hardware. 

I will continue to pull from the upstream fork and make modifications to this repo to ensure validator-node enhancements continue to work in a Dockerized configuration and continual upgrades as they are released

**Image Repository:** https://hub.docker.com/repository/docker/bannimal/tics-validator-node/general 

The Docker Image will be updated with newer versions of qubeticsd and rebuilt with the same version tag. v1.0.3 will be next.

## Welcome to Block Dock Validator* 🚢🐳

*Validator (valoper):* qubeticsvaloper18llj8eqh9k9mznylk8svrcc63ucf7y2r4xkd8l

<p>
  <a href="https://t.me/blockdockvalidator">
    <img src="assets/blockdock.png" alt="Block Dock Productions logo" width="260">
  </a>
</p>

👉 Subscribe for updates

<p><strong>Telegram:</strong> <a href="https://t.me/blockdockvalidator">@blockdockvalidator</a></p>
 
Stake with confidence. Here’s what you get as a delegator:

### 🔒 *Private, non-cloud infrastructure** 
Our validator runs on a private server over a private VPN—no big-cloud control plane, no shared tenancy. Fewer noisy neighbors and fewer correlated outages mean more time signing blocks and earning rewards.

### 🛡️ *Operated by a 20-year cybersecurity pro*  
Security basics done right: least-privilege access, hardened hosts, change control, and continuous monitoring. It’s all designed to reduce operational mistakes that can lead to downtime or slashing.

### ⚙️ *High-performance hardware & network*  
Built on powerful compute, fast disks, and reliable networking. That translates to quick block processing, stable peering, and fewer missed signatures—i.e., *more consistent rewards* over time.

### 🐳 *Containerized (Docker) for safe, smooth upgrades*  
- *Consistency:* The validator and its dependencies ship together, so upgrades are predictable.  
- *Low downtime:* We stage updates and restart cleanly so you keep earning.  
- *Fast rollback:* If something breaks, we can revert quickly to a known-good image.  
- *Easy failover/DR:* Identical containers can be brought up on standby hardware fast.

### 🌐 *Open community, built from scratch*  
Not “instanode” or one-click. We run our own configs and share learnings. Expect clear maintenance windows, upgrade notices, and transparent ops.

#### 🌐 **Transparency: OPENSOURCE CODE for delegators to view upgrade scripts, automation and new enhancements directly in code**

*What this means for you:*  
• Higher uptime → more chances to collect rewards  
• Secure operations → lower operational risk  
• Predictable upgrades → fewer interruptions  
• Clear comms → no surprises

# Key notes for Opensource Codebase

* Installs Go 1.22.4 which coscmovisor@v1.5.0 relies on
* Installs all prerequisites (eg. jq qget build-essential, etc..)
* Sets ENV for all required PATHS
* Leverages a modified qubetics_ubuntu_node.sh script that removes pre-requisite installations
* Modifies the qubetics_ubuntu_node.sh script to start the qubeticsd directly from cosmovisor since systemctl is not supported in Docker
* Creates a cosmovisor.log for viewing the block indexing in the background and to troubleshoot errors
* Setup script sets fase fees for best network performance (Per Qubetics reccomendation)
* Reboot systemd service for auto-start and upgrades 
* Additional scripts added for fast_sync to snapshotter 

## Reccomended Usage

**OPTION 1** (Reccomended)
Use the existing Docker image I will be maintaining across releases of the mainnet

**OPTION 2**
Build your own docker image as an amd64 image for x86 usage (ARM is not currently supported upstream) [Dockerfile Example](https://github.com/ericbannon/qubetics-ubuntu22.04-validator-docker/blob/main/Dockerfile)


## ✅ Prerequisites
### System Requirements

* Memory: At least 16GB RAM
* Storage: Minimum 500GB available disk space (SSD)
* CPU: 8-core minimum
* Network: Stable internet connection

### Node configuraton requirements

- SSD mounted at `/mnt/nvme`
- Domain name (e.g., `node.validator-tics.com`) - (You need to have your own external Domain name and A record pointed to you public IP for your router and port forwarding enabled on server)
- Reverse Proxy on your server (Using Caddy)

#### Port Forwarding
- If you want to access the Validator Dashboard you can enable port forwarding on your router:
  - TCP 26656 (P2P)
  - TCP 26657 (RPC)
  - TCP 443 (HTTPS)
  - Optional: TCP 80 (redirect)

- For enhanced security, you do not need to open any ports besides 26656 if you plan to use inbound & outbound peering without accessing the Validator Dashboard. This is more secure when using a private server

**IMPORTANT**: This assumes that you have mounted your desired storage partition as /mnt/nvme/ on your host system. If you have changed this, then your ubuntu setup script home directory will need to be changed accordingly.

## Docker Steps & Node Installation 🚀

Runs a background Docker container with the Qubetics configurations installed. 

* Mounts the DAEMON_HOME as your new data directory for where the blockchain will be managed. 
* Docker container has access to the host filesystem in privilieged mode
* Since you have downloaded the upgraded versions directly in the Docker image:
* Cosmovisor uses /mnt/nvme/qubetics/cosmovisor/genesis/bin/qubeticsd initially

Once block 175000 is reached, it switches to the upgrade binary in:
/mnt/nvme/qubetics/cosmovisor/upgrades/v1.0.1/bin/qubeticsd

Once block 75000 is reached, it switches to the upgrade binary in:
/mnt/nvme/qubetics/cosmovisor/upgrades/v1.0.2/bin/qubeticsd

#### Run the Docker Container in the Background 🧪

```
  docker run -dit \
  --platform=linux/amd64 \
  --name "$CONTAINER_NAME" \
  --privileged \
  --network host \
  --cpus="16" \
  --cpuset-cpus="0-15" \
  --ulimit nofile=65536:65536 \
  --ulimit memlock=-1 \
  --cap-add sys_nice \
  -v /mnt/nvme:/mnt/nvme \
  -e DAEMON_NAME=qubeticsd \
  -e DAEMON_HOME="$DAEMON_HOME" \
  -e DAEMON_ALLOW_DOWNLOAD_BINARIES=false \
  -e DAEMON_RESTART_AFTER_UPGRADE=true \
  -e DAEMON_LOG_BUFFER_SIZE=512 \
  "$VALIDATOR_IMAGE"
``` 


**Reccomended** If you are running an independent node for the purpose of validation and want the docker container to have system access to all CPUs and RAM, please include the following in your run command:

```
    -cpus="$(nproc)" \
    --ulimit memlock=-1 \\
```

#### Install Qubetics Validator Node
```
bash -x qubetics_ubuntu_node.sh
```

Enter in your node details and proceed to make note of any of the outpout - mnemonics & Node information. Store somewhere safe and secure.

#### Useful commands to retrive Node Info

##### Get Tendermint Validator Public Key
```
$DAEMON_NAME tendermint show-validator --home $DAEMON_HOME
```
##### Get Node ID
```
$DAEMON_NAME tendermint show-node-id --home $DAEMON_HOME
```
##### Get Bech32 Wallet Address 
```
$DAEMON_NAME keys show $KEYS --keyring-backend $KEYRING --home $DAEMON_HOME -a
```

## Viewing logs & Troubleshooting 🔍

To view live logs for cosmovisor and your validator node you can run the following:

```
tail -f /mnt/nvme/qubetics/cosmovisor.log
```

# Concluding Notes 

Since you have started the Docker container in the background using the "-d" flag, you can safely exit the running container and the qubeticsd service will continue to run.

## See host-utilities README.md 🔧
Instructions on Auto-Upgrades and Safe Reboot in [Host Utilities README](./host-utilities/README.md)


