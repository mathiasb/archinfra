#!/bin/bash
# Deploy all k3s applications
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "--- Helm repos ---"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack      https://charts.jetstack.io
helm repo add gitea-charts  https://dl.gitea.com/charts/
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo "--- NVIDIA device plugin ---"
kubectl apply -f "${INFRA_DIR}/k3s/system/nvidia-device-plugin.yaml"

echo "--- Waiting for GPU to be allocatable ---"
until kubectl get node koala -o jsonpath='{.status.allocatable}' | grep -q "nvidia.com/gpu"; do
  echo "  waiting for GPU..."
  sleep 10
done
echo "GPU allocatable"

echo "--- ingress-nginx ---"
if ! helm status ingress-nginx -n ingress-nginx &>/dev/null; then
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http=30080 \
    --set controller.service.nodePorts.https=30443
else
  echo "ingress-nginx already installed, skipping"
fi

echo "--- cert-manager ---"
if ! helm status cert-manager -n cert-manager &>/dev/null; then
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true
  kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/instance=cert-manager \
    -n cert-manager --timeout=120s
else
  echo "cert-manager already installed, skipping"
fi

echo "--- ClusterIssuer ---"
kubectl apply -f "${INFRA_DIR}/k3s/system/clusterissuer.yaml"

echo "--- Gitea ---"
if ! helm status gitea -n gitea &>/dev/null; then
  helm install gitea gitea-charts/gitea \
    --namespace gitea \
    --create-namespace \
    --values "${INFRA_DIR}/k3s/apps/gitea/values.yaml"
  kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/name=gitea \
    -n gitea --timeout=300s
  # Patch ingress class
  kubectl patch ingress gitea -n gitea \
    --type merge -p '{"spec":{"ingressClassName":"nginx"}}'
else
  echo "Gitea already installed, skipping"
fi

echo "--- AI stack ---"
kubectl apply -f "${INFRA_DIR}/k3s/apps/ai-stack/"

echo "--- Monitoring ---"
kubectl create namespace monitoring 2>/dev/null || true
if ! helm status kube-prometheus-stack -n monitoring &>/dev/null; then
  echo ""
  read -rsp "Grafana admin password: " GRAFANA_PASS
  echo ""
  kubectl create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="${GRAFANA_PASS}" \
    --namespace monitoring
  helm install kube-prometheus-stack \
    prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --values "${INFRA_DIR}/k3s/apps/monitoring/values.yaml"
else
  echo "kube-prometheus-stack already installed, skipping"
fi

kubectl apply -f "${INFRA_DIR}/k3s/apps/monitoring/dcgm-exporter.yaml"

# Prometheus scrape config
kubectl create secret generic additional-scrape-configs \
  --from-file=prometheus-additional.yaml="${INFRA_DIR}/k3s/apps/monitoring/prometheus-scrape-config.yaml" \
  --namespace monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

echo "--- Prometheus NodePort ---"
kubectl patch svc kube-prometheus-stack-prometheus \
  -n monitoring \
  --type merge \
  -p '{"spec":{"type":"NodePort","ports":[{"port":9090,"nodePort":31900}]}}' \
  2>/dev/null || true

echo "--- update-models symlink ---"
sudo ln -sf /home/mathias/infra/scripts/update-models.sh \
  /usr/local/bin/update-models 2>/dev/null || true

echo "--- Apps deployed ---"
echo ""
echo "Manual steps still needed:"
echo "  1. Set Gitea admin password via: kubectl exec -n gitea deploy/gitea -- gitea admin user change-password --username mathias --password ..."
echo "  2. Import bare repos to Gitea"
echo "  3. Add NPM proxy hosts on piguard for each service"
echo "  4. Add koala models to LiteLLM config on piguard"
