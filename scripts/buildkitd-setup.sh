#!/bin/bash
# Install and configure BuildKit daemon on koala.
# Run as root. Idempotent — safe to re-run.
set -euo pipefail

BUILDKIT_VERSION="v0.21.0"
BUILDKIT_URL="https://github.com/moby/buildkit/releases/download/${BUILDKIT_VERSION}/buildkit-${BUILDKIT_VERSION}.linux-amd64.tar.gz"
INSTALL_DIR="/usr/local"

# --- Binary ---
if [[ "$(buildkitd --version 2>/dev/null | awk '{print $3}')" == "${BUILDKIT_VERSION}" ]]; then
  echo "buildkitd ${BUILDKIT_VERSION} already installed, skipping"
else
  echo "=== Installing BuildKit ${BUILDKIT_VERSION} ==="
  curl -fsSL "${BUILDKIT_URL}" -o /tmp/buildkit.tar.gz
  tar -xz -C "${INSTALL_DIR}" -f /tmp/buildkit.tar.gz
  rm /tmp/buildkit.tar.gz
  echo "Installed: $(buildkitd --version)"
fi

# --- Config ---
mkdir -p /etc/buildkit
cat > /etc/buildkit/buildkitd.toml << 'EOF'
[worker.containerd]
  enabled = false

[worker.oci]
  enabled = true

[registry."gitea.d-ma.be"]
  http = false
  insecure = false
EOF
echo "Config written to /etc/buildkit/buildkitd.toml"

# --- Systemd unit ---
# --- Buildkit group (allows runner user to access socket without root) ---
# mathias runs act_runner — it needs socket access without root
groupadd -f buildkit
usermod -aG buildkit mathias
echo "Group 'buildkit' created, mathias added"
echo "NOTE: restart act_runner after this script: systemctl restart act_runner"

cat > /etc/systemd/system/buildkitd.service << 'EOF'
[Unit]
Description=BuildKit daemon
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/buildkitd --config /etc/buildkit/buildkitd.toml --group buildkit
Restart=on-failure
LimitNOFILE=1048576
LimitNPROC=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now buildkitd
echo "buildkitd enabled and started"

# --- Directory permissions (tmpfiles.d) ---
# /run/buildkit/ is created root-only by default; the buildkit group needs
# execute permission on the directory to reach the socket inside it.
cp "$(dirname "${BASH_SOURCE[0]}")/buildkitd-tmpfiles.conf" \
  /etc/tmpfiles.d/buildkitd.conf
systemd-tmpfiles --create /etc/tmpfiles.d/buildkitd.conf
echo "tmpfiles.d entry installed — /run/buildkit/ will be group-accessible on boot"
echo "Socket permissions:"
ls -la /run/buildkit/

# --- Registry auth ---
# Requires REGISTRY_CREDS env var in the format "mathias:<token>"
# (same value as the REGISTRY_CREDS Gitea org secret)
if [[ -z "${REGISTRY_CREDS:-}" ]]; then
  echo ""
  echo "REGISTRY_CREDS not set — skipping registry auth setup."
  echo "To configure manually:"
  echo "  REGISTRY_CREDS='mathias:<token>' $0"
  echo "Or write /root/.docker/config.json manually:"
  echo '  {"auths":{"gitea.d-ma.be":{"auth":"<base64 of mathias:token>"}}}'
else
  mkdir -p /root/.docker
  AUTH_B64=$(echo -n "${REGISTRY_CREDS}" | base64 -w0)
  cat > /root/.docker/config.json << DOCKEREOF
{
  "auths": {
    "gitea.d-ma.be": {
      "auth": "${AUTH_B64}"
    }
  }
}
DOCKEREOF
  chmod 600 /root/.docker/config.json
  echo "Registry auth written to /root/.docker/config.json"
fi

# --- Claude CLI ---
if command -v claude &>/dev/null; then
  echo "claude already installed at $(command -v claude)"
else
  echo "=== Installing Claude CLI ==="
  npm install -g @anthropic-ai/claude-code
  echo "Installed: $(claude --version)"
fi

echo ""
echo "=== BuildKit setup complete ==="
echo ""
echo "Remaining manual steps:"
echo "  1. Set /etc/environment with API keys (see docs/cd-pipeline.md#environment-variables)"
echo "     Required: ANTHROPIC_API_KEY, DMABE_LLMAPI_KEY, GEMINI_API_KEY, MISTRAL_API_KEY, BERGET_API_KEY"
echo "     Values in 1Password."
echo "  2. Verify: systemctl status buildkitd"
