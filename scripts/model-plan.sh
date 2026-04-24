#!/usr/bin/env bash
set -euo pipefail

# model-plan.sh — dry-run showing what model:apply would do
# Compares models.yml desired state against live state and generated configs.
# No side effects — read-only.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_YML="$REPO_ROOT/models.yml"

SWAP_CONFIGMAP="$REPO_ROOT/k3s/apps/ai-stack/llama-swap-configmap.yaml"
LITELLM_CONFIG="$REPO_ROOT/litellm/config.yaml"
MODELS_MD="$REPO_ROOT/MODELS.md"

GENERATED_FILES=("$SWAP_CONFIGMAP" "$LITELLM_CONFIG" "$MODELS_MD")

if [[ ! -f "$MODELS_YML" ]]; then
  echo "ERROR: models.yml not found at $MODELS_YML" >&2
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required (brew install yq)" >&2
  exit 1
fi

changes_needed=0

echo ""
echo "=== Model Plan (dry-run) ==="

# ─── 1. Config freshness ─────────────────────────────────────────
echo ""
echo "── config changes ──"
echo ""

# Save current generated files, run generate, diff, restore
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Back up current generated files
for f in "${GENERATED_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    cp "$f" "$tmpdir/$(basename "$f")"
  fi
done
# Also back up the intermediate models.yml used by configmap generation
swap_config="$REPO_ROOT/k3s/apps/ai-stack/models.yml"
if [[ -f "$swap_config" ]]; then
  cp "$swap_config" "$tmpdir/swap-models.yml"
fi

# Run generate silently
if "$SCRIPT_DIR/model-generate.sh" &>/dev/null; then
  config_dirty=false

  # Check each generated file
  for f in "${GENERATED_FILES[@]}"; do
    fname="$(basename "$f")"
    label="$fname"
    case "$fname" in
      llama-swap-configmap.yaml) label="llama-swap ConfigMap" ;;
      config.yaml)              label="LiteLLM config" ;;
      MODELS.md)                label="MODELS.md docs" ;;
    esac

    if [[ -f "$tmpdir/$fname" ]]; then
      if ! diff -q "$tmpdir/$fname" "$f" &>/dev/null; then
        printf "  %-8s %s (models.yml newer than generated config)\n" "REGEN" "$label"
        config_dirty=true
        changes_needed=1
      else
        printf "  %-8s %s\n" "ok" "$label"
      fi
    else
      printf "  %-8s %s (file did not exist, now generated)\n" "NEW" "$label"
      config_dirty=true
      changes_needed=1
    fi
  done

  # Restore originals
  for f in "${GENERATED_FILES[@]}"; do
    fname="$(basename "$f")"
    if [[ -f "$tmpdir/$fname" ]]; then
      cp "$tmpdir/$fname" "$f"
    else
      rm -f "$f"
    fi
  done
  if [[ -f "$tmpdir/swap-models.yml" ]]; then
    cp "$tmpdir/swap-models.yml" "$swap_config"
  elif [[ -f "$swap_config" ]] && [[ ! -f "$tmpdir/swap-models.yml" ]]; then
    rm -f "$swap_config"
  fi
else
  echo "  ERROR    model-generate.sh failed — cannot check config freshness"
  # Restore originals on failure too
  for f in "${GENERATED_FILES[@]}"; do
    fname="$(basename "$f")"
    if [[ -f "$tmpdir/$fname" ]]; then
      cp "$tmpdir/$fname" "$f"
    fi
  done
  if [[ -f "$tmpdir/swap-models.yml" ]]; then
    cp "$tmpdir/swap-models.yml" "$swap_config"
  fi
fi

# ─── 2. Missing models on koala ──────────────────────────────────
echo ""
echo "── koala actions ──"
echo ""

koala_host=$(yq '.hardware.koala.host' "$MODELS_YML")
model_path=$(yq '.hardware.koala.model_path' "$MODELS_YML")

koala_reachable=true
koala_files=""
if ! koala_files=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "mathias@koala" "ls '$model_path/'" 2>&1); then
  echo "  SKIP     koala unreachable via SSH — cannot verify model files"
  koala_reachable=false
fi

if [[ "$koala_reachable" == "true" ]]; then
  while IFS= read -r slot; do
    slot_name="${slot#koala/}"
    repo=$(yq ".slots[\"$slot\"].model" "$MODELS_YML")
    file=$(yq ".slots[\"$slot\"].file" "$MODELS_YML")

    # Build expected filename: repo slashes→underscores, then _filename
    repo_flat="$(echo "$repo" | tr '/' '_')"
    expected_file="${repo_flat}_${file}"

    if echo "$koala_files" | grep -q "^${expected_file}$"; then
      printf "  %-8s %s (file exists)\n" "ok" "$slot"
    else
      printf "  %-8s %s: %s (%s)\n" "PULL" "$slot" "$repo" "$file"
      changes_needed=1
    fi
  done < <(yq '.slots | keys | .[] | select(test("^koala/"))' "$MODELS_YML")
fi

# ─── 3. Missing models on iguana ─────────────────────────────────
echo ""
echo "── iguana actions ──"
echo ""

iguana_reachable=true
iguana_models=""
if ! iguana_models=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "mathias@iguana" "ollama list" 2>&1); then
  echo "  SKIP     iguana unreachable via SSH — cannot verify models"
  iguana_reachable=false
fi

if [[ "$iguana_reachable" == "true" ]]; then
  while IFS= read -r slot; do
    slot_name="${slot#iguana/}"
    model=$(yq ".slots[\"$slot\"].model" "$MODELS_YML")
    platform=$(yq ".slots[\"$slot\"].platform // \"ollama\"" "$MODELS_YML")

    # Skip non-ollama platforms
    if [[ "$platform" != "ollama" ]]; then
      printf "  %-8s %s (%s — skipped)\n" "skip" "$slot" "$platform"
      continue
    fi

    # Strip :tag for matching
    match_name="${model%%:*}"

    if echo "$iguana_models" | awk '{print $1}' | grep -qi "^${match_name}"; then
      printf "  %-8s %s (installed)\n" "ok" "$slot"
    else
      printf "  %-8s %s: ollama pull %s\n" "PULL" "$slot" "$model"
      changes_needed=1
    fi
  done < <(yq '.slots | keys | .[] | select(test("^iguana/"))' "$MODELS_YML")
fi

# ─── 4. ConfigMap drift ─────────────────────────────────────────
echo ""
echo "── deployment actions ──"
echo ""

# Compare generated ConfigMap against live cluster
live_cm=""
cm_reachable=true
if ! live_cm=$(kubectl get configmap llama-swap-config -n ai-stack -o yaml 2>&1); then
  echo "  SKIP     kubectl unreachable — cannot verify ConfigMap drift"
  cm_reachable=false
fi

if [[ "$cm_reachable" == "true" ]]; then
  # Extract just the data.models.yml content from both for comparison
  live_data=$(echo "$live_cm" | yq '.data["models.yml"]' 2>/dev/null || echo "")
  local_data=""
  if [[ -f "$SWAP_CONFIGMAP" ]]; then
    local_data=$(yq '.data["models.yml"]' "$SWAP_CONFIGMAP" 2>/dev/null || echo "")
  fi

  if [[ -z "$local_data" ]]; then
    printf "  %-8s ConfigMap — local file missing, cannot compare\n" "WARN"
  elif [[ -z "$live_data" ]]; then
    printf "  %-8s ConfigMap — not found in cluster, needs initial apply\n" "APPLY"
    changes_needed=1
  elif [[ "$live_data" != "$local_data" ]]; then
    printf "  %-8s ConfigMap differs from live cluster\n" "APPLY"
    changes_needed=1
  else
    printf "  %-8s ConfigMap matches live cluster\n" "ok"
  fi
fi

# LiteLLM — can't easily verify remotely
printf "  %-8s LiteLLM config differs from piguard (cannot verify — manual check)\n" "DEPLOY"

# ─── Summary ─────────────────────────────────────────────────────
echo ""
if [[ "$changes_needed" -eq 0 ]]; then
  echo "Everything in sync. No changes needed."
else
  echo "Run 'task model:apply' to execute these changes."
fi
echo ""

exit 0
