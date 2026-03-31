#!/bin/bash
# Usage: update-models.sh
# Rebuilds llama-swap configmap from models.yml and triggers a rolling restart
set -euo pipefail

MODELS_YML=/data/projects/gocrwl/llama-swap/models.yml
CONFIGMAP_YAML=~/infra/k3s/apps/ai-stack/llama-swap-configmap.yaml
INFRA_MODELS=~/infra/k3s/apps/ai-stack/models.yml

echo "=== Rebuilding configmap from ${MODELS_YML} ==="

cat > "${CONFIGMAP_YAML}" << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: llama-swap-config
  namespace: ai-stack
data:
  models.yml: |
EOF

sed 's/^/    /' "${MODELS_YML}" >> "${CONFIGMAP_YAML}"

# Sync models.yml copy in infra repo
cp "${MODELS_YML}" "${INFRA_MODELS}"

echo "=== Applying configmap ==="
kubectl apply -f "${CONFIGMAP_YAML}"

echo "=== Restarting llama-swap (deleting pod to release GPU) ==="
kubectl delete pod -n ai-stack \
  $(kubectl get pods -n ai-stack -l app=llama-swap --no-headers | awk '{print $1}') \
  2>/dev/null || true

echo "=== Waiting for new pod ==="
kubectl rollout status deployment/llama-swap -n ai-stack --timeout=120s

echo "=== Verifying models ==="
sleep 5
curl -s http://10.0.1.20:31234/v1/models | python3 -m json.tool | grep '"id"'

echo "=== Committing to infra repo ==="
cd ~/infra
git add k3s/apps/ai-stack/
git commit -m "chore: update llama-swap models" && git push origin main || true

echo "=== Done ==="
