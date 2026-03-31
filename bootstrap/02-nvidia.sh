#!/bin/bash
# NVIDIA: containerd config for k3s, CDI spec
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CONFIG_DIR}/config.sh"

echo "--- NVIDIA containerd config ---"
if ! sudo grep -q "nvidia" /var/lib/rancher/k3s/agent/etc/containerd/config.toml 2>/dev/null; then
  sudo mkdir -p /var/lib/rancher/k3s/agent/etc/containerd
  sudo nvidia-ctk runtime configure --runtime=containerd \
    --config=/var/lib/rancher/k3s/agent/etc/containerd/config.toml
  sudo cp /etc/containerd/conf.d/99-nvidia.toml \
    /var/lib/rancher/k3s/agent/etc/containerd/99-nvidia.toml
  echo "NVIDIA containerd config applied"
else
  echo "NVIDIA containerd already configured, skipping"
fi

echo "--- CDI spec ---"
if [ ! -f /etc/cdi/nvidia.yaml ]; then
  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
else
  echo "CDI spec already exists, skipping"
fi

echo "--- nvidia-persistenced ---"
sudo systemctl enable --now nvidia-persistenced
sudo systemctl enable nvidia-hibernate nvidia-resume nvidia-suspend

echo "--- NVIDIA setup done ---"
echo "NOTE: nvidia-smi must work before continuing. If driver not loaded, reboot first."
nvidia-smi | head -4
