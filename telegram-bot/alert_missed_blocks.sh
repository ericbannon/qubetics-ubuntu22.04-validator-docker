# /etc/systemd/system/qubetics-alert.service
[Unit]
Description=Qubetics missed block Telegram alert
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=admin
WorkingDirectory=/home/admin/scripts
EnvironmentFile=/etc/default/telegram.env
# Optional: fail early if env is missing
ExecStartPre=/usr/bin/test -r /etc/default/telegram.env
# Use a direct interpreter and the absolute script path
ExecStart=/bin/bash /home/admin/scripts/alert_missed_blocks.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target