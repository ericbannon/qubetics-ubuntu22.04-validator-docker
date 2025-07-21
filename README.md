# qubetics-ubuntu22.04-validator-docker

## Description
This is a working example of a Docker image that leverages Ubuntu 22.04 to run the Qubetics Mainnet Validator Node on any cloud environment, or hardware. 

## Reccomended Usage
Build the Dockerfile as an amd64 image for x86 usage (ARM is not currently supported upstream https://github.com/Qubetics/qubetics-mainnetnode-script/tree/main)

### Key notes

* Installs Go 1.22.4 which coscmovisor@v1.5.0 relies on
* Installs all prerequisites (eg. jq qget build-essential, etc..)
* Sets ENV for all required PATHS
* Leverages a modified qubetics_ubuntu_node.sh script that removes pre-requisite installations
* Modifies the qubetics_ubuntu_node.sh script to start the qubeticsd directly from cosmovisor since systemctl is not supported in Docker
* Can be run as amd64 on any ARM system (eg. raspberry pi 5) with qemu emulation enabled

### Usage

If running on an ARM based system:

```
docker run -dit --platform=linux/amd64  --name validator-node   --restart unless-stopped   --privileged   --network host   bannimal/tics-validator-node:latest
```

If already running on x86 platform:

```
docker run -dit --name validator-node   --restart unless-stopped   --privileged   --network host   bannimal/tics-validator-node:latest
```

### Install Qubetics Validator Node

bash -x qubetics_ubuntu_node.sh

Enter in your node details and proceed to make note of any of the outpout - mnemonics & Node information

### Concluding Notes 

Since you have started the Docker container in the background using the "-d" flag, you can dafely exit the running container and the qubeticsd service will continue to run.

* Additional scripts added for fast_sync to snapshotter & node upgrade scripts.

* I will continue to pull from the upstream fork and make modifications to this repo to ensure validator-node enhancements continue to work in a Dockerized configuration

