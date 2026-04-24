#!/usr/bin/env bash
set -euo pipefail

# model-apply.sh — provision models and deploy configs from models.yml
# Pulls missing models, applies k8s configs, deploys to piguard.
# Destructive operations (ConfigMap apply, LiteLLM deploy) require confirmation.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_YML="$REPO_ROOT/models.yml"

SWAP_CONFIGMAP="$REPO_ROOT/k3s/apps/ai-stack/llama-swap-configmap.yaml"

if [[ ! -f "$MODELS_YML" ]]; then
  echo "ERROR: models.yml not found at $MODELS_YML" >&2
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required (brew install yq)" >&2
  exit 1
fi

# ── Helpers ──────────────────────────────────────────────────────

confirm() {
  local prompt="$1"
  echo ""
  read -p "⚠️  ${prompt} [y/N] " -r
  [[ $REPLY =~ ^[Yy]$ ]]
}

# ── Read hardware info ───────────────────────────────────────────

KOALA_HOST=$(yq '.hardware.koala.host' "$MODELS_YML")
KOALA_PORT=$(yq '.hardware.koala.llama_swap_port' "$MODELS_YML")
KOALA_MODEL_PATH=$(yq '.hardware.koala.model_path' "$MODELS_YML")

# ─── Step 1: Regenerate configs ─────────────────────────────────

echo ""
echo "=== Step 1: Regenerate configs ==="
echo ""

if "$SCRIPT_DIR/model-generate.sh"; then
  echo ""
  echo "Configs regenerated successfully."
else
  echo "ERROR: model-generate.sh failed" >&2
  exit 1
fi

# ─── Step 2: Pull missing models on koala ────────────────────────

echo ""
echo "=== Step 2: Pull missing models on koala ==="
echo ""

koala_reachable=true
koala_files=""
if ! koala_files=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "mathias@koala" "ls '$KOALA_MODEL_PATH/'" 2>&1); then
  echo "ERROR: koala unreachable via SSH — skipping koala model pulls"
  koala_reachable=false
fi

if [[ "$koala_reachable" == "true" ]]; then
  while IFS= read -r slot; do
    repo=$(yq ".slots[\"$slot\"].model" "$MODELS_YML")
    file=$(yq ".slots[\"$slot\"].file" "$MODELS_YML")

    repo_flat="$(echo "$repo" | tr '/' '_')"
    expected_file="${repo_flat}_${file}"

    if echo "$koala_files" | grep -q "^${expected_file}$"; then
      echo "  ok       $slot (file exists)"
    else
      echo "  PULLING  $slot: $repo / $file"
      if ssh -o ConnectTimeout=5 "mathias@koala" "huggingface-cli download '$repo' '$file' --local-dir '$KOALA_MODEL_PATH/'" ; then
        echo "  done     $slot"
      else
        echo "  ERROR    $slot: download failed — continuing"
      fi
    fi
  done < <(yq '.slots | keys | .[] | select(test("^koala/"))' "$MODELS_YML")
fi

# ─── Step 3: Pull missing models on iguana ───────────────────────

echo ""
echo "=== Step 3: Pull missing models on iguana ==="
echo ""

iguana_reachable=true
iguana_models=""
if ! iguana_models=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "mathias@iguana" "ollama list" 2>&1); then
  echo "ERROR: iguana unreachable via SSH — skipping iguana model pulls"
  iguana_reachable=false
fi

if [[ "$iguana_reachable" == "true" ]]; then
  while IFS= read -r slot; do
    model=$(yq ".slots[\"$slot\"].model" "$MODELS_YML")
    platform=$(yq ".slots[\"$slot\"].platform // \"ollama\"" "$MODELS_YML")

    # Skip non-ollama platforms
    if [[ "$platform" != "ollama" ]]; then
      echo "  skip     $slot ($platform — not ollama)"
      continue
    fi

    # Strip :tag for matching
    match_name="${model%%:*}"

    if echo "$iguana_models" | awk '{print $1}' | grep -qi "^${match_name}"; then
      echo "  ok       $slot (installed)"
    else
      echo "  PULLING  $slot: ollama pull $model"
      if ssh -o ConnectTimeout=5 "mathias@iguana" "ollama pull '$model'" ; then
        echo "  done     $slot"
      else
        echo "  ERROR    $slot: pull failed — continuing"
      fi
    fi
  done < <(yq '.slots | keys | .[] | select(test("^iguana/"))' "$MODELS_YML")
fi

# ─── Step 4: Deploy llama-swap ConfigMap (APPROVAL GATE) ─────────

echo ""
echo "=== Step 4: Deploy llama-swap ConfigMap ==="
echo ""

cm_changed=false

if [[ ! -f "$SWAP_CONFIGMAP" ]]; then
  echo "ERROR: ConfigMap file not found at $SWAP_CONFIGMAP — skipping"
else
  live_cm=""
  cm_reachable=true
  if ! live_cm=$(kubectl get configmap llama-swap-config -n ai-stack -o yaml 2>&1); then
    echo "ERROR: kubectl unreachable — skipping ConfigMap deployment"
    cm_reachable=false
  fi

  if [[ "$cm_reachable" == "true" ]]; then
    # Compare data.models.yml content
    live_data=$(echo "$live_cm" | yq '.data["models.yml"]' 2>/dev/null || echo "")
    local_data=$(yq '.data["models.yml"]' "$SWAP_CONFIGMAP" 2>/dev/null || echo "")

    if [[ "$live_data" == "$local_data" ]]; then
      echo "ConfigMap is up to date — no changes needed."
    else
      cm_changed=true
      echo "ConfigMap differs from live cluster."

      if confirm "Apply ConfigMap and restart llama-swap pod? (affects live inference)"; then
        echo ""
        echo "  Applying ConfigMap..."
        kubectl apply -f "$SWAP_CONFIGMAP"

        echo "  Restarting llama-swap pod..."
        pod_name=$(kubectl get pods -n ai-stack -l app=llama-swap --no-headers | awk '{print $1}')
        if [[ -n "$pod_name" ]]; then
          kubectl delete pod -n ai-stack "$pod_name"
        else
          echo "  WARNING: no llama-swap pod found to restart"
        fi

        echo "  Waiting for rollout..."
        if kubectl rollout status deployment/llama-swap -n ai-stack --timeout=120s; then
          echo "  Rollout complete. Verifying endpoint..."
          sleep 5
          if curl -sf "http://${KOALA_HOST}:${KOALA_PORT}/v1/models" | python3 -m json.tool | grep '"id"'; then
            echo "  llama-swap verified and serving models."
          else
            echo "  WARNING: Could not verify llama-swap models endpoint."
          fi
        else
          echo "  ERROR: Rollout did not complete within 120s."
        fi
      else
        echo "Skipped ConfigMap deployment."
      fi
    fi
  fi
fi

# ─── Step 5: Deploy LiteLLM config (APPROVAL GATE) ──────────────

echo ""
echo "=== Step 5: Deploy LiteLLM config ==="
echo ""

if confirm "Deploy LiteLLM config to piguard? (affects all model routing)"; then
  echo ""
  if "$REPO_ROOT/litellm/deploy.sh"; then
    echo "LiteLLM deployed successfully."
  else
    echo "ERROR: LiteLLM deployment failed."
  fi
else
  echo "Skipped LiteLLM deployment."
fi

# ─── Step 6: Commit changes ─────────────────────────────────────

echo ""
echo "=== Step 6: Commit changes ==="
echo ""

cd "$REPO_ROOT"
git add k3s/apps/ai-stack/ litellm/config.yaml MODELS.md

if git diff --cached --quiet; then
  echo "No changes to commit."
else
  git commit -m "chore: update model configs from models.yml"
  echo "Changes committed."
fi

echo ""
echo "=== model-apply complete ==="
echo ""
