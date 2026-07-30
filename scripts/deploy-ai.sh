#!/usr/bin/env bash
#
# deploy-ai.sh - deploy Ollama + Open WebUI stack to the VM
#
set -euo pipefail

G='\033[32m'; Y='\033[33m'; R='\033[31m'; C='\033[36m'; N='\033[0m'
BOX="docker"

step() { printf '%s=>%s %s\n' "$G" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# Check rootd
command -v rootd >/dev/null 2>&1 || die "rootd not found. Run termux-setup.sh first."

step "Creating AI directory on VM"
rootd sh $BOX -- ssh $DOCKER_HOST "mkdir -p ~/ai-stack"

step "Copying docker-compose.yaml to VM"
# Get the absolute path of the compose file
COMPOSE_PATH="$(realpath ai/docker-compose.yaml)"
# Since we use DOCKER_HOST via SSH, we can use 'docker compose' directly if wired correctly,
# but it's safer to copy the file and run it there.
cat "$COMPOSE_PATH" | rootd sh $BOX -- ssh $DOCKER_HOST "cat > ~/ai-stack/docker-compose.yaml"

step "Starting AI Stack (Ollama + Open WebUI)"
rootd sh $BOX -- docker compose -f ~/ai-stack/docker-compose.yaml up -d

step "Waiting for Ollama to be ready..."
sleep 10

step "Downloading default model: Llama 3.1 (8B)"
rootd sh $BOX -- docker exec ollama ollama pull llama3.1

step "Deployment complete!"
VM_IP=$(echo $DOCKER_HOST | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
echo -e "\n${G}AI is now running at:${N}"
echo -e "Dashboard: ${C}http://$VM_IP:3000${N} (via Tailscale)"
echo -e "Ollama API: ${C}http://$VM_IP:11434${N}"
echo -e "\nNote: The first login to Open WebUI will allow you to create the admin account."
