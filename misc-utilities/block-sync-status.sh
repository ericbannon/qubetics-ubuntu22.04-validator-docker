while true; do
  height=$(grep 'height=' /mnt/nvme/qubetics/cosmovisor.log | tail -n 1 | \
           awk -F'height=' '{print $2}' | awk '{print $1}')
  if [ -n "$height" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') 🧱 Block height: $height"
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') ⚠️  No block height found"
  fi
  sleep 60
done