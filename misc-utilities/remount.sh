#!/bin/bash

set -e

# Function to log status messages
echo_status() {
    echo -e "\033[1;32m[INFO]\033[0m $1"
}

echo_status "Checking for running cosmovisor or qubetics processes..."

# Kill any lingering cosmovisor or qubeticsd processes
for proc in $(pgrep -f cosmovisor); do
    echo_status "Killing cosmovisor process with PID $proc"
    sudo kill -9 "$proc"
    sleep 1
done

for proc in $(pgrep -f qubeticsd); do
    echo_status "Killing qubeticsd process with PID $proc"
    sudo kill -9 "$proc"
    sleep 1
done

echo_status "Checking for Docker containers using /mnt/nvme..."

docker ps -a --format '{{.ID}} {{.Mounts}}' | grep "/mnt/nvme" | awk '{print $1}' | while read -r container; do
    echo_status "Stopping and removing Docker container: $container"
    sudo docker stop "$container"
    sudo docker rm "$container"
done

echo_status "Attempting to unmount /mnt/nvme..."
sudo umount -l /mnt/nvme || echo_status "/mnt/nvme was not mounted."

# Optionally remount if needed (replace this with your actual NVMe device)
# echo_status "Remounting NVMe device..."
# sudo mount /dev/nvme0n1p1 /mnt/nvme

echo_status "Deleting /mnt/nvme/qubetics..."
sudo rm -rf /mnt/nvme/qubetics

echo_status "Cleanup completed."
sudo mount /dev/nvme0n1p1 /mnt/nvme
echo "nvme remounted"
