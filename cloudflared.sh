#!/bin/bash

set -e

# -----------------------------
# Variablen anpassen
# -----------------------------
TUNNEL_NAME="allm-s2"
HOSTNAME="allm-s2.hestrix.net"
LOCAL_SERVICE="http://127.0.0.1:3001"

# -----------------------------
# Installation cloudflared
# -----------------------------
echo "[INFO] Installing cloudflared..."
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O cloudflared
sudo mv cloudflared /usr/local/bin/cloudflared
sudo chmod +x /usr/local/bin/cloudflared

echo "[INFO] Installed cloudflared version: $(cloudflared --version)"

# -----------------------------
# Cloudflare Login
# -----------------------------
echo "[ACTION REQUIRED] Bitte den folgenden Befehl im Browser bestätigen!"
cloudflared tunnel login

# -----------------------------
# Tunnel anlegen
# -----------------------------
echo "[INFO] Creating tunnel $TUNNEL_NAME..."
cloudflared tunnel create $TUNNEL_NAME

# UUID ermitteln
UUID=$(ls ~/.cloudflared | grep .json | sed 's/.json//')
echo "[INFO] Tunnel UUID: $UUID"

# -----------------------------
# DNS Route setzen
# -----------------------------
echo "[INFO] Creating DNS route for $HOSTNAME..."
cloudflared tunnel route dns $TUNNEL_NAME $HOSTNAME

# -----------------------------
# Config-Datei erstellen
# -----------------------------
echo "[INFO] Writing config.yml..."
mkdir -p ~/.cloudflared
cat > ~/.cloudflared/config.yml << EOF
tunnel: $UUID
credentials-file: /root/.cloudflared/$UUID.json

ingress:
  - hostname: $HOSTNAME
    service: $LOCAL_SERVICE
  - service: http_status:404
EOF

# -----------------------------
# Service einrichten
# -----------------------------
echo "[INFO] Installing systemd service..."
sudo cloudflared service install
sudo systemctl enable --now cloudflared

echo "[INFO] Cloudflared setup completed!"
echo "[INFO] Test your service at: https://$HOSTNAME"
