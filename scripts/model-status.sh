#!/usr/bin/env bash
set -euo pipefail

# model-status.sh — compare declared slots in models.yml against live state
# on koala (llama-swap) and iguana (ollama).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODELS_YML="${SCRIPT_DIR}/../models.yml"

if [[ ! -f "$MODELS_YML" ]]; then
  echo "ERROR: models.yml not found at $MODELS_YML" >&2
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required but not found" >&2
  exit 1
fi

# ── Read hardware info ────────────────────────────────────────

KOALA_HOST=$(yq '.hardware.koala.host' "$MODELS_YML")
KOALA_PORT=$(yq '.hardware.koala.llama_swap_port' "$MODELS_YML")
IGUANA_HOST=$(yq '.hardware.iguana.host' "$MODELS_YML")

# ── Query koala (llama-swap) ──────────────────────────────────

koala_models=""
koala_err=""
if koala_json=$(curl -sf --connect-timeout 5 "http://${KOALA_HOST}:${KOALA_PORT}/v1/models" 2>&1); then
  koala_models=$(echo "$koala_json" | jq -r '.data[].id' 2>/dev/null || true)
else
  koala_err="unreachable"
fi

# ── Query iguana (ollama) ─────────────────────────────────────

iguana_models=""
iguana_err=""
if iguana_raw=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "mathias@iguana" "ollama list" 2>&1); then
  iguana_models="$iguana_raw"
else
  iguana_err="unreachable"
fi

# ── Output ────────────────────────────────────────────────────

FMT="%-22s %-42s %s\n"

echo ""
echo "=== Model Status ==="

# ── koala ─────────────────────────────────────────────────────

echo ""
echo "── koala (llama-swap) ──"
echo ""

if [[ -n "$koala_err" ]]; then
  echo "  ERROR: koala ($KOALA_HOST:$KOALA_PORT) is $koala_err"
else
  printf "$FMT" "SLOT" "MODEL" "STATUS"
  printf "$FMT" "----" "-----" "------"

  while IFS= read -r slot; do
    slot_name="${slot#koala/}"
    model=$(yq ".slots[\"$slot\"].model" "$MODELS_YML")
    litellm_name=$(yq ".slots[\"$slot\"].litellm_name" "$MODELS_YML")

    # llama-swap knows the model by litellm_name with "koala/" stripped
    swap_name="${litellm_name#koala/}"

    # Truncate display model name for readability
    display_model="$model"
    if [[ ${#display_model} -gt 40 ]]; then
      display_model="${display_model:0:37}..."
    fi

    status="MISSING"
    if echo "$koala_models" | grep -qi "^${swap_name}$"; then
      status="ok"
    fi

    printf "$FMT" "$slot_name" "$display_model" "$status"
  done < <(yq '.slots | keys | .[] | select(test("^koala/"))' "$MODELS_YML")
fi

# ── iguana ────────────────────────────────────────────────────

echo ""
echo "── iguana (ollama) ──"
echo ""

if [[ -n "$iguana_err" ]]; then
  echo "  ERROR: iguana ($IGUANA_HOST) is $iguana_err"
else
  printf "$FMT" "SLOT" "MODEL" "STATUS"
  printf "$FMT" "----" "-----" "------"

  # Collect declared iguana model names for untracked detection
  declared_iguana_models=()

  while IFS= read -r slot; do
    slot_name="${slot#iguana/}"
    model=$(yq ".slots[\"$slot\"].model" "$MODELS_YML")
    platform=$(yq ".slots[\"$slot\"].platform // \"ollama\"" "$MODELS_YML")

    # Non-ollama platforms: show platform name instead of ok/MISSING
    if [[ "$platform" != "ollama" ]]; then
      printf "$FMT" "$slot_name" "$model" "$platform"
      continue
    fi

    declared_iguana_models+=("$model")

    # Strip :tag for matching
    match_name="${model%%:*}"

    status="MISSING"
    if echo "$iguana_models" | awk '{print $1}' | grep -qi "^${match_name}"; then
      status="ok"
    fi

    printf "$FMT" "$slot_name" "$model" "$status"
  done < <(yq '.slots | keys | .[] | select(test("^iguana/"))' "$MODELS_YML")

  # ── Untracked models on iguana ──────────────────────────────

  untracked=""
  while IFS=$'\t' read -r name rest; do
    # Skip header line
    [[ "$name" == "NAME" ]] && continue
    [[ -z "$name" ]] && continue

    # Check if this model matches any declared model
    found=false
    for declared in "${declared_iguana_models[@]}"; do
      # Strip :tag from both sides for comparison
      declared_base="${declared%%:*}"
      name_base="${name%%:*}"
      if [[ "${name_base,,}" == "${declared_base,,}" ]]; then
        found=true
        break
      fi
    done

    if [[ "$found" == "false" ]]; then
      # Extract size from ollama list output (whitespace-separated fields)
      size=$(echo "$rest" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+[GMKT]B$/) print $i}')
      if [[ -n "$size" ]]; then
        untracked+="  UNTRACKED: ${name} (${size})"$'\n'
      else
        untracked+="  UNTRACKED: ${name}"$'\n'
      fi
    fi
  done < <(echo "$iguana_models" | tr -s ' ' '\t')

  if [[ -n "$untracked" ]]; then
    echo ""
    echo "── iguana: models not in any slot ──"
    echo ""
    printf "%s" "$untracked"
  fi
fi

echo ""
