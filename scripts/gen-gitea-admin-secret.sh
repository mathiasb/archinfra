#!/usr/bin/env bash
# Generate the SOPS-encrypted gitea-admin-secret.
#
# Prompts for the desired admin password, encrypts it with the repo's age
# recipient (.sops.yaml), and writes k3s/apps/gitea/admin-secret.enc.yaml.
#
# Usage:
#   bash scripts/gen-gitea-admin-secret.sh
#
# Requires: sops, age. Install with: sudo pacman -S sops age

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/k3s/apps/gitea/admin-secret.enc.yaml"

# Verify tooling
for tool in sops age base64; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: $tool not installed. Install with: sudo pacman -S sops age"
    exit 1
  fi
done

# Verify .sops.yaml is in scope
if [ ! -f "$REPO_ROOT/.sops.yaml" ]; then
  echo "ERROR: $REPO_ROOT/.sops.yaml not found — sops won't know which key to use"
  exit 1
fi

# Prompt for password silently
printf 'Gitea admin password (mathias): '
stty -echo
IFS= read -r password
stty echo
printf '\n'

[ -n "$password" ] || { echo "Empty password — abort."; exit 1; }

printf 'Confirm password: '
stty -echo
IFS= read -r confirm
stty echo
printf '\n'

[ "$password" = "$confirm" ] || { echo "Passwords do not match — abort."; exit 1; }

# Build base64-encoded values to avoid YAML escaping pitfalls with special chars
USERNAME_B64=$(printf '%s' 'mathias' | base64 -w0)
PASSWORD_B64=$(printf '%s' "$password" | base64 -w0)

# Use mktemp to avoid leaving the plaintext on disk longer than necessary
TMP=$(mktemp --suffix=.yaml)
trap '
  if [ -n "${TMP:-}" ] && [ -f "$TMP" ]; then
    shred -u "$TMP" 2>/dev/null || rm -f "$TMP"
  fi
  unset password confirm PASSWORD_B64
' EXIT

# Important: chmod 600 BEFORE writing to mktemp output (mktemp is already 600)
cat > "$TMP" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitea-admin-secret
  namespace: gitea
type: Opaque
data:
  username: ${USERNAME_B64}
  password: ${PASSWORD_B64}
EOF

# sops auto-detects yaml from file extension and reads .sops.yaml for recipients
( cd "$REPO_ROOT" && sops --encrypt "$TMP" ) > "$OUT"

echo "✓ wrote $OUT"
echo "  to inspect:  sops --decrypt $OUT  (requires age private key from cluster)"
echo "  to apply:    sops --decrypt $OUT | kubectl apply -f -  (or commit + Flux applies it)"
