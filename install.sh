cat > install.sh <<'SCRIPT'
#!/bin/bash
set -e

# 1 Update
apt update && apt -y upgrade

# 2 Nvidia Treiber prüfen/installieren
if ! command -v nvidia-smi &> /dev/null; then
  apt -y install nvidia-driver-535
  echo "Reboot nach Treiberinstallation empfohlen!"
fi

# 3 Docker + NVIDIA Toolkit
apt -y install ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

distribution=$(. /etc/os-release;echo $ID$VERSION_ID) \
 && curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
 && curl -fsSL https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
apt update && apt -y install nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# 4 Projekt
mkdir -p /opt/anythingllm && cd /opt/anythingllm

cat > docker-compose.yml <<'YAML'
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    volumes:
      - ollama:/root/.ollama
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  anythingllm:
    image: mintplexlabs/anythingllm:latest
    container_name: anythingllm
    restart: unless-stopped
    ports:
      - "3001:3001"
    environment:
      - JWT_SECRET=please-change-me
      - STORAGE_DIR=/app/server/storage
    volumes:
      - anything:/app/server/storage
    depends_on:
      - ollama

volumes:
  ollama:
  anything:
YAML

# 5 Start Container
docker compose up -d

# 6 Modell laden
docker exec -it ollama ollama pull llama3.1:8b

echo "------------------------------------------------"
echo "✅ Installation abgeschlossen."
echo "AnythingLLM UI: http://DEINE_SERVER_IP:3001"
echo "Provider: Generic OpenAI"
echo "Base URL: http://ollama:11434/v1"
echo "API Key: dummy"
echo "Model: llama3.1:8b"
echo "------------------------------------------------"
SCRIPT

chmod +x install.sh
