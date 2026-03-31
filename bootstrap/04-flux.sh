#!/bin/bash
# Flux: install CLI, bootstrap to Gitea
set -euo pipefail

echo "--- Flux CLI ---"
if ! command -v flux &>/dev/null; then
  curl -s https://fluxcd.io/install.sh | sudo bash
else
  echo "Flux CLI already installed, skipping"
fi

echo "--- Gitea token ---"
echo ""
echo "You need a Gitea access token with repo read/write permissions."
echo "Create one at: https://gitea.d-ma.be/user/settings/applications"
echo ""
read -rsp "Gitea token: " GITEA_TOKEN
echo ""

echo "--- Bootstrap Flux to Gitea ---"
if ! flux get sources git 2>/dev/null | grep -q "flux-system"; then
  flux bootstrap git \
    --url=https://gitea.d-ma.be/mathias/infra \
    --branch=main \
    --path=k3s/flux \
    --username=mathias \
    --password="${GITEA_TOKEN}" \
    --token-auth=true
else
  echo "Flux already bootstrapped, skipping"
fi

echo "--- Configuring git credentials ---"
git config --global credential.helper store
cd ~/infra
git remote set-url origin \
  "https://mathias:${GITEA_TOKEN}@gitea.d-ma.be/mathias/infra.git"

echo "--- Flux done ---"
