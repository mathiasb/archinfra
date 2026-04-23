# Model Management Tooling — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Declarative model management across koala, iguana, and piguard — one `models.yml` source of truth, generated configs, Taskfile commands with approval gates, automated benchmarks.

**Architecture:** A central `models.yml` declares all model slots. Shell scripts (invoked via Taskfile) generate llama-swap ConfigMap, LiteLLM config, and MODELS.md from this file. `model:status` / `model:plan` / `model:apply` commands handle drift detection and provisioning with interactive approval for destructive operations.

**Tech Stack:** Bash scripts, Taskfile (taskfile.dev), yq (YAML processing), kubectl, ssh, ollama CLI, curl

**Spec:** `docs/superpowers/specs/2026-04-23-model-management-design.md`

---

## File Structure

```
infra/
├── models.yml                              # SOURCE OF TRUTH — all slots, all machines
├── Taskfile.yml                            # model:* commands
├── litellm/
│   ├── config.yaml                         # GENERATED — full LiteLLM config
│   ├── extras.yaml                         # MANUAL — cloud routes, general settings
│   └── deploy.sh                           # scp config to piguard + restart
├── params/
│   └── koala-profiles.yml                  # known-good parameter profiles for 12GB VRAM
├── scripts/
│   ├── model-generate.sh                   # models.yml → configmap + litellm + MODELS.md
│   ├── model-status.sh                     # query live state, compare to models.yml
│   ├── model-plan.sh                       # diff desired vs live, show action plan
│   ├── model-apply.sh                      # execute plan with approval gates
│   └── bench/
│       ├── run-bench.sh                    # tok/s, TTFT, VRAM, context stress
│       └── prompts/
│           ├── code-completion.txt         # standard coding prompt
│           └── instruction-following.txt   # standard instruction prompt
├── benchmarks/
│   └── results.jsonl                       # append-only benchmark log (created by bench)
├── k3s/apps/ai-stack/
│   ├── llama-swap-configmap.yaml           # GENERATED
│   ├── llama-swap-deployment.yaml          # existing, unchanged
│   └── models.yml                          # GENERATED (mirror)
└── MODELS.md                              # GENERATED
```

### Prerequisites

Install on the machine where you run tasks (flamingo/iguana/koala):

```bash
# taskfile
brew install go-task          # macOS
# or: sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin  # Linux

# yq (YAML processor)
brew install yq               # macOS
# or: sudo pacman -S go-yq    # Arch (koala)
```

Ensure `ssh mathias@iguana` and `ssh mathias@piguard` work without password prompts (Tailscale/SSH keys).

---

## Task 1: Create `models.yml` source of truth

**Files:**
- Create: `models.yml`

This is the foundation everything else builds on. We translate current live state into the declarative format.

- [ ] **Step 1: Create `models.yml` with hardware profiles and all current slots**

```yaml
# models.yml — single source of truth for all model slots
# Generated configs: llama-swap ConfigMap, LiteLLM config, MODELS.md
# Manual edits only — everything downstream is derived from this file.

hardware:
  koala:
    gpu: "RTX 5070"
    vram_gb: 12
    ram_gb: 64
    platform: llama-swap
    access: kubectl
    host: "10.0.1.20"
    llama_swap_port: 31234
    model_path: "/data/models/huggingface"
  iguana:
    gpu: "M2 Ultra"
    unified_memory_gb: 64
    platform: ollama
    access: ssh
    host: "10.0.1.25"
    ollama_port: 11434

# llama-swap server defaults (koala)
llama_swap:
  server:
    listen: "0.0.0.0"
    port: 8080
  env:
    HF_HOME: "/data/models/huggingface"
    CUDA_VISIBLE_DEVICES: "0"
    OMP_NUM_THREADS: "16"
    GGML_NUM_THREADS: "16"
    GGML_NO_ALLOCATOR: "1"
    LLAMA_CACHE_CAPACITY: "16GiB"
    LLAMA_SET_ROWS: "1"
  llama_defaults:
    threads: 16

slots:
  # ── koala (llama-swap via k8s) ──────────────────────────────

  koala/fast-coder:
    model: "unsloth/Qwen3.5-9B-GGUF"
    file: "Qwen3.5-9B-UD-Q4_K_XL.gguf"
    litellm_name: "koala/qwen35-9b-fast"
    port: 5805
    use_case: "Agentic coding (fast, many tool calls)"
    params:
      ctx_size: 262144
      ngl: 99
      batch_size: 2048
      ubatch_size: 512
      cache_type_k: q4_0
      cache_type_v: q4_0
      flash_attn: true
      kv_unified: true
      cache_reuse: 256
    sampling:
      temp: 0.6
      top_p: 0.95
      top_k: 20
      repeat_penalty: 1.07
    benchmark_targets:
      min_tok_s: 50

  koala/quality-coder:
    model: "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"
    file: "Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf"
    litellm_name: "koala/qwen3-coder-30b"
    port: 5800
    use_case: "Agentic coding (quality, complex tasks)"
    params:
      ctx_size: 32768
      ngl: 10
      batch_size: 128
      ubatch_size: 64
      cache_type_k: q8_0
      cache_type_v: q5_0
      flash_attn: true
      kv_unified: true
      cache_reuse: 256
    sampling:
      temp: 0.2
      top_p: 0.9
      top_k: 64
      repeat_penalty: 1.07
    benchmark_targets:
      min_tok_s: 10

  koala/fast-general:
    model: "unsloth/Phi-4-mini-instruct-GGUF"
    file: "Phi-4-mini-instruct.Q8_0.gguf"
    litellm_name: "koala/phi4-mini"
    port: 5801
    use_case: "Quick one-off tasks, tool calls"
    params:
      ctx_size: 8192
      ngl: 60
      batch_size: 512
      ubatch_size: 128
      cache_type_k: q8_0
      cache_type_v: f16
      kv_unified: true
      cache_reuse: 256
    sampling:
      temp: 0.2
      top_p: 0.9
      top_k: 64
      repeat_penalty: 1.05
    benchmark_targets:
      min_tok_s: 80

  koala/general:
    model: "bartowski/phi-4-GGUF"
    file: "phi-4-Q4_K_M.gguf"
    litellm_name: "koala/phi4-14b"
    port: 5802
    use_case: "Chat / general assistant"
    params:
      ctx_size: 8192
      ngl: 64
      batch_size: 448
      ubatch_size: 128
      cache_type_k: q8_0
      cache_type_v: f16
      kv_unified: true
      cache_reuse: 256
    sampling:
      temp: 0.2
      top_p: 0.9
      top_k: 64
      repeat_penalty: 1.05

  # ── iguana (ollama) ─────────────────────────────────────────

  iguana/quality-coder:
    model: "qwen3-coder-next"
    litellm_name: "qwen3-coder-next"
    use_case: "Agentic coding (quality, complex tasks)"
    params:
      num_ctx: 65536
    benchmark_targets:
      min_tok_s: 15

  iguana/general:
    model: "qwen3.5:35b"
    litellm_name: "qwen3.5-35b"
    use_case: "Chat / general assistant (OpenWebUI)"
    params:
      num_ctx: 32768
    benchmark_targets:
      min_tok_s: 20

  iguana/reasoning:
    model: "deepseek-r1-tuned"
    litellm_name: "deepseek-r1-tuned"
    use_case: "Reasoning / planning"
    params:
      num_ctx: 16384
    benchmark_targets:
      min_tok_s: 15

  iguana/embed:
    model: "nomic-embed-text"
    litellm_name: "nomic-embed"
    type: embedding
    use_case: "Embeddings (RAG)"

  iguana/rerank:
    model: "Qwen3-Reranker-0.6B"
    litellm_name: "iguana/rerank"
    type: reranker
    use_case: "Search result reranking"

  iguana/stt:
    model: "mlx-community/whisper-large-v3-mlx"
    litellm_name: "iguana/whisper"
    platform: mlx-openai-server
    port: 8100
    type: stt
    use_case: "Speech to text"
```

- [ ] **Step 2: Validate YAML is well-formed**

Run: `yq eval '.' models.yml > /dev/null && echo "OK"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add models.yml
git commit -m "feat: add models.yml source of truth for all model slots"
```

---

## Task 2: Create parameter profiles

**Files:**
- Create: `params/koala-profiles.yml`

Reference table of known-good parameter sets for koala's 12GB VRAM. Not consumed by scripts — this is documentation that informs `models.yml` edits.

- [ ] **Step 1: Create `params/koala-profiles.yml`**

```yaml
# Known-good parameter profiles for koala (RTX 5070, 12GB VRAM, 64GB RAM)
# Use as starting points when adding models to models.yml.
# After benchmarking, update models.yml with tuned values.

profiles:
  gpu-resident-small:
    description: "Models <=6GB, fully GPU-resident"
    fits: "Q4 quants up to ~9B dense, Q8 up to ~3B"
    example_models:
      - "Qwen3.5-9B UD-Q4_K_XL (~5.6GB)"
      - "Phi-4-mini Q8_0 (~4GB)"
    params:
      ngl: 99
      batch_size: 2048
      ubatch_size: 512
      cache_type_k: q4_0
      cache_type_v: q4_0
      flash_attn: true
    notes: "Can push ctx_size high (128k+). Best throughput."

  gpu-resident-medium:
    description: "Models 6-10GB, fits in VRAM with careful params"
    fits: "Q4 quants 9-14B dense"
    example_models:
      - "Phi-4 14B Q4_K_M (~9GB)"
    params:
      ngl: 60-64
      batch_size: 448-512
      ubatch_size: 128
      cache_type_k: q8_0
      cache_type_v: f16
    notes: "ctx_size 8k-16k safe. 32k possible with q4_0 KV cache. Watch VRAM during generation."

  partial-offload:
    description: "Models >10GB, partial GPU offload to system RAM"
    fits: "MoE models (e.g. Qwen3-Coder-30B-A3B), large dense Q4"
    example_models:
      - "Qwen3-Coder-30B-A3B UD-Q4_K_XL (~19GB, 10 layers on GPU)"
      - "DeepSeek-Coder-V2-Lite Q4_K_M (~9GB model, MoE needs headroom)"
    params:
      ngl: 10-20
      batch_size: 128
      ubatch_size: 64
      cache_type_k: q8_0
      cache_type_v: q5_0
      flash_attn: true
    notes: "Slower but worthwhile for quality. ctx_size 16-32k max. More GPU layers = faster but check VRAM with nvidia-smi during load."
```

- [ ] **Step 2: Commit**

```bash
git add params/koala-profiles.yml
git commit -m "docs: add koala VRAM parameter profiles"
```

---

## Task 3: Create LiteLLM extras and deploy script

**Files:**
- Create: `litellm/extras.yaml`
- Create: `litellm/deploy.sh`

The extras file holds non-generated LiteLLM config (cloud routes, general settings). The deploy script pushes config to piguard.

- [ ] **Step 1: SSH to piguard and retrieve current LiteLLM config**

Run from flamingo/iguana:
```bash
ssh mathias@piguard "cat ~/litellm-infra/config.yaml"
```

Copy the output. This is needed to extract cloud routes and general settings that aren't model slots.

- [ ] **Step 2: Create `litellm/extras.yaml`**

Extract non-slot config from the piguard config. This file is merged with generated routes. Populate with whatever was retrieved in step 1. Template structure:

```yaml
# litellm/extras.yaml — manually maintained LiteLLM settings
# Merged with generated model routes to produce litellm/config.yaml
# Edit this for: cloud providers, general settings, rate limits

general_settings:
  master_key: "os.environ/LITELLM_MASTER_KEY"
  database_url: "os.environ/DATABASE_URL"

# Cloud and external model routes (not managed by model slots)
extra_models:
  # Example — adjust based on actual piguard config:
  # - model_name: "claude-sonnet"
  #   litellm_params:
  #     model: "claude-sonnet-4-20250514"
  #     api_key: "os.environ/ANTHROPIC_API_KEY"
  # - model_name: "berget/llama-70b"
  #   litellm_params:
  #     model: "openai/meta-llama/Llama-3.3-70B-Instruct"
  #     api_base: "https://api.berget.ai/v1"
  #     api_key: "os.environ/BERGET_API_KEY"
```

Populate `extra_models` with the actual cloud routes from piguard's config. Remove any routes that correspond to model slots (those will be generated).

- [ ] **Step 3: Create `litellm/deploy.sh`**

```bash
#!/bin/bash
# Deploy LiteLLM config to piguard and restart
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.yaml"
PIGUARD_HOST="piguard"
PIGUARD_CONFIG_DIR="/home/mathias/litellm-infra"

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: ${CONFIG} not found. Run 'task model:generate' first."
    exit 1
fi

echo "=== Deploying LiteLLM config to ${PIGUARD_HOST} ==="
scp "$CONFIG" "${PIGUARD_HOST}:${PIGUARD_CONFIG_DIR}/config.yaml"

echo "=== Restarting LiteLLM ==="
ssh "$PIGUARD_HOST" "cd ${PIGUARD_CONFIG_DIR} && docker compose restart litellm"

echo "=== Waiting for LiteLLM to be ready ==="
for i in $(seq 1 30); do
    if ssh "$PIGUARD_HOST" "curl -sf http://localhost:4000/health" > /dev/null 2>&1; then
        echo "LiteLLM is healthy."
        exit 0
    fi
    sleep 2
done

echo "WARNING: LiteLLM did not become healthy within 60s. Check piguard."
exit 1
```

```bash
chmod +x litellm/deploy.sh
```

- [ ] **Step 4: Commit**

```bash
git add litellm/extras.yaml litellm/deploy.sh
git commit -m "feat: add litellm extras config and deploy script"
```

---

## Task 4: Write `model-generate.sh` — config generation

**Files:**
- Create: `scripts/model-generate.sh`

This is the core script. It reads `models.yml` and produces three outputs: llama-swap ConfigMap, LiteLLM config, and MODELS.md.

- [ ] **Step 1: Create `scripts/model-generate.sh`**

```bash
#!/bin/bash
# Generate all configs from models.yml
# Outputs:
#   k3s/apps/ai-stack/llama-swap-configmap.yaml
#   k3s/apps/ai-stack/models.yml  (mirror)
#   litellm/config.yaml
#   MODELS.md
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_YML="${REPO_ROOT}/models.yml"
CONFIGMAP_OUT="${REPO_ROOT}/k3s/apps/ai-stack/llama-swap-configmap.yaml"
LLAMA_SWAP_MIRROR="${REPO_ROOT}/k3s/apps/ai-stack/models.yml"
LITELLM_OUT="${REPO_ROOT}/litellm/config.yaml"
LITELLM_EXTRAS="${REPO_ROOT}/litellm/extras.yaml"
MODELS_MD_OUT="${REPO_ROOT}/MODELS.md"

if [ ! -f "$MODELS_YML" ]; then
    echo "ERROR: ${MODELS_YML} not found"
    exit 1
fi

echo "=== Generating configs from models.yml ==="

# ── 1. Generate llama-swap models.yml ─────────────────────────

generate_llama_swap() {
    local model_path
    model_path=$(yq '.hardware.koala.model_path' "$MODELS_YML")

    # Start with server config and env from models.yml
    cat <<YAML
server:
$(yq '.llama_swap.server' "$MODELS_YML" | sed 's/^/  /')

env:
$(yq '.llama_swap.env' "$MODELS_YML" | sed 's/^/  /')

llama_defaults:
$(yq '.llama_swap.llama_defaults' "$MODELS_YML" | sed 's/^/  /')

models:
YAML

    # Iterate koala slots
    yq -r '.slots | to_entries[] | select(.key | startswith("koala/")) | .key' "$MODELS_YML" | while read -r slot_key; do
        local slot_name
        slot_name="${slot_key#koala/}"
        local llama_name
        llama_name=$(yq ".slots[\"${slot_key}\"] | .file // .model" "$MODELS_YML" | sed 's|/|_|g')

        local file port ctx ngl batch ubatch flash cache_k cache_v kv_unified cache_reuse
        file=$(yq ".slots[\"${slot_key}\"].file" "$MODELS_YML")
        port=$(yq ".slots[\"${slot_key}\"].port" "$MODELS_YML")
        ctx=$(yq ".slots[\"${slot_key}\"].params.ctx_size" "$MODELS_YML")
        ngl=$(yq ".slots[\"${slot_key}\"].params.ngl" "$MODELS_YML")
        batch=$(yq ".slots[\"${slot_key}\"].params.batch_size" "$MODELS_YML")
        ubatch=$(yq ".slots[\"${slot_key}\"].params.ubatch_size" "$MODELS_YML")
        flash=$(yq ".slots[\"${slot_key}\"].params.flash_attn" "$MODELS_YML")
        cache_k=$(yq ".slots[\"${slot_key}\"].params.cache_type_k" "$MODELS_YML")
        cache_v=$(yq ".slots[\"${slot_key}\"].params.cache_type_v" "$MODELS_YML")
        kv_unified=$(yq ".slots[\"${slot_key}\"].params.kv_unified" "$MODELS_YML")
        cache_reuse=$(yq ".slots[\"${slot_key}\"].params.cache_reuse" "$MODELS_YML")

        local temp top_p top_k repeat
        temp=$(yq ".slots[\"${slot_key}\"].sampling.temp" "$MODELS_YML")
        top_p=$(yq ".slots[\"${slot_key}\"].sampling.top_p" "$MODELS_YML")
        top_k=$(yq ".slots[\"${slot_key}\"].sampling.top_k" "$MODELS_YML")
        repeat=$(yq ".slots[\"${slot_key}\"].sampling.repeat_penalty" "$MODELS_YML")

        # Derive the model filename — handle HF repo/file naming
        local model_repo
        model_repo=$(yq ".slots[\"${slot_key}\"].model" "$MODELS_YML")
        local model_file_path="${model_path}/${model_repo/\//_}_${file}"

        # Build the llama-swap model name from the litellm_name
        local swap_name
        swap_name=$(yq ".slots[\"${slot_key}\"].litellm_name" "$MODELS_YML" | sed 's|^koala/||')

        cat <<YAML
  ${swap_name}:
    source: local
    port: ${port}
    cmd: >
      llama-server
      --model "${model_file_path}"
      --host 0.0.0.0
      --port \${PORT}
      --jinja
      --metrics
YAML
        [ "$flash" = "true" ] && echo "      --flash-attn on"
        echo "      --ctx-size ${ctx}"
        if [ "$ngl" = "99" ]; then
            echo "      --n-gpu-layers 99"
        else
            echo "      -ngl ${ngl}"
        fi
        echo "      --batch-size ${batch}"
        echo "      --ubatch-size ${ubatch}"
        echo "      --parallel 1"
        [ "$kv_unified" = "true" ] && echo "      --kv-unified"
        [ "$cache_reuse" != "null" ] && echo "      --cache-reuse ${cache_reuse}"
        echo "      --cache-type-k ${cache_k}"
        echo "      --cache-type-v ${cache_v}"
        [ "$temp" != "null" ] && echo "      --temp ${temp}"
        [ "$top_p" != "null" ] && echo "      --top-p ${top_p}"
        [ "$top_k" != "null" ] && echo "      --top-k ${top_k}"
        [ "$repeat" != "null" ] && echo "      --repeat-penalty ${repeat}"
        echo ""
    done
}

echo "  Generating llama-swap config..."
LLAMA_SWAP_CONTENT=$(generate_llama_swap)

# Write the mirror copy
echo "$LLAMA_SWAP_CONTENT" > "$LLAMA_SWAP_MIRROR"

# Write the ConfigMap
cat > "$CONFIGMAP_OUT" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: llama-swap-config
  namespace: ai-stack
data:
  models.yml: |
EOF
echo "$LLAMA_SWAP_CONTENT" | sed 's/^/    /' >> "$CONFIGMAP_OUT"
echo "  Written: ${CONFIGMAP_OUT}"

# ── 2. Generate LiteLLM config ───────────────────────────────

generate_litellm() {
    local koala_host koala_port iguana_host iguana_port
    koala_host=$(yq '.hardware.koala.host' "$MODELS_YML")
    koala_port=$(yq '.hardware.koala.llama_swap_port' "$MODELS_YML")
    iguana_host=$(yq '.hardware.iguana.host' "$MODELS_YML")
    iguana_port=$(yq '.hardware.iguana.ollama_port' "$MODELS_YML")

    # Start with general settings from extras
    if [ -f "$LITELLM_EXTRAS" ]; then
        yq '.general_settings // {}' "$LITELLM_EXTRAS" | {
            local gs
            gs=$(cat)
            if [ "$gs" != "{}" ] && [ "$gs" != "null" ]; then
                echo "general_settings:"
                echo "$gs" | sed 's/^/  /'
                echo ""
            fi
        }
    fi

    echo "model_list:"

    # Generate koala routes (llama-swap → openai-compatible)
    yq -r '.slots | to_entries[] | select(.key | startswith("koala/")) | .key' "$MODELS_YML" | while read -r slot_key; do
        local litellm_name model_type
        litellm_name=$(yq ".slots[\"${slot_key}\"].litellm_name" "$MODELS_YML")
        model_type=$(yq ".slots[\"${slot_key}\"].type // \"chat\"" "$MODELS_YML")

        # Skip non-chat models (no LiteLLM route for STT etc.)
        [ "$model_type" != "chat" ] && [ "$model_type" != "null" ] && continue

        # llama-swap uses the model name in the path
        local swap_name
        swap_name=$(echo "$litellm_name" | sed 's|^koala/||')

        cat <<YAML
  - model_name: "${litellm_name}"
    litellm_params:
      model: "openai/${swap_name}"
      api_base: "http://${koala_host}:${koala_port}/v1"
YAML
    done

    # Generate iguana routes (ollama)
    yq -r '.slots | to_entries[] | select(.key | startswith("iguana/")) | .key' "$MODELS_YML" | while read -r slot_key; do
        local litellm_name model_name model_type
        litellm_name=$(yq ".slots[\"${slot_key}\"].litellm_name" "$MODELS_YML")
        model_name=$(yq ".slots[\"${slot_key}\"].model" "$MODELS_YML")
        model_type=$(yq ".slots[\"${slot_key}\"].type // \"chat\"" "$MODELS_YML")

        case "$model_type" in
            embedding)
                cat <<YAML
  - model_name: "${litellm_name}"
    litellm_params:
      model: "ollama/${model_name}"
      api_base: "http://${iguana_host}:${iguana_port}"
YAML
                ;;
            reranker|stt)
                # Skip — not routed through LiteLLM
                ;;
            *)
                cat <<YAML
  - model_name: "${litellm_name}"
    litellm_params:
      model: "ollama_chat/${model_name}"
      api_base: "http://${iguana_host}:${iguana_port}"
YAML
                ;;
        esac
    done

    # Append extra models from extras.yaml
    if [ -f "$LITELLM_EXTRAS" ]; then
        local extras
        extras=$(yq '.extra_models // []' "$LITELLM_EXTRAS")
        if [ "$extras" != "[]" ] && [ "$extras" != "null" ]; then
            echo "$extras" | sed 's/^/  /'
        fi
    fi
}

echo "  Generating LiteLLM config..."
generate_litellm > "$LITELLM_OUT"
echo "  Written: ${LITELLM_OUT}"

# ── 3. Generate MODELS.md ────────────────────────────────────

generate_models_md() {
    cat <<'HEADER'
# Model Management

Slot-based model management for the homelab AI stack.
Each slot has exactly one model. When a better model arrives, evaluate it, swap if it wins, delete the old one.

> **This file is generated from `models.yml`. Do not edit directly.**
> Run `task model:generate` to regenerate.

---

## Hardware Profiles

HEADER

    echo "| Machine | GPU/Memory | Platform |"
    echo "|---|---|---|"
    yq -r '.hardware | to_entries[] | "| " + .key + " | " + (.value.gpu // "N/A") + " " + ((.value.vram_gb // .value.unified_memory_gb | tostring) + "GB") + " | " + .value.platform + " |"' "$MODELS_YML"
    echo ""
    echo "---"
    echo ""
    echo "## Model Slots"
    echo ""

    # Group by machine
    for machine in koala iguana; do
        local platform
        platform=$(yq ".hardware.${machine}.platform" "$MODELS_YML")
        echo "### ${machine} (${platform})"
        echo ""
        echo "| Slot | LiteLLM name | Model | Use Case |"
        echo "|---|---|---|---|"

        yq -r ".slots | to_entries[] | select(.key | startswith(\"${machine}/\")) | .key" "$MODELS_YML" | while read -r slot_key; do
            local slot_name litellm_name model use_case
            slot_name="${slot_key#${machine}/}"
            litellm_name=$(yq ".slots[\"${slot_key}\"].litellm_name" "$MODELS_YML")
            model=$(yq ".slots[\"${slot_key}\"].model" "$MODELS_YML")
            use_case=$(yq ".slots[\"${slot_key}\"].use_case // \"—\"" "$MODELS_YML")
            echo "| ${slot_name} | \`${litellm_name}\` | ${model} | ${use_case} |"
        done
        echo ""
    done

    cat <<'FOOTER'
---

## Use Case → Model Mapping

See slot definitions above for primary assignments. Fallback routing is configured in LiteLLM (`litellm/extras.yaml`).

---

## Management

```bash
task model:status     # compare models.yml vs live state
task model:plan       # dry-run: show what would change
task model:apply      # execute changes (with approval gates)
task model:eval       # benchmark a model against slot targets
task model:generate   # regenerate configs without deploying
```

See `params/koala-profiles.yml` for VRAM parameter guidance.
FOOTER
}

echo "  Generating MODELS.md..."
generate_models_md > "$MODELS_MD_OUT"
echo "  Written: ${MODELS_MD_OUT}"

echo ""
echo "=== Done. Review generated files, then deploy with 'task model:apply' ==="
```

```bash
chmod +x scripts/model-generate.sh
```

- [ ] **Step 2: Run the generator and verify output**

```bash
./scripts/model-generate.sh
```

Check each output:
- `k3s/apps/ai-stack/llama-swap-configmap.yaml` — compare against current version, should be equivalent
- `k3s/apps/ai-stack/models.yml` — should match the llama-swap config content
- `litellm/config.yaml` — should have routes for all slots
- `MODELS.md` — should have all slots documented

```bash
diff <(git show HEAD:k3s/apps/ai-stack/llama-swap-configmap.yaml) k3s/apps/ai-stack/llama-swap-configmap.yaml
```

The diff may show minor formatting differences (that's fine) but the model names, ports, and parameters should be identical.

- [ ] **Step 3: Fix any generation issues, re-run until output matches expectations**

Iterate on the script until the generated ConfigMap is functionally equivalent to the current hand-maintained one.

- [ ] **Step 4: Commit**

```bash
git add scripts/model-generate.sh
git commit -m "feat: add model-generate.sh — generates configs from models.yml"
```

---

## Task 5: Write `model-status.sh` — live state comparison

**Files:**
- Create: `scripts/model-status.sh`

Queries koala (kubectl + llama-swap API) and iguana (ollama list) to show current state vs declared state.

- [ ] **Step 1: Create `scripts/model-status.sh`**

```bash
#!/bin/bash
# Show model status: declared (models.yml) vs live (koala + iguana)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_YML="${REPO_ROOT}/models.yml"

KOALA_HOST=$(yq '.hardware.koala.host' "$MODELS_YML")
KOALA_PORT=$(yq '.hardware.koala.llama_swap_port' "$MODELS_YML")
IGUANA_HOST=$(yq '.hardware.iguana.host' "$MODELS_YML")
IGUANA_PORT=$(yq '.hardware.iguana.ollama_port' "$MODELS_YML")

echo "=== Model Status ==="
echo ""

# ── koala (llama-swap) ────────────────────────────────────────

echo "── koala (llama-swap) ──"
echo ""

# Get live models from llama-swap API
LIVE_KOALA=$(curl -sf "http://${KOALA_HOST}:${KOALA_PORT}/v1/models" 2>/dev/null || echo '{"data":[]}')

printf "%-20s %-40s %-10s\n" "SLOT" "MODEL" "STATUS"
printf "%-20s %-40s %-10s\n" "----" "-----" "------"

yq -r '.slots | to_entries[] | select(.key | startswith("koala/")) | .key' "$MODELS_YML" | while read -r slot_key; do
    slot_name="${slot_key#koala/}"
    litellm_name=$(yq ".slots[\"${slot_key}\"].litellm_name" "$MODELS_YML")
    swap_name=$(echo "$litellm_name" | sed 's|^koala/||')
    model=$(yq ".slots[\"${slot_key}\"].model" "$MODELS_YML")

    # Check if model is available in llama-swap
    if echo "$LIVE_KOALA" | grep -q "\"${swap_name}\"" 2>/dev/null; then
        status="ok"
    else
        status="MISSING"
    fi

    printf "%-20s %-40s %-10s\n" "$slot_name" "$model" "$status"
done

echo ""

# ── iguana (ollama) ───────────────────────────────────────────

echo "── iguana (ollama) ──"
echo ""

# Get live models from ollama
LIVE_IGUANA=$(ssh -o ConnectTimeout=5 mathias@iguana "ollama list 2>/dev/null" 2>/dev/null || echo "")

printf "%-20s %-40s %-10s\n" "SLOT" "MODEL" "STATUS"
printf "%-20s %-40s %-10s\n" "----" "-----" "------"

yq -r '.slots | to_entries[] | select(.key | startswith("iguana/")) | .key' "$MODELS_YML" | while read -r slot_key; do
    slot_name="${slot_key#iguana/}"
    model=$(yq ".slots[\"${slot_key}\"].model" "$MODELS_YML")
    platform=$(yq ".slots[\"${slot_key}\"].platform // \"ollama\"" "$MODELS_YML")

    # Skip non-ollama platforms (e.g. mlx-openai-server)
    if [ "$platform" != "ollama" ] && [ "$platform" != "null" ]; then
        status="$platform"
    elif echo "$LIVE_IGUANA" | grep -qi "${model%%:*}" 2>/dev/null; then
        status="ok"
    else
        status="MISSING"
    fi

    printf "%-20s %-40s %-10s\n" "$slot_name" "$model" "$status"
done

echo ""

# ── Untracked models on iguana ────────────────────────────────

if [ -n "$LIVE_IGUANA" ]; then
    echo "── iguana: models not in any slot ──"
    echo ""
    # Extract declared iguana model names
    DECLARED=$(yq -r '.slots | to_entries[] | select(.key | startswith("iguana/")) | .value.model' "$MODELS_YML")

    echo "$LIVE_IGUANA" | tail -n +2 | while read -r line; do
        live_model=$(echo "$line" | awk '{print $1}')
        # Check if this model is declared in any slot
        matched=false
        while read -r declared_model; do
            if echo "$live_model" | grep -qi "${declared_model%%:*}" 2>/dev/null; then
                matched=true
                break
            fi
        done <<< "$DECLARED"

        if [ "$matched" = "false" ]; then
            size=$(echo "$line" | awk '{print $3}')
            echo "  UNTRACKED: ${live_model} (${size})"
        fi
    done
    echo ""
fi

echo "=== Done ==="
```

```bash
chmod +x scripts/model-status.sh
```

- [ ] **Step 2: Test the script**

Run: `./scripts/model-status.sh`

Expected: table output showing all declared slots with ok/MISSING status, plus any untracked models on iguana.

- [ ] **Step 3: Commit**

```bash
git add scripts/model-status.sh
git commit -m "feat: add model-status.sh — compare declared vs live state"
```

---

## Task 6: Write `model-plan.sh` — dry-run diff

**Files:**
- Create: `scripts/model-plan.sh`

Shows what `model:apply` would do without making changes.

- [ ] **Step 1: Create `scripts/model-plan.sh`**

```bash
#!/bin/bash
# Dry-run: show what model:apply would do
# Compares models.yml against generated configs and live state
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_YML="${REPO_ROOT}/models.yml"
CONFIGMAP="${REPO_ROOT}/k3s/apps/ai-stack/llama-swap-configmap.yaml"
LITELLM_CONFIG="${REPO_ROOT}/litellm/config.yaml"
MODELS_MD="${REPO_ROOT}/MODELS.md"

KOALA_HOST=$(yq '.hardware.koala.host' "$MODELS_YML")
KOALA_PORT=$(yq '.hardware.koala.llama_swap_port' "$MODELS_YML")
IGUANA_HOST=$(yq '.hardware.iguana.host' "$MODELS_YML")

HAS_CHANGES=false

echo "=== Model Plan (dry-run) ==="
echo ""

# ── 1. Check if configs need regenerating ─────────────────────

# Generate to temp and compare
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Temporarily redirect generate output
CONFIGMAP_SAVE="$CONFIGMAP"
LITELLM_SAVE="$LITELLM_CONFIG"
MODELS_MD_SAVE="$MODELS_MD"

# Run generate to temp files
cp "$MODELS_YML" "$TMPDIR/"
[ -f "${REPO_ROOT}/litellm/extras.yaml" ] && cp "${REPO_ROOT}/litellm/extras.yaml" "$TMPDIR/"

# Compare current generated files vs what would be generated
"${REPO_ROOT}/scripts/model-generate.sh" > /dev/null 2>&1

if ! diff -q "$CONFIGMAP" <(git show HEAD:"k3s/apps/ai-stack/llama-swap-configmap.yaml" 2>/dev/null) > /dev/null 2>&1; then
    echo "CONFIG  llama-swap ConfigMap needs updating"
    HAS_CHANGES=true
fi

if [ -f "$LITELLM_CONFIG" ]; then
    if ! diff -q "$LITELLM_CONFIG" <(git show HEAD:"litellm/config.yaml" 2>/dev/null) > /dev/null 2>&1; then
        echo "CONFIG  LiteLLM config needs updating"
        HAS_CHANGES=true
    fi
fi

# ── 2. Check koala model files ────────────────────────────────

echo ""
echo "── koala actions ──"

KOALA_MODEL_PATH=$(yq '.hardware.koala.model_path' "$MODELS_YML")

yq -r '.slots | to_entries[] | select(.key | startswith("koala/")) | .key' "$MODELS_YML" | while read -r slot_key; do
    model=$(yq ".slots[\"${slot_key}\"].model" "$MODELS_YML")
    file=$(yq ".slots[\"${slot_key}\"].file" "$MODELS_YML")
    model_file="${KOALA_MODEL_PATH}/${model/\//_}_${file}"

    # Check if model file exists on koala
    if ! ssh -o ConnectTimeout=5 mathias@koala "test -f '${model_file}'" 2>/dev/null; then
        echo "  PULL    ${slot_key}: ${model} (${file})"
        HAS_CHANGES=true
    fi
done

# ── 3. Check iguana models ────────────────────────────────────

echo ""
echo "── iguana actions ──"

LIVE_IGUANA=$(ssh -o ConnectTimeout=5 mathias@iguana "ollama list 2>/dev/null" 2>/dev/null || echo "")

yq -r '.slots | to_entries[] | select(.key | startswith("iguana/")) | .key' "$MODELS_YML" | while read -r slot_key; do
    model=$(yq ".slots[\"${slot_key}\"].model" "$MODELS_YML")
    platform=$(yq ".slots[\"${slot_key}\"].platform // \"ollama\"" "$MODELS_YML")

    [ "$platform" != "ollama" ] && [ "$platform" != "null" ] && continue

    if ! echo "$LIVE_IGUANA" | grep -qi "${model%%:*}" 2>/dev/null; then
        echo "  PULL    ${slot_key}: ollama pull ${model}"
        HAS_CHANGES=true
    fi
done

# ── 4. Check for deployment drift ────────────────────────────

echo ""
echo "── deployment actions ──"

# Check if configmap in cluster matches generated one
LIVE_CM=$(kubectl get configmap llama-swap-config -n ai-stack -o yaml 2>/dev/null || echo "")
if [ -n "$LIVE_CM" ]; then
    LIVE_MODELS_YML=$(echo "$LIVE_CM" | yq '.data["models.yml"]')
    GENERATED_MODELS_YML=$(cat "${REPO_ROOT}/k3s/apps/ai-stack/models.yml")
    if [ "$LIVE_MODELS_YML" != "$GENERATED_MODELS_YML" ]; then
        echo "  APPLY   kubectl apply configmap (llama-swap restart required)"
        HAS_CHANGES=true
    fi
fi

echo ""
if [ "$HAS_CHANGES" = "true" ]; then
    echo "Run 'task model:apply' to execute these changes."
else
    echo "Everything is in sync. No changes needed."
fi
```

```bash
chmod +x scripts/model-plan.sh
```

- [ ] **Step 2: Test the script**

Run: `./scripts/model-plan.sh`

Expected: shows planned actions or "Everything is in sync."

- [ ] **Step 3: Commit**

```bash
git add scripts/model-plan.sh
git commit -m "feat: add model-plan.sh — dry-run diff of desired vs live state"
```

---

## Task 7: Write `model-apply.sh` — provisioning with approval gates

**Files:**
- Create: `scripts/model-apply.sh`

Executes the plan: pulls models, applies configs, restarts services, with interactive approval for destructive operations.

- [ ] **Step 1: Create `scripts/model-apply.sh`**

```bash
#!/bin/bash
# Apply model changes: pull models, deploy configs, restart services
# Approval gates for destructive operations
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_YML="${REPO_ROOT}/models.yml"

KOALA_HOST=$(yq '.hardware.koala.host' "$MODELS_YML")
KOALA_PORT=$(yq '.hardware.koala.llama_swap_port' "$MODELS_YML")
IGUANA_HOST=$(yq '.hardware.iguana.host' "$MODELS_YML")
KOALA_MODEL_PATH=$(yq '.hardware.koala.model_path' "$MODELS_YML")

confirm() {
    local prompt="$1"
    echo ""
    read -p "⚠️  ${prompt} [y/N] " -r
    [[ $REPLY =~ ^[Yy]$ ]]
}

echo "=== Applying model changes ==="
echo ""

# ── 1. Regenerate configs ─────────────────────────────────────

echo "── Step 1: Regenerate configs ──"
"${REPO_ROOT}/scripts/model-generate.sh"
echo ""

# ── 2. Pull missing models on koala ───────────────────────────

echo "── Step 2: Pull models (koala) ──"

yq -r '.slots | to_entries[] | select(.key | startswith("koala/")) | .key' "$MODELS_YML" | while read -r slot_key; do
    model=$(yq ".slots[\"${slot_key}\"].model" "$MODELS_YML")
    file=$(yq ".slots[\"${slot_key}\"].file" "$MODELS_YML")
    model_file="${KOALA_MODEL_PATH}/${model/\//_}_${file}"

    if ! ssh -o ConnectTimeout=5 mathias@koala "test -f '${model_file}'" 2>/dev/null; then
        echo "  Downloading ${model}/${file} to koala..."
        ssh mathias@koala "huggingface-cli download '${model}' '${file}' --local-dir '${KOALA_MODEL_PATH}/'"
    else
        echo "  ${file} already present"
    fi
done
echo ""

# ── 3. Pull missing models on iguana ──────────────────────────

echo "── Step 3: Pull models (iguana) ──"

LIVE_IGUANA=$(ssh -o ConnectTimeout=5 mathias@iguana "ollama list 2>/dev/null" 2>/dev/null || echo "")

yq -r '.slots | to_entries[] | select(.key | startswith("iguana/")) | .key' "$MODELS_YML" | while read -r slot_key; do
    model=$(yq ".slots[\"${slot_key}\"].model" "$MODELS_YML")
    platform=$(yq ".slots[\"${slot_key}\"].platform // \"ollama\"" "$MODELS_YML")

    [ "$platform" != "ollama" ] && [ "$platform" != "null" ] && continue

    if ! echo "$LIVE_IGUANA" | grep -qi "${model%%:*}" 2>/dev/null; then
        echo "  Pulling ${model} on iguana..."
        ssh mathias@iguana "ollama pull '${model}'"
    else
        echo "  ${model} already present"
    fi
done
echo ""

# ── 4. Deploy llama-swap ConfigMap ────────────────────────────

echo "── Step 4: Deploy llama-swap ConfigMap ──"

LIVE_CM=$(kubectl get configmap llama-swap-config -n ai-stack -o yaml 2>/dev/null || echo "")
CONFIGMAP="${REPO_ROOT}/k3s/apps/ai-stack/llama-swap-configmap.yaml"

if [ -z "$LIVE_CM" ]; then
    echo "  No existing ConfigMap — applying..."
    kubectl apply -f "$CONFIGMAP"
elif ! diff -q <(echo "$LIVE_CM" | yq '.data["models.yml"]') "${REPO_ROOT}/k3s/apps/ai-stack/models.yml" > /dev/null 2>&1; then
    if confirm "Apply updated llama-swap ConfigMap and restart pod? (affects live inference)"; then
        kubectl apply -f "$CONFIGMAP"

        echo "  Restarting llama-swap pod..."
        kubectl delete pod -n ai-stack \
            $(kubectl get pods -n ai-stack -l app=llama-swap --no-headers | awk '{print $1}') \
            2>/dev/null || true

        echo "  Waiting for rollout..."
        kubectl rollout status deployment/llama-swap -n ai-stack --timeout=120s

        echo "  Verifying models..."
        sleep 5
        curl -sf "http://${KOALA_HOST}:${KOALA_PORT}/v1/models" | python3 -m json.tool | grep '"id"' || echo "  WARNING: could not verify models"
    else
        echo "  Skipped ConfigMap deployment."
    fi
else
    echo "  ConfigMap is up to date."
fi
echo ""

# ── 5. Deploy LiteLLM config ─────────────────────────────────

echo "── Step 5: Deploy LiteLLM config ──"

if confirm "Deploy LiteLLM config to piguard and restart? (affects all model routing)"; then
    "${REPO_ROOT}/litellm/deploy.sh"
else
    echo "  Skipped LiteLLM deployment."
fi
echo ""

# ── 6. Commit changes ────────────────────────────────────────

echo "── Step 6: Commit ──"

cd "$REPO_ROOT"
git add -A k3s/apps/ai-stack/ litellm/config.yaml MODELS.md
if git diff --cached --quiet; then
    echo "  No changes to commit."
else
    git commit -m "chore: update model configs from models.yml"
    echo "  Committed."
fi

echo ""
echo "=== Apply complete ==="
echo "Run 'task model:status' to verify."
```

```bash
chmod +x scripts/model-apply.sh
```

- [ ] **Step 2: Review the script for correctness**

Read through the script. Verify:
- HuggingFace download command builds the right path
- ConfigMap diff logic matches what `model-generate.sh` produces
- Approval gates are on all destructive operations

- [ ] **Step 3: Commit**

```bash
git add scripts/model-apply.sh
git commit -m "feat: add model-apply.sh — provisioning with approval gates"
```

---

## Task 8: Write benchmark scripts

**Files:**
- Create: `scripts/bench/run-bench.sh`
- Create: `scripts/bench/prompts/code-completion.txt`
- Create: `scripts/bench/prompts/instruction-following.txt`

- [ ] **Step 1: Create benchmark prompts**

`scripts/bench/prompts/code-completion.txt`:
```
Write a Go function that takes a slice of integers and returns the top K elements in descending order. Use a min-heap for O(n log k) complexity. Include the heap implementation — do not use container/heap.
```

`scripts/bench/prompts/instruction-following.txt`:
```
Explain the difference between a mutex and a semaphore. Give one concrete example where each is the better choice. Keep your answer under 200 words.
```

- [ ] **Step 2: Create `scripts/bench/run-bench.sh`**

```bash
#!/bin/bash
# Benchmark a model slot: tok/s, TTFT, VRAM, context stress
# Usage: run-bench.sh <slot-name>
#   e.g.: run-bench.sh koala/fast-coder
#         run-bench.sh iguana/quality-coder
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODELS_YML="${REPO_ROOT}/models.yml"
RESULTS_FILE="${REPO_ROOT}/benchmarks/results.jsonl"
PROMPTS_DIR="$(cd "$(dirname "$0")/prompts" && pwd)"

SLOT="${1:?Usage: run-bench.sh <slot-name> (e.g. koala/fast-coder)}"

# Resolve slot config
MACHINE="${SLOT%%/*}"
MODEL=$(yq ".slots[\"${SLOT}\"].model" "$MODELS_YML")
LITELLM_NAME=$(yq ".slots[\"${SLOT}\"].litellm_name" "$MODELS_YML")
MIN_TOK_S=$(yq ".slots[\"${SLOT}\"].benchmark_targets.min_tok_s // 0" "$MODELS_YML")

if [ "$MODEL" = "null" ]; then
    echo "ERROR: slot '${SLOT}' not found in models.yml"
    exit 1
fi

echo "=== Benchmarking ${SLOT} ==="
echo "  Model: ${MODEL}"
echo "  LiteLLM name: ${LITELLM_NAME}"
echo "  Target: >= ${MIN_TOK_S} tok/s"
echo ""

# Determine API endpoint
if [ "$MACHINE" = "koala" ]; then
    HOST=$(yq '.hardware.koala.host' "$MODELS_YML")
    PORT=$(yq '.hardware.koala.llama_swap_port' "$MODELS_YML")
    API_BASE="http://${HOST}:${PORT}/v1"
elif [ "$MACHINE" = "iguana" ]; then
    HOST=$(yq '.hardware.iguana.host' "$MODELS_YML")
    PORT=$(yq '.hardware.iguana.ollama_port' "$MODELS_YML")
    API_BASE="http://${HOST}:${PORT}/v1"
else
    echo "ERROR: unknown machine '${MACHINE}'"
    exit 1
fi

# ── Throughput benchmark (3 runs) ─────────────────────────────

echo "── Throughput (3 runs, ~500 tokens each) ──"

PROMPT=$(cat "${PROMPTS_DIR}/code-completion.txt")
TOTAL_TOKS=0
TOTAL_TIME=0
TTFT_TOTAL=0

for run in 1 2 3; do
    # Use curl with timing to measure TTFT and total time
    START=$(date +%s%N)

    RESPONSE=$(curl -sf "${API_BASE}/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$(cat <<JSON
{
    "model": "${LITELLM_NAME##*/}",
    "messages": [{"role": "user", "content": $(echo "$PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}],
    "max_tokens": 512,
    "temperature": 0.1
}
JSON
)" 2>/dev/null)

    END=$(date +%s%N)

    if [ -z "$RESPONSE" ]; then
        echo "  Run ${run}: FAILED (no response)"
        continue
    fi

    TOKENS=$(echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('usage',{}).get('completion_tokens',0))" 2>/dev/null || echo 0)
    ELAPSED_MS=$(( (END - START) / 1000000 ))
    ELAPSED_S=$(echo "scale=2; $ELAPSED_MS / 1000" | bc)

    if [ "$TOKENS" -gt 0 ] && [ "$ELAPSED_MS" -gt 0 ]; then
        TOK_S=$(echo "scale=1; $TOKENS * 1000 / $ELAPSED_MS" | bc)
        TOTAL_TOKS=$((TOTAL_TOKS + TOKENS))
        TOTAL_TIME=$((TOTAL_TIME + ELAPSED_MS))
        echo "  Run ${run}: ${TOKENS} tokens in ${ELAPSED_S}s = ${TOK_S} tok/s"
    else
        echo "  Run ${run}: ${TOKENS} tokens in ${ELAPSED_S}s (could not calculate tok/s)"
    fi
done

if [ "$TOTAL_TIME" -gt 0 ]; then
    AVG_TOK_S=$(echo "scale=1; $TOTAL_TOKS * 1000 / $TOTAL_TIME" | bc)
else
    AVG_TOK_S=0
fi

echo ""
echo "  Average: ${AVG_TOK_S} tok/s"

# ── VRAM check (koala only) ───────────────────────────────────

VRAM_GB="N/A"
if [ "$MACHINE" = "koala" ]; then
    echo ""
    echo "── VRAM usage ──"
    VRAM_MIB=$(ssh -o ConnectTimeout=5 mathias@koala \
        "nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits" 2>/dev/null || echo "0")
    VRAM_GB=$(echo "scale=1; ${VRAM_MIB} / 1024" | bc)
    VRAM_TOTAL=$(ssh -o ConnectTimeout=5 mathias@koala \
        "nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits" 2>/dev/null || echo "0")
    VRAM_TOTAL_GB=$(echo "scale=1; ${VRAM_TOTAL} / 1024" | bc)
    echo "  ${VRAM_GB} / ${VRAM_TOTAL_GB} GB"
fi

# ── Context stress test ───────────────────────────────────────

echo ""
echo "── Context stress test ──"

SHORT_PROMPT="Respond with just 'ok'."
for ctx_target in 8192 16384 32768 65536 131072 262144; do
    # Build a prompt that's roughly ctx_target tokens (4 chars per token estimate)
    PADDING_LEN=$((ctx_target * 3))
    if [ "$PADDING_LEN" -gt 1000000 ]; then
        # Skip very large contexts — too slow to generate padding
        echo "  ${ctx_target} tokens: skipped (too large for quick test)"
        continue
    fi

    PADDED_PROMPT="${SHORT_PROMPT} $(head -c $PADDING_LEN /dev/urandom | base64 | head -c $PADDING_LEN)"

    RESPONSE=$(curl -sf --max-time 30 "${API_BASE}/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$(cat <<JSON
{
    "model": "${LITELLM_NAME##*/}",
    "messages": [{"role": "user", "content": $(echo "$PADDED_PROMPT" | head -c $((ctx_target * 4)) | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}],
    "max_tokens": 16
}
JSON
)" 2>/dev/null || echo "")

    if [ -n "$RESPONSE" ] && echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('choices')" 2>/dev/null; then
        echo "  ${ctx_target} tokens: ok"
    else
        echo "  ${ctx_target} tokens: FAILED"
        break
    fi
done

# ── Result verdict ────────────────────────────────────────────

echo ""
echo "── Result ──"

PASS="true"
if [ "$MIN_TOK_S" != "0" ]; then
    if (( $(echo "$AVG_TOK_S < $MIN_TOK_S" | bc -l) )); then
        echo "  FAIL: ${AVG_TOK_S} tok/s < target ${MIN_TOK_S} tok/s"
        PASS="false"
    else
        echo "  PASS: ${AVG_TOK_S} tok/s >= target ${MIN_TOK_S} tok/s"
    fi
else
    echo "  No throughput target defined."
fi

# ── Log result ────────────────────────────────────────────────

mkdir -p "$(dirname "$RESULTS_FILE")"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "{\"timestamp\":\"${TIMESTAMP}\",\"slot\":\"${SLOT}\",\"model\":\"${MODEL}\",\"tok_s\":${AVG_TOK_S},\"vram_gb\":\"${VRAM_GB}\",\"pass\":${PASS}}" >> "$RESULTS_FILE"
echo "  Result logged to ${RESULTS_FILE}"
```

```bash
chmod +x scripts/bench/run-bench.sh
mkdir -p scripts/bench/prompts
```

- [ ] **Step 3: Test with a live slot**

Run: `./scripts/bench/run-bench.sh koala/fast-coder`

Expected: throughput numbers, VRAM reading, context stress results, result logged to `benchmarks/results.jsonl`.

- [ ] **Step 4: Commit**

```bash
git add scripts/bench/ benchmarks/
git commit -m "feat: add benchmark scripts — tok/s, VRAM, context stress"
```

---

## Task 9: Create the Taskfile

**Files:**
- Create: `Taskfile.yml`

Ties all scripts together with clean task names.

- [ ] **Step 1: Create `Taskfile.yml`**

```yaml
version: '3'

vars:
  SCRIPTS_DIR: ./scripts

tasks:
  model:generate:
    desc: Regenerate all configs from models.yml (no deployment)
    cmds:
      - "{{.SCRIPTS_DIR}}/model-generate.sh"

  model:status:
    desc: Compare models.yml vs live state on all machines
    cmds:
      - "{{.SCRIPTS_DIR}}/model-status.sh"

  model:plan:
    desc: "Dry-run: show what model:apply would do"
    cmds:
      - "{{.SCRIPTS_DIR}}/model-plan.sh"

  model:apply:
    desc: Execute provisioning plan with approval gates
    cmds:
      - "{{.SCRIPTS_DIR}}/model-apply.sh"

  model:eval:
    desc: "Benchmark a model slot (usage: task model:eval -- koala/fast-coder)"
    cmds:
      - "{{.SCRIPTS_DIR}}/bench/run-bench.sh {{.CLI_ARGS}}"

  model:remove:
    desc: "Remove a model from a machine (usage: task model:remove -- iguana/model-name)"
    cmds:
      - |
        SLOT="{{.CLI_ARGS}}"
        MACHINE="${SLOT%%/*}"
        MODEL="${SLOT#*/}"
        if [ -z "$MODEL" ] || [ "$MODEL" = "$SLOT" ]; then
          echo "Usage: task model:remove -- <machine>/<model>"
          echo "  e.g.: task model:remove -- iguana/glm-4.7-flash"
          exit 1
        fi
        echo ""
        read -p "⚠️  Remove ${MODEL} from ${MACHINE}? [y/N] " -r
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
          echo "Cancelled."
          exit 0
        fi
        case "$MACHINE" in
          iguana)
            ssh mathias@iguana "ollama rm '${MODEL}'"
            ;;
          koala)
            echo "koala model removal: delete the GGUF file manually from /data/models/huggingface/"
            echo "  ssh mathias@koala 'ls /data/models/huggingface/*${MODEL}*'"
            ;;
          *)
            echo "Unknown machine: ${MACHINE}"
            exit 1
            ;;
        esac
        echo "Done. Update models.yml if this was a slot holder, then run: task model:generate"
```

- [ ] **Step 2: Verify Taskfile is valid**

Run: `task --list`

Expected output:
```
task: Available tasks for this project:
* model:apply:       Execute provisioning plan with approval gates
* model:eval:        Benchmark a model slot (usage: task model:eval -- koala/fast-coder)
* model:generate:    Regenerate all configs from models.yml (no deployment)
* model:plan:        Dry-run: show what model:apply would do
* model:remove:      Remove a model from a machine (usage: task model:remove -- iguana/model-name)
* model:status:      Compare models.yml vs live state on all machines
```

- [ ] **Step 3: Commit**

```bash
git add Taskfile.yml
git commit -m "feat: add Taskfile with model management commands"
```

---

## Task 10: Integration test — end-to-end generate and verify

**Files:**
- No new files — testing existing scripts together

This task validates the full pipeline works before migrating LiteLLM.

- [ ] **Step 1: Run config generation**

```bash
task model:generate
```

Verify outputs exist and look correct:
- `k3s/apps/ai-stack/llama-swap-configmap.yaml`
- `k3s/apps/ai-stack/models.yml`
- `litellm/config.yaml`
- `MODELS.md`

- [ ] **Step 2: Compare generated llama-swap ConfigMap with current**

```bash
diff <(git show HEAD:k3s/apps/ai-stack/llama-swap-configmap.yaml) k3s/apps/ai-stack/llama-swap-configmap.yaml
```

Verify model names, ports, and parameters are equivalent. Minor whitespace differences are acceptable.

- [ ] **Step 3: Run status check**

```bash
task model:status
```

Verify all koala slots show "ok" and iguana slots show correct state.

- [ ] **Step 4: Run plan**

```bash
task model:plan
```

Should show "Everything is in sync" if no changes are needed, or list specific actions.

- [ ] **Step 5: Run a benchmark**

```bash
task model:eval -- koala/fast-coder
```

Verify tok/s output, VRAM reading, and result logged to `benchmarks/results.jsonl`.

- [ ] **Step 6: Fix any issues found during testing, commit fixes**

```bash
git add -A
git commit -m "fix: address integration test findings"
```

---

## Task 11: Migrate LiteLLM config from piguard

**Files:**
- Modify: `litellm/extras.yaml` (populate with real piguard config)

This is the final migration step — making this repo the source of truth for LiteLLM.

- [ ] **Step 1: Retrieve and review current piguard config**

```bash
ssh mathias@piguard "cat ~/litellm-infra/config.yaml" > /tmp/piguard-litellm-config.yaml
cat /tmp/piguard-litellm-config.yaml
```

Identify: which routes correspond to model slots (will be generated), which are cloud/extra routes (go in `extras.yaml`), and what general settings exist.

- [ ] **Step 2: Update `litellm/extras.yaml` with real values**

Move cloud routes and general settings from piguard config into `extras.yaml`. Remove any routes that correspond to slots in `models.yml` — those will be generated.

- [ ] **Step 3: Regenerate and compare**

```bash
task model:generate
diff /tmp/piguard-litellm-config.yaml litellm/config.yaml
```

The generated config should have all the same routes as piguard, potentially in a different order. Verify no routes are missing.

- [ ] **Step 4: Deploy to piguard**

```bash
litellm/deploy.sh
```

Verify LiteLLM is healthy and routing works:
```bash
curl -sf http://piguard:4000/v1/models -H "Authorization: Bearer $DMABE_LLMAPI_KEY" | python3 -m json.tool | grep '"id"'
```

- [ ] **Step 5: Commit**

```bash
git add litellm/extras.yaml litellm/config.yaml
git commit -m "feat: migrate litellm config from piguard — this repo is now source of truth"
```

- [ ] **Step 6: Archive old litellm-infra repo on gitea**

Add a note to the README of `litellm-infra` on gitea pointing to this repo, or archive the repo.

---

## Task 12: Clean up old scripts and update docs

**Files:**
- Modify: `docs/network.md` (update LiteLLM and llama-swap sections)
- Modify: `scripts/update-models.sh` (deprecation notice)

- [ ] **Step 1: Add deprecation notice to `update-models.sh`**

Add to the top of `scripts/update-models.sh`:

```bash
echo "DEPRECATED: Use 'task model:apply' instead. See Taskfile.yml."
echo "This script will be removed in a future cleanup."
exit 1
```

- [ ] **Step 2: Update `docs/network.md` LiteLLM section**

Replace the LiteLLM section with:

```markdown
## LiteLLM

LiteLLM runs on **piguard** via Docker Compose.

- **Config source of truth**: `litellm/config.yaml` in this repo (generated from `models.yml`)
- **Deploy**: `litellm/deploy.sh` (scp + restart)
- **Port**: 4000 (accessed as `http://piguard:4000`)
- **API key**: `DMABE_LLMAPI_KEY`
- **Management**: `task model:generate` regenerates config, `task model:apply` deploys it
```

- [ ] **Step 3: Update `docs/network.md` llama-swap section**

Replace with:

```markdown
## llama-swap

llama-swap runs on **koala** at port **31234**, managing GPU model loading/unloading.

- **Config source of truth**: `models.yml` in repo root (koala slots)
- **ConfigMap**: `k3s/apps/ai-stack/llama-swap-configmap.yaml` (generated, do not edit directly)
- **Management**: `task model:apply` regenerates ConfigMap, restarts pod, and commits
- **Status**: `task model:status` shows live vs declared state
```

- [ ] **Step 4: Commit**

```bash
git add scripts/update-models.sh docs/network.md
git commit -m "chore: deprecate update-models.sh, update docs for new model management"
```
