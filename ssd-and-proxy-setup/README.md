## Mounting SSD Partition 🛠️

#### Identify the SSD Disk

```
lsblk
```
You should see something like:

```
NAME         MAJ:MIN RM  SIZE RO TYPE MOUNTPOINT
nvme0n1      259:0    0  1.8T  0 disk
```
#### Create a Partition and Format the Drive

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
#### Mount the Drive
```
sudo mount /dev/nvme0n1p1 /mnt/nvme
```
Check if mounted:
```
df -h
```
#### Auto-mount on Boot

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

## Publically Expose Your Local Host 🛠️

In order to add your validator node to the Qubetics system, you must have a public hostname/IP address that can communicate over https or wss. The following example uses Caddy, but Nginx can also be used if preferred.

#### 🔐 4. Setup Caddy (HTTPS Reverse Proxy)

Inside your server running Ubuntu, install:

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy
```

Create `/etc/caddy/Caddyfile`: (using your own provided Hostname below)

```caddyfile
node.validator-tics.com {
    reverse_proxy localhost:26657
}
```

Fix permissions:

```bash
sudo mkdir -p /var/log/caddy
sudo chown -R caddy:caddy /var/log/caddy
```

Validate and start:

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl restart caddy
```
