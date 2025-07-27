FROM ubuntu:22.04

LABEL maintainer="Eric Bannon - GitHub: ericbannon" \
      version="1.0" \
      description="An Ubuntu 22.04 Docker Image to run a Qubetics mainnet validator node"

# Install Qubetics node prerequisites 

ENV DEBIAN_FRONTEND=noninteractive

# Set environment variables if needed
# ENV DAEMON_NAME=qubeticsd
# ENV DAEMON_HOME=/mnt/nvme/qubetics

RUN apt-get update && \
    apt-get install -y \
    curl \
    libssl3 \
    libcurl4 \
    ca-certificates \
    git \
    wget \
    unzip \
    file \
    jq \
    sudo \
    build-essential \
    bash && \
    rm -rf /var/lib/apt/lists/*

# Define Go version and paths

ENV GO_VERSION=1.22.4
ENV GOROOT=/usr/local/go
ENV GOPATH=/go
ENV PATH=$GOROOT/bin:$GOPATH/bin:$PATH

# Download and install Go

RUN wget https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz && \
    rm -rf /usr/local/go && \
    tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz && \
    rm go${GO_VERSION}.linux-amd64.tar.gz

# Download Node Validtor Scripts

RUN git clone https://github.com/ericbannon/qubetics-ubuntu22.04-validator-docker.git /opt/qubetics && \
    chmod +x /opt/qubetics/qubetics_ubuntu_node.sh && \
    chmod +x /opt/qubetics/misc-utilities/*

# Download upgrade binary (v1.0.1) and place it in the upgrade slot
ENV UPGRADE_URL=https://github.com/Qubetics/qubetics-mainnet-upgrade/releases/download/ubuntu22.04/qubeticsd

RUN mkdir /opt/qubetics/upgrades && \   
    curl -L $UPGRADE_URL -o /opt/qubetics/upgrades/qubeticsd

# Install COSMOVISOR 1.5.0 

RUN go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v1.5.0 && \
    mv /go/bin/cosmovisor /usr/local/bin/ && \
    chmod +x /usr/local/bin/cosmovisor