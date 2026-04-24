#!/bin/bash
# Deploy LiteLLM config to piguard and restart
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.yaml"
PIGUARD_HOST="piguard"
PIGUARD_CONFIG_DIR="/home/mathias/litellm-infra"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: ${CONFIG} not found. Run 'task model:generate' first."
    exit 1
fi

echo "=== Deploying LiteLLM config to ${PIGUARD_HOST} ==="
scp "$CONFIG" "${PIGUARD_HOST}:${PIGUARD_CONFIG_DIR}/config.yaml"

echo "=== Restarting LiteLLM ==="
ssh "$PIGUARD_HOST" "cd ${PIGUARD_CONFIG_DIR} && docker compose restart litellm"

echo "=== Waiting for LiteLLM to be ready ==="
for i in $(seq 1 30); do
    if ssh "$PIGUARD_HOST" "curl -sf http://localhost:4000/health" > /dev/null 2>&1; then
        echo "LiteLLM is healthy."
        exit 0
    fi
    sleep 2
done

echo "WARNING: LiteLLM did not become healthy within 60s. Check piguard."
exit 1
