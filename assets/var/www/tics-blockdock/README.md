
# Bannon TICS Validator — Minimal Site

Static site you can host with Caddy on your node.

## Deploy

1. Copy files to your server:
   ```bash
   sudo mkdir -p /var/www/bannon-tics
   sudo rsync -av ./ /var/www/bannon-tics/
   ```

2. Add this to `/etc/caddy/Caddyfile` and reload:
   ```caddyfile
   bannon-tics-validator.com, www.bannon-tics-validator.com {{
       root * /var/www/bannon-tics
       file_server
       encode zstd gzip
   }}
   ```

3. Reload Caddy:
   ```bash
   sudo caddy reload --config /etc/caddy/Caddyfile
   ```

## Customize
- Replace `YOUR_OPERATOR_ADDRESS_HERE` in `index.html`.
- Swap `/assets/logo.png` with your own.
- Update links and contact info.

MIT licensed — reuse freely.
