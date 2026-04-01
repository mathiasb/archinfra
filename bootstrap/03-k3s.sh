#!/bin/bash
# k3s: install, kubeconfig, PV redirect
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CONFIG_DIR}/config.sh"

echo "--- k3s config ---"
sudo mkdir -p /etc/rancher/k3s
sudo cp "${INFRA_DIR}/scripts/k3s-config.yaml" /etc/rancher/k3s/config.yaml

echo "--- k3s install ---"
if ! command -v k3s &>/dev/null; then
  curl -sfL https://get.k3s.io | sh -s - \
    --write-kubeconfig-mode 644 \
    --disable traefik \
    --disable servicelb \
    --node-name ${HOSTNAME}
else
  echo "k3s already installed, skipping"
fi

echo "--- kubeconfig ---"
mkdir -p ~/.kube
if [ ! -f ~/.kube/config ]; then
  sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
  sudo chown mathias:mathias ~/.kube/config
else
  echo "kubeconfig already set up, skipping"
fi

echo "--- Waiting for k3s to be ready ---"
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  echo "  waiting for node..."
  sleep 5
done
echo "k3s node Ready"

echo "--- PV redirect to fast disk ---"
kubectl patch configmap local-path-config \
  -n kube-system \
  --type merge \
  -p '{"data":{"config.json":"{\"nodePathMap\":[{\"node\":\"DEFAULT_PATH_FOR_NON_LISTED_NODES\",\"paths\":[\"/data/k3s/pv\"]}]}"}}'
kubectl rollout restart deployment/local-path-provisioner -n kube-system

echo "--- k3s done ---"
