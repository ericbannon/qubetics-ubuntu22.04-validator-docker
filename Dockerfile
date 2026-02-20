FROM ubuntu:22.04

LABEL maintainer="Eric Bannon - GitHub: ericbannon" \
      version="2.0" \
      description="An Ubuntu 22.04 Docker Image to run a Qubetics mainnet validator node"

ENV DEBIAN_FRONTEND=noninteractive

# --- Upgrade settings ---
ARG VERSION=22.04
ENV VERSION=${VERSION}

ENV UPGRADEVER=v2.0.0
ENV UPGRADE_URL=https://github.com/Qubetics/qubetics-upgrade-v2.0.0/releases/download/ubuntu${VERSION}/qubeticsd

# Cosmovisor
ENV COSMOVER=1.5.0

# Install prerequisites FIRST (curl is needed for the upgrade download)
RUN set -eux; \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      curl \
      ca-certificates \
      libssl3 \
      libcurl4 \
      git \
      wget \
      unzip \
      file \
      jq \
      sudo \
      build-essential \
      bash && \
    rm -rf /var/lib/apt/lists/*

# Download upgrade binary and place it in the cosmovisor upgrade slot
RUN set -eux; \
    mkdir -p /opt/cosmovisor/upgrades/${UPGRADEVER}/bin; \
    curl -fsSL "${UPGRADE_URL}" -o /opt/cosmovisor/upgrades/${UPGRADEVER}/bin/qubeticsd; \
    chmod +x /opt/cosmovisor/upgrades/${UPGRADEVER}/bin/qubeticsd; \
    ls -lah /opt/cosmovisor/upgrades/${UPGRADEVER}/bin/qubeticsd; \
    /opt/cosmovisor/upgrades/${UPGRADEVER}/bin/qubeticsd version || true

# Define Go version and paths
ENV GO_VERSION=1.22.4
ENV GOROOT=/usr/local/go
ENV GOPATH=/go
ENV PATH=$GOROOT/bin:$GOPATH/bin:$PATH

# Download and install Go (amd64 tarball — build image for linux/amd64)
RUN set -eux; \
    wget -q https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz; \
    rm -rf /usr/local/go; \
    tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz; \
    rm go${GO_VERSION}.linux-amd64.tar.gz

# Download Node Validator Scripts
RUN set -eux; \
    rm -rf /opt/qubetics; \
    git clone https://github.com/ericbannon/qubetics-ubuntu22.04-validator-docker.git /opt/qubetics; \
    mv /opt/qubetics/ubuntu22.04build/qubeticsd /usr/local/bin/qubeticsd; \
    chmod +x /usr/local/bin/qubeticsd; \
    chmod +x /opt/qubetics/qubetics_ubuntu_node.sh; \
    chmod +x /opt/qubetics/host-utilities/*

# Install cosmovisor
RUN set -eux; \
    go install cosmossdk.io/tools/cosmovisor/cmd/cosmovisor@v${COSMOVER}; \
    mv /go/bin/cosmovisor /usr/local/bin/; \
    chmod +x /usr/local/bin/cosmovisor

# Optional: keep default as bash (your script uses docker exec),
# or switch to cosmovisor ENTRYPOINT if you want it to auto-start.
CMD ["/bin/bash"]