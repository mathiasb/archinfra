#!/bin/bash
# Fix ImagePullBackOff for gitea.d-ma.be on koala.
# containerd v2.x ignores registries.yaml mirrors — use hosts.toml instead.
# Mirror target: http://127.0.0.1:30300 (gitea-http-nodeport, bypasses ingress)
# Run as root: sudo bash scripts/fix-containerd-registry.sh
set -euo pipefail

CONFIG_TOML="/var/lib/rancher/k3s/agent/etc/containerd/config.toml"

echo "=== Step 1: find config_path ==="
CERT_DIR=$(grep -oP 'config_path\s*=\s*"\K[^"]+' "${CONFIG_TOML}")
if [[ -z "${CERT_DIR}" ]]; then
  echo "ERROR: config_path not found in ${CONFIG_TOML}"
  cat "${CONFIG_TOML}"
  exit 1
fi
echo "config_path = ${CERT_DIR}"

echo ""
echo "=== Step 2: write hosts.toml ==="
mkdir -p "${CERT_DIR}/gitea.d-ma.be"
cat > "${CERT_DIR}/gitea.d-ma.be/hosts.toml" << 'EOF'
server = "https://gitea.d-ma.be"

[host."http://127.0.0.1:30300"]
  capabilities = ["pull", "resolve"]
  [host."http://127.0.0.1:30300".header]
    Authorization = ["Basic bWF0aGlhczo3MzZhOGMzNmFkY2M2ZWNiNDFmZmY1NmU1YWU0ZDBlYjMxMDVhNjcw"]
EOF
echo "Written: ${CERT_DIR}/gitea.d-ma.be/hosts.toml"
cat "${CERT_DIR}/gitea.d-ma.be/hosts.toml"

echo ""
echo "=== Step 3: trim registries.yaml (remove deprecated mirror/config for gitea) ==="
cat > /etc/rancher/k3s/registries.yaml << 'EOF'
mirrors:
  "localhost:5000":
    endpoint:
      - "http://localhost:5000"
configs:
  "localhost:5000":
    tls:
      insecure_skip_verify: true
EOF
echo "registries.yaml updated"

echo ""
echo "=== Step 4: restart k3s ==="
systemctl restart k3s
echo "k3s restarted — waiting 30s for pod to reschedule..."
sleep 30

echo ""
echo "=== Step 5: check supervisor pod ==="
kubectl get pod -n supervisor -o wide
echo ""
kubectl describe pod -n supervisor 2>/dev/null | grep -A5 "Events:" | tail -10 || true

echo ""
echo "=== Done ==="
