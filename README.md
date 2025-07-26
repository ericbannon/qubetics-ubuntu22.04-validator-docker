# qubetics-ubuntu22.04-validator-docker

## Description
This is a working example of a Docker image that leverages Ubuntu 22.04 to run the Qubetics Mainnet Validator Node on any cloud environment, or hardware. 

## Reccomended Usage
Build the Dockerfile as an amd64 image for x86 usage (ARM is not currently supported upstream https://[Dockerfile Example](https://github.com/ericbannon/qubetics-ubuntu22.04-validator-docker/blob/main/Dockerfile)

### Key notes

* Installs Go 1.22.4 which coscmovisor@v1.5.0 relies on
* Installs all prerequisites (eg. jq qget build-essential, etc..)
* Sets ENV for all required PATHS
* Leverages a modified qubetics_ubuntu_node.sh script that removes pre-requisite installations
* Modifies the qubetics_ubuntu_node.sh script to start the qubeticsd directly from cosmovisor since systemctl is not supported in Docker
* Can be run as amd64 on any ARM system (eg. raspberry pi 5) with qemu emulation enabled
* Creates a cosmovisor.log for viewing the block indexing in the background and to troubleshoot errors

### Usage

IMPORTANT: This assumes that you have mounted your desired storage partition as /mnt/nvme/ on your host system. If you have changed this, then your ubuntu setup script home directory will need to be changed accordingly.

#### Mounting SSD partition on your host system

##### Identify the SSD disk

```
lsblk
```
You should see something like:

```
NAME         MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT
nvme0n1      259:0    0  1.8T  0 disk
```
##### Create a partition and format the drive

```
sudo fdisk /dev/nvme0n1
```
Inside fdisk:
```
g → create GPT partition table
n → new partition
w → write and exit
```
Format as ext4:
```
sudo mkfs.ext4 /dev/nvme0n1p1
```
##### Mount the drive
```
sudo mount /dev/nvme0n1p1 /mnt/nvme
```
Check if mounted:
```
df -h
```
##### Auto-mount on Boot

Get the UUID:
```
sudo blkid /dev/nvme0n1p1
```
example: /dev/nvme0n1p1: UUID="abcd-1234" TYPE="ext4"

Edit fstab
```
sudo nano /etc/fstab
```
Add:
```
UUID=abcd-1234 /mnt/nvme ext4 defaults,noatime 0 2
```
Note: replace with you actual UUID
Save and test:
```
sudo mount -a
```
Your drive is now mounted at /mnt/nvme and will stay mounted after reboot.

* You are running a background Docker container with the Qubetics configurations installed. 
* Notice that you are mounting the DAEMON_HOME as your new data directory for where the blockchain will be managed. 
* You are giving the docker container access to the host filesystem in privilieged mode
* The container will not restart unless stopped to provide continuity and avoid uneccessary reboots

If running on an ARM based system:

```
docker run -dit \
  --platform=linux/amd64 \
  --name validator-node \
  --restart unless-stopped \
  --privileged \
  --network host \
  -v /mnt/nvme:/mnt/nvme \
  -e DAEMON_NAME=qubeticsd \
  -e DAEMON_HOME=/mnt/nvme/qubetics \
  -e DAEMON_ALLOW_DOWNLOAD_BINARIES=false \
  -e DAEMON_RESTART_AFTER_UPGRADE=true \
  -e DAEMON_LOG_BUFFER_SIZE=512 \
  bannimal/tics-validator-node:latest
```

If already running on x86 platform:

``docker run -dit \
  --name validator-node \
  --restart unless-stopped \
  --privileged \
  --network host \
  -v /mnt/nvme:/mnt/nvme \
  -e DAEMON_NAME=qubeticsd \
  -e DAEMON_HOME=/mnt/nvme/qubetics \
  -e DAEMON_ALLOW_DOWNLOAD_BINARIES=false \
  -e DAEMON_RESTART_AFTER_UPGRADE=true \
  -e DAEMON_LOG_BUFFER_SIZE=512 \
  bannimal/tics-validator-node:latest
```

### Install Qubetics Validator Node

bash -x qubetics_ubuntu_node.sh

Enter in your node details and proceed to make note of any of the outpout - mnemonics & Node information

### Concluding Notes 

Since you have started the Docker container in the background using the "-d" flag, you can dafely exit the running container and the qubeticsd service will continue to run.

### Viewing logs & Troubleshooting

To view live logs for cosmovisor and your validator node you can run the following:

```
tail -f /mnt/nvme/qubetics/cosmovisor.log
```

* Additional scripts added for fast_sync to snapshotter & node upgrade scripts.

* I will continue to pull from the upstream fork and make modifications to this repo to ensure validator-node enhancements continue to work in a Dockerized configuration

