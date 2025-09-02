cat > install.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# --[ Settings ]----------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

# --[ Helpers ]-----------------------------------------------------------------
log()  { printf "\n\033[1;32m[✔]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[!]\033[0m %s\n" "$*"; }
err()  { printf "\n\033[1;31m[✘]\033[0m %s\n" "$*" >&2; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Bitte als root ausführen (sudo -i oder voranstellen: sudo bash install.sh)."
    exit 1
  fi
}

yesno() {
  # de/ja/j + en/yes/y => true
  local ans="${1:-}"
  [[ "$ans" =~ ^([YyJj]|[Yy]es|[Jj]a)$ ]]
}

# --[ 0 Root prüfen ]-----------------------------------------------------------
require_root

# --[ 1 System-Update ]---------------------------------------------------------
log "System aktualisieren (apt update/upgrade)…"
apt-get update -y
apt-get upgrade -y

# --[ 2 NVIDIA Treiber prüfen/installieren ]------------------------------------
if ! command -v nvidia-smi >/dev/null 2>&1; then
  warn "nvidia-smi nicht gefunden – NVIDIA-Treiber 535 wird installiert."
  apt-get install -y nvidia-driver-535
  warn "Ein Reboot nach der Treiberinstallation ist empfohlen!"
else
  log "NVIDIA-Treiber erkannt: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo 'unbekannt')"
fi

# --[ 3 Docker + NVIDIA Toolkit ]-----------------------------------------------
log "Docker installieren…"
apt-get install -y ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

UBUNTU_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
ARCH="$(dpkg --print-architecture)"
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
  | tee /etc/apt/sources.list.d/docker.list >/dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Docker-Dienst sicherstellen
systemctl enable --now docker

# User der docker-Gruppe hinzufügen (wenn via sudo gestartet)
if [ -n "${SUDO_USER:-}" ] && id -nG "$SUDO_USER" | grep -qv '\bdocker\b'; then
  usermod -aG docker "$SUDO_USER" || true
  warn "User '$SUDO_USER' zur 'docker'-Gruppe hinzugefügt (erneutes Login nötig)."
fi

log "NVIDIA Container Toolkit installieren…"
distribution=$(. /etc/os-release; echo ${ID}${VERSION_ID})
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL "https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list" \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

apt-get update -y
apt-get install -y nvidia-container-toolkit

# Docker-Runtime mit NVIDIA konfigurieren
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# --[ 4 Projektverzeichnis + .env ]---------------------------------------------
log "Projektverzeichnis anlegen…"
mkdir -p /opt/anythingllm && cd /opt/anythingllm

# JWT_SECRET in .env schreiben (Compose liest diese automatisch)
if [ ! -f .env ]; then
  JWT_SECRET_VAL="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 48 || true)"
  printf "JWT_SECRET=%s\n" "$JWT_SECRET_VAL" > .env
else
  if ! grep -q '^JWT_SECRET=' .env; then
    JWT_SECRET_VAL="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 48 || true)"
    printf "\nJWT_SECRET=%s\n" "$JWT_SECRET_VAL" >> .env
  fi
fi

# --[ 4.1 Domain-Setup (optional) ]---------------------------------------------
ENABLE_DOMAIN="0"
DOMAIN=""
ACME_EMAIL=""

read -r -p $'\nMöchtest du eine Domain für AnythingLLM verbinden und automatisch HTTPS einrichten? [y/N]: ' WANT_DOMAIN || true
if yesno "${WANT_DOMAIN:-}"; then
  ENABLE_DOMAIN="1"
  while :; do
    read -r -p "Bitte gib die Domain (FQDN) ein, z. B. ai.deine-domain.tld: " DOMAIN || true
    # sehr einfache Validierung
    if [[ -n "${DOMAIN:-}" && "$DOMAIN" =~ ^[A-Za-z0-9._-]+\.[A-Za-z]{2,}$ ]]; then
      break
    else
      warn "Ungültige Domain. Bitte erneut eingeben."
    fi
  done
  read -r -p "Optionale E-Mail für Let's Encrypt Benachrichtigungen (Enter zum Überspringen): " ACME_EMAIL || true

  log "Caddy Reverse Proxy wird konfiguriert (automatisches TLS)…"

  # Caddyfile schreiben (mit Domain)
  # Hinweis: Unquoted Heredoc -> Variablenexpand zur Laufzeit
  cat > Caddyfile <<CADDY
${ACME_EMAIL:+{
  email ${ACME_EMAIL}
}}

${DOMAIN} {
  encode zstd gzip
  reverse_proxy anythingllm:3001
}
CADDY

  # Compose-Override für Caddy schreiben
  cat > docker-compose.caddy.yml <<'YAML'
services:
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - anythingllm

volumes:
  caddy_data:
  caddy_config:
YAML

  # UFW-Regeln (falls ufw aktiv ist)
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    warn "UFW ist aktiv – öffne Ports 80/443…"
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
  fi
fi

# --[ 5 Compose schreiben ]-----------------------------------------------------
log "docker-compose.yml schreiben…"
cat > docker-compose.yml <<'YAML'
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    environment:
      - OLLAMA_KEEP_ALIVE=30m
      - OLLAMA_HOST=0.0.0.0
    volumes:
      - ollama:/root/.ollama
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    healthcheck:
      # Kein curl nötig – nutzt das eingebaute CLI
      test: ["CMD-SHELL", "ollama list >/dev/null 2>&1 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 20

  anythingllm:
    image: mintplexlabs/anythingllm:latest
    container_name: anythingllm
    restart: unless-stopped
    ports:
      - "3001:3001"
    environment:
      - JWT_SECRET=${JWT_SECRET}
      - STORAGE_DIR=/app/server/storage
    volumes:
      - anything:/app/server/storage
    depends_on:
      ollama:
        condition: service_healthy

volumes:
  ollama:
  anything:
YAML

# --[ 6 Container starten ]-----------------------------------------------------
log "Container starten…"
COMPOSE_ARGS=(-f docker-compose.yml)
if [ "$ENABLE_DOMAIN" = "1" ]; then
  COMPOSE_ARGS+=(-f docker-compose.caddy.yml)
fi
docker compose "${COMPOSE_ARGS[@]}" up -d

# --[ 7 Warten bis Ollama bereit ist ]------------------------------------------
log "Warte, bis Ollama bereit ist…"
for i in {1..60}; do
  if docker exec ollama ollama list >/dev/null 2>&1; then
    log "Ollama ist bereit."
    break
  fi
  sleep 3
  if [ "$i" -eq 60 ]; then
    err "Ollama wurde nicht rechtzeitig bereit. Bitte Logs prüfen: docker logs -n 200 ollama"
    exit 1
  fi
done

# --[ 8 Modelle laden ]---------------------------------------------------------
log "Modelle in Ollama laden (dies kann je nach Verbindung einige Minuten dauern)…"

pull_model() {
  local model="$1"
  if docker exec ollama ollama pull "$model"; then
    log "Modell geladen: $model"
  else
    warn "Konnte Modell nicht laden (übersprungen): $model"
  fi
}

# Basis + gewünschte Modelle
pull_model "llama3.1:8b"
pull_model "mixtral:8x7b"

# --[ 9 Hinweise ]--------------------------------------------------------------
UI_URL="http://DEINE_SERVER_IP:3001"
if [ "$ENABLE_DOMAIN" = "1" ]; then
  UI_URL="https://${DOMAIN}"
  warn "Stelle sicher, dass ein A/AAAA-Record für ${DOMAIN} auf diesen Server zeigt, sonst kann kein Zertifikat ausgestellt werden."
fi

cat <<EOF

------------------------------------------------
✅ Installation abgeschlossen.

In AnythingLLM:
  Provider: Generic OpenAI
  Base URL: http://ollama:11434/v1
  API Key: dummy
  Token context window: 8192
  Max tokens: 2048
  Modelle: llama3.1:8b / mixtral:8x7b

------------------------------------------------
EOF
SCRIPT

chmod +x install.sh
echo "install.sh aktualisiert. Ausführen mit: sudo bash install.sh"

