#!/usr/bin/env bash
set -euo pipefail

# model-generate.sh — generate all derived configs from models.yml
# Outputs:
#   k3s/apps/ai-stack/llama-swap-configmap.yaml  (K8s ConfigMap)
#   k3s/apps/ai-stack/models.yml                 (llama-swap config)
#   litellm/config.yaml                          (LiteLLM routing)
#   MODELS.md                                    (documentation)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_YML="$REPO_ROOT/models.yml"
SWAP_CONFIG="$REPO_ROOT/k3s/apps/ai-stack/models.yml"
SWAP_CONFIGMAP="$REPO_ROOT/k3s/apps/ai-stack/llama-swap-configmap.yaml"
LITELLM_CONFIG="$REPO_ROOT/litellm/config.yaml"
LITELLM_EXTRAS="$REPO_ROOT/litellm/extras.yaml"
MODELS_MD="$REPO_ROOT/MODELS.md"

# Check dependencies
if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required (brew install yq)" >&2
  exit 1
fi

echo "==> Reading $MODELS_YML"

# ─── Helper: build llama-server cmd for a koala slot ────────────
build_cmd() {
  local slot_key="$1"
  local model_path
  model_path="$(yq ".hardware.koala.model_path" "$MODELS_YML")"

  local repo file port
  repo="$(yq ".slots[\"$slot_key\"].model" "$MODELS_YML")"
  file="$(yq ".slots[\"$slot_key\"].file" "$MODELS_YML")"
  port="$(yq ".slots[\"$slot_key\"].port" "$MODELS_YML")"

  # Build model file path: repo slashes→underscores, then _filename
  local repo_flat
  repo_flat="$(echo "$repo" | tr '/' '_')"
  local model_file_path="${model_path}/${repo_flat}_${file}"

  # Start building cmd parts
  local parts=()
  parts+=("llama-server")
  parts+=("--model \"${model_file_path}\"")
  parts+=("--host 0.0.0.0")
  parts+=('--port ${PORT}')
  parts+=("--jinja")
  parts+=("--metrics")

  # --flash-attn (only when true)
  local flash_attn
  flash_attn="$(yq ".slots[\"$slot_key\"].params.flash_attn // false" "$MODELS_YML")"
  if [[ "$flash_attn" == "true" ]]; then
    parts+=("--flash-attn on")
  fi

  # --ctx-size
  local ctx_size
  ctx_size="$(yq ".slots[\"$slot_key\"].params.ctx_size" "$MODELS_YML")"
  if [[ "$ctx_size" != "null" ]]; then
    parts+=("--ctx-size ${ctx_size}")
  fi

  # -ngl / --n-gpu-layers
  local ngl
  ngl="$(yq ".slots[\"$slot_key\"].params.ngl" "$MODELS_YML")"
  if [[ "$ngl" != "null" ]]; then
    if [[ "$ngl" == "99" ]]; then
      parts+=("--n-gpu-layers 99")
    else
      parts+=("-ngl ${ngl}")
    fi
  fi

  # --batch-size
  local batch_size
  batch_size="$(yq ".slots[\"$slot_key\"].params.batch_size" "$MODELS_YML")"
  if [[ "$batch_size" != "null" ]]; then
    parts+=("--batch-size ${batch_size}")
  fi

  # --ubatch-size
  local ubatch_size
  ubatch_size="$(yq ".slots[\"$slot_key\"].params.ubatch_size" "$MODELS_YML")"
  if [[ "$ubatch_size" != "null" ]]; then
    parts+=("--ubatch-size ${ubatch_size}")
  fi

  # --parallel 1 (always, except when ngl=99 which matches current behavior)
  if [[ "$ngl" != "99" ]]; then
    parts+=("--parallel 1")
  fi

  # --kv-unified
  local kv_unified
  kv_unified="$(yq ".slots[\"$slot_key\"].params.kv_unified // false" "$MODELS_YML")"
  if [[ "$kv_unified" == "true" ]]; then
    parts+=("--kv-unified")
  fi

  # --cache-reuse
  local cache_reuse
  cache_reuse="$(yq ".slots[\"$slot_key\"].params.cache_reuse" "$MODELS_YML")"
  if [[ "$cache_reuse" != "null" ]]; then
    parts+=("--cache-reuse ${cache_reuse}")
  fi

  # --cache-type-k
  local cache_type_k
  cache_type_k="$(yq ".slots[\"$slot_key\"].params.cache_type_k" "$MODELS_YML")"
  if [[ "$cache_type_k" != "null" ]]; then
    parts+=("--cache-type-k ${cache_type_k}")
  fi

  # --cache-type-v
  local cache_type_v
  cache_type_v="$(yq ".slots[\"$slot_key\"].params.cache_type_v" "$MODELS_YML")"
  if [[ "$cache_type_v" != "null" ]]; then
    parts+=("--cache-type-v ${cache_type_v}")
  fi

  # Sampling params (optional)
  local temp top_p top_k repeat_penalty
  temp="$(yq ".slots[\"$slot_key\"].sampling.temp" "$MODELS_YML")"
  top_p="$(yq ".slots[\"$slot_key\"].sampling.top_p" "$MODELS_YML")"
  top_k="$(yq ".slots[\"$slot_key\"].sampling.top_k" "$MODELS_YML")"
  repeat_penalty="$(yq ".slots[\"$slot_key\"].sampling.repeat_penalty" "$MODELS_YML")"

  [[ "$temp" != "null" ]] && parts+=("--temp ${temp}")
  [[ "$top_p" != "null" ]] && parts+=("--top-p ${top_p}")
  [[ "$top_k" != "null" ]] && parts+=("--top-k ${top_k}")
  [[ "$repeat_penalty" != "null" ]] && parts+=("--repeat-penalty ${repeat_penalty}")

  # Join with newline+6-space indent for YAML folded scalar
  local IFS=$'\n'
  echo "${parts[*]}"
}

# ─── 1. Generate llama-swap models.yml ──────────────────────────
echo "==> Generating llama-swap config"

{
  # Server section
  echo "server:"
  echo "  listen: $(yq '.llama_swap.server.listen' "$MODELS_YML")"
  echo "  port: $(yq '.llama_swap.server.port' "$MODELS_YML")"
  echo ""

  # Env section
  echo "env:"
  for key in $(yq '.llama_swap.env | keys | .[]' "$MODELS_YML"); do
    val="$(yq ".llama_swap.env[\"$key\"]" "$MODELS_YML")"
    # Quote values that need it (numbers that should be strings, etc.)
    if [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" =~ GiB$ ]]; then
      echo "  ${key}: \"${val}\""
    else
      echo "  ${key}: ${val}"
    fi
  done
  echo ""

  # llama_defaults section
  echo "llama_defaults:"
  echo "  threads: $(yq '.llama_swap.llama_defaults.threads' "$MODELS_YML")"
  echo ""

  # Models section
  echo "models:"

  # Iterate koala slots only
  for slot_key in $(yq '.slots | keys | .[] | select(test("^koala/"))' "$MODELS_YML"); do
    litellm_name="$(yq ".slots[\"$slot_key\"].litellm_name" "$MODELS_YML")"
    # Strip koala/ prefix to get swap model name
    swap_name="${litellm_name#koala/}"
    port="$(yq ".slots[\"$slot_key\"].port" "$MODELS_YML")"

    echo "  ${swap_name}:"
    echo "    source: local"
    echo "    port: ${port}"
    echo "    cmd: >"

    # Get cmd parts and indent them
    while IFS= read -r part; do
      echo "      ${part}"
    done < <(build_cmd "$slot_key")

    echo ""
  done
} > "$SWAP_CONFIG"

echo "    Written: $SWAP_CONFIG"

# ─── 2. Generate K8s ConfigMap ──────────────────────────────────
echo "==> Generating llama-swap ConfigMap"

{
  echo "apiVersion: v1"
  echo "kind: ConfigMap"
  echo "metadata:"
  echo "  name: llama-swap-config"
  echo "  namespace: ai-stack"
  echo "data:"
  echo "  models.yml: |"

  # Indent the entire models.yml content by 4 spaces
  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      echo ""
    else
      echo "    ${line}"
    fi
  done < "$SWAP_CONFIG"
} > "$SWAP_CONFIGMAP"

echo "    Written: $SWAP_CONFIGMAP"

# ─── 3. Generate LiteLLM config ────────────────────────────────
echo "==> Generating LiteLLM config"

koala_host="$(yq '.hardware.koala.host' "$MODELS_YML")"
koala_port="$(yq '.hardware.koala.llama_swap_port' "$MODELS_YML")"
iguana_host="$(yq '.hardware.iguana.host' "$MODELS_YML")"
iguana_port="$(yq '.hardware.iguana.ollama_port' "$MODELS_YML")"

{
  # General settings from extras.yaml
  yq '.general_settings' "$LITELLM_EXTRAS" | sed 's/^//' | {
    echo "general_settings:"
    while IFS= read -r line; do
      # Skip the first line if it's "general_settings:" or empty mapping
      [[ "$line" == "---" ]] && continue
      [[ -z "$line" ]] && continue
      echo "  $line"
    done
  }
  echo ""

  echo "model_list:"

  # Koala slots → openai provider via llama-swap
  for slot_key in $(yq '.slots | keys | .[] | select(test("^koala/"))' "$MODELS_YML"); do
    litellm_name="$(yq ".slots[\"$slot_key\"].litellm_name" "$MODELS_YML")"
    swap_name="${litellm_name#koala/}"

    echo "  - model_name: \"${litellm_name}\""
    echo "    litellm_params:"
    echo "      model: \"openai/${swap_name}\""
    echo "      api_base: \"http://${koala_host}:${koala_port}/v1\""
  done

  # Iguana slots → ollama provider
  for slot_key in $(yq '.slots | keys | .[] | select(test("^iguana/"))' "$MODELS_YML"); do
    litellm_name="$(yq ".slots[\"$slot_key\"].litellm_name" "$MODELS_YML")"
    slot_type="$(yq ".slots[\"$slot_key\"].type // \"chat\"" "$MODELS_YML")"
    model_name="$(yq ".slots[\"$slot_key\"].model" "$MODELS_YML")"

    # Skip reranker and stt — not routed through LiteLLM
    [[ "$slot_type" == "reranker" ]] && continue
    [[ "$slot_type" == "stt" ]] && continue

    local_provider="ollama_chat"
    [[ "$slot_type" == "embedding" ]] && local_provider="ollama"

    echo "  - model_name: \"${litellm_name}\""
    echo "    litellm_params:"
    echo "      model: \"${local_provider}/${model_name}\""
    echo "      api_base: \"http://${iguana_host}:${iguana_port}\""
  done

  # Merge extra_models from extras.yaml (if any)
  extra_count="$(yq '.extra_models | length' "$LITELLM_EXTRAS")"
  if [[ "$extra_count" -gt 0 ]]; then
    # Output each extra model as a properly indented YAML list item
    yq '.extra_models' "$LITELLM_EXTRAS" | sed 's/^/  /'
  fi
} > "$LITELLM_CONFIG"

echo "    Written: $LITELLM_CONFIG"

# ─── 4. Generate MODELS.md ─────────────────────────────────────
echo "==> Generating MODELS.md"

{
  echo "# Model Inventory"
  echo ""
  echo "> Auto-generated from \`models.yml\` — do not edit manually."
  echo "> Regenerate with: \`scripts/model-generate.sh\`"
  echo ""

  # Hardware profiles
  echo "## Hardware Profiles"
  echo ""
  echo "| Machine | GPU | Memory | Platform | Host |"
  echo "|---------|-----|--------|----------|------|"

  # koala
  koala_gpu="$(yq '.hardware.koala.gpu' "$MODELS_YML")"
  koala_vram="$(yq '.hardware.koala.vram_gb' "$MODELS_YML")"
  koala_ram="$(yq '.hardware.koala.ram_gb' "$MODELS_YML")"
  koala_platform="$(yq '.hardware.koala.platform' "$MODELS_YML")"
  echo "| koala | ${koala_gpu} | ${koala_vram} GB VRAM, ${koala_ram} GB RAM | ${koala_platform} | ${koala_host}:${koala_port} |"

  # iguana
  iguana_gpu="$(yq '.hardware.iguana.gpu' "$MODELS_YML")"
  iguana_mem="$(yq '.hardware.iguana.unified_memory_gb' "$MODELS_YML")"
  iguana_platform="$(yq '.hardware.iguana.platform' "$MODELS_YML")"
  echo "| iguana | ${iguana_gpu} | ${iguana_mem} GB unified | ${iguana_platform} | ${iguana_host}:${iguana_port} |"
  echo ""

  # Koala slots
  echo "## koala — llama-swap (k3s)"
  echo ""
  echo "| Slot | Model | LiteLLM Name | Port | Context | Use Case |"
  echo "|------|-------|-------------|------|---------|----------|"

  for slot_key in $(yq '.slots | keys | .[] | select(test("^koala/"))' "$MODELS_YML"); do
    slot_name="${slot_key#koala/}"
    model="$(yq ".slots[\"$slot_key\"].model" "$MODELS_YML")"
    litellm_name="$(yq ".slots[\"$slot_key\"].litellm_name" "$MODELS_YML")"
    port="$(yq ".slots[\"$slot_key\"].port" "$MODELS_YML")"
    ctx="$(yq ".slots[\"$slot_key\"].params.ctx_size // \"-\"" "$MODELS_YML")"
    use_case="$(yq ".slots[\"$slot_key\"].use_case" "$MODELS_YML")"
    echo "| ${slot_name} | ${model} | \`${litellm_name}\` | ${port} | ${ctx} | ${use_case} |"
  done
  echo ""

  # Iguana slots
  echo "## iguana — ollama"
  echo ""
  echo "| Slot | Model | LiteLLM Name | Type | Use Case |"
  echo "|------|-------|-------------|------|----------|"

  for slot_key in $(yq '.slots | keys | .[] | select(test("^iguana/"))' "$MODELS_YML"); do
    slot_name="${slot_key#iguana/}"
    model="$(yq ".slots[\"$slot_key\"].model" "$MODELS_YML")"
    litellm_name="$(yq ".slots[\"$slot_key\"].litellm_name" "$MODELS_YML")"
    slot_type="$(yq ".slots[\"$slot_key\"].type // \"chat\"" "$MODELS_YML")"
    use_case="$(yq ".slots[\"$slot_key\"].use_case" "$MODELS_YML")"
    echo "| ${slot_name} | ${model} | \`${litellm_name}\` | ${slot_type} | ${use_case} |"
  done
  echo ""

  # Management commands
  echo "## Management Commands"
  echo ""
  echo '```bash'
  echo 'task model:status     # compare models.yml vs live state'
  echo 'task model:plan       # dry-run: show what would change'
  echo 'task model:apply      # execute changes (with approval gates)'
  echo 'task model:eval       # benchmark a model against slot targets'
  echo 'task model:generate   # regenerate configs without deploying'
  echo 'task model:remove     # remove a model (with confirmation)'
  echo '```'
  echo ""
  echo "See \`params/koala-profiles.yml\` for VRAM parameter guidance."
} > "$MODELS_MD"

echo "    Written: $MODELS_MD"

echo ""
echo "==> Done. Generated files:"
echo "    - $SWAP_CONFIG"
echo "    - $SWAP_CONFIGMAP"
echo "    - $LITELLM_CONFIG"
echo "    - $MODELS_MD"
