# qubetics-ubuntu22.04-validator-docker

## Description
This is a working example of a Docker image that leverages Ubuntu 22.04 to run the Qubetics Mainnet Validator Node on any cloud environment, or hardware. 

## Key notes

* Built as a amd64 image for x86 usage (No ARM support until supported upstream)
* Installs Go 1.22.4 which coscmovisor@v1.5.0 relies on
* Installs all prerequisites (eg. jq qget build-essential, etc..)
* Sets ENV for all required PATHS
* Leverages a modified qubetics_ubuntu_node.sh script that removes pre-requisite installations
* Modifies the qubetics_ubuntu_node.sh script to start the qubeticsd directly from cosmovisor since systemctl is not supported in Docker
* Can be run as amd64 on any ARM system (eg. raspberry pi 5) assuming qemu emulation is enabled

## Usage

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

