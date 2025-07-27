tail -f /mnt/nvme/qubetics/cosmovisor.log | \
grep --line-buffered 'height=' | \
awk -F'height=' '{print $2}' | \
awk '{print $1}' | \
while read height; do
  echo "$(date '+%Y-%m-%d %H:%M:%S') 🧱 Block height: $height"
done

