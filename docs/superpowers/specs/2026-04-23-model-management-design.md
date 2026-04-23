# Model Management Tooling — Design Spec

## Problem

Managing models across koala (llama-swap/k8s), iguana (Ollama), and piguard (LiteLLM routing) is manual and error-prone. Adding or swapping a model touches 3+ systems with no coordination, no validation, and no single source of truth. Parameters are guessed, LiteLLM drifts out of sync, old models accumulate, and MODELS.md is aspirational documentation rather than ground truth.

## Goals

1. **Single source of truth** — one config file declares all model slots, parameters, and routes
2. **Generated configs** — llama-swap ConfigMap, LiteLLM config, and MODELS.md are all derived, never hand-edited
3. **Automated provisioning** — pulling, configuring, deploying, and benchmarking models via Taskfile commands
4. **Approval gates** — destructive operations (delete, swap live slot, deploy routing changes) require explicit confirmation
5. **Collaborative research** — model discovery and evaluation happens conversationally; execution is automated
6. **Parameter knowledge** — proven parameter profiles for koala's 12GB VRAM accumulate in the repo

## Non-Goals

- Full benchmark suites (HumanEval, MMLU, etc.) — published benchmarks are checked during research, not re-run locally
- VRAM calculator — too model-specific to be reliable; use empirical profiles instead
- GUI or web interface — CLI-first, Taskfile commands
- Auto-discovery of new models — research phase is human-driven (with Claude as research partner)

---

## Architecture

### Source of Truth: `models.yml`

A single YAML file at the repo root declares all model slots across all machines.

```yaml
hardware:
  koala:
    gpu: "RTX 5070"
    vram_gb: 12
    ram_gb: 64
    platform: llama-swap    # managed via k8s ConfigMap
    access: kubectl
    host: "10.0.1.20"
    llama_swap_port: 31234
  iguana:
    gpu: "M2 Ultra"
    unified_memory_gb: 64
    platform: ollama
    access: ssh
    host: "10.0.1.25"
    ollama_port: 11434

slots:
  koala/fast-coder:
    model: "unsloth/Qwen3.5-9B-GGUF"
    file: "Qwen3.5-9B-UD-Q4_K_XL.gguf"
    litellm_name: "koala/qwen35-9b-fast"
    port: 5805
    params:
      ctx_size: 262144
      ngl: 99
      batch_size: 2048
      ubatch_size: 512
      cache_type_k: q4_0
      cache_type_v: q4_0
      flash_attn: true
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
    params:
      ctx_size: 32768
      ngl: 10
      batch_size: 128
      ubatch_size: 64
      cache_type_k: q8_0
      cache_type_v: q5_0
      flash_attn: true
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
    params:
      ctx_size: 8192
      ngl: 60
      batch_size: 512
      ubatch_size: 128
      cache_type_k: q8_0
      cache_type_v: f16
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
    params:
      ctx_size: 8192
      ngl: 64
      batch_size: 448
      ubatch_size: 128
      cache_type_k: q8_0
      cache_type_v: f16
    sampling:
      temp: 0.2
      top_p: 0.9
      top_k: 64
      repeat_penalty: 1.05

  iguana/quality-coder:
    model: "qwen3-coder-next"
    litellm_name: "qwen3-coder-next"
    params:
      num_ctx: 65536
    benchmark_targets:
      min_tok_s: 15

  iguana/general:
    model: "qwen3.5:35b"
    litellm_name: "qwen3.5-35b"
    params:
      num_ctx: 32768
    benchmark_targets:
      min_tok_s: 20

  iguana/reasoning:
    model: "deepseek-r1-tuned"
    litellm_name: "deepseek-r1-tuned"
    params:
      num_ctx: 16384
    benchmark_targets:
      min_tok_s: 15

  iguana/embed:
    model: "nomic-embed-text"
    litellm_name: "nomic-embed"
    type: embedding

  iguana/rerank:
    model: "Qwen3-Reranker-0.6B"
    litellm_name: "iguana/rerank"
    type: reranker

  iguana/stt:
    model: "mlx-community/whisper-large-v3-mlx"
    litellm_name: "iguana/whisper"
    platform: mlx-openai-server
    port: 8100
    type: stt
```

### Generated Configs

Three outputs are generated from `models.yml` by `task model:generate`:

| Output | Source slots | Deployed to |
|--------|-------------|-------------|
| `k3s/apps/ai-stack/llama-swap-configmap.yaml` | `koala/*` slots | koala k3s cluster (kubectl apply) |
| `litellm/config.yaml` | All slots + `litellm/extras.yaml` | piguard (scp + docker compose restart) |
| `MODELS.md` | All slots + hardware | This repo (documentation) |

**`litellm/extras.yaml`** — manually maintained, merged into generated config:
- Cloud provider routes (berget.ai, etc.)
- LiteLLM general settings (rate limits, logging, auth)
- Any routing that doesn't map to a model slot

### LiteLLM Migration

The `litellm-infra` repo on gitea is absorbed into this repo:

1. Copy current `config.yaml` from piguard
2. Extract non-route settings into `litellm/extras.yaml`
3. Verify `task model:generate` produces equivalent routing
4. Deploy, confirm LiteLLM works
5. Archive `litellm-infra` repo on gitea

---

## Directory Structure

```
infra/
├── models.yml                          # SOURCE OF TRUTH
├── Taskfile.yml                        # model management commands
├── litellm/
│   ├── config.yaml                     # GENERATED
│   ├── extras.yaml                     # manual: cloud routes, general settings
│   └── deploy.sh                       # scp to piguard + restart
├── params/
│   └── koala-profiles.yml              # known-good parameter profiles
├── scripts/
│   ├── generate-configs.sh             # models.yml → all generated files
│   ├── model-plan.sh                   # diff desired vs live state
│   ├── model-apply.sh                  # execute provisioning with gates
│   ├── model-status.sh                 # query live state across machines
│   ├── update-models.sh                # EXISTING — will be replaced by model-apply
│   └── bench/
│       ├── run-bench.sh                # throughput, TTFT, VRAM, context tests
│       └── prompts/                    # standard test prompts per slot type
│           ├── code-completion.txt
│           ├── instruction-following.txt
│           └── reasoning.txt
├── benchmarks/
│   └── results.jsonl                   # append-only benchmark log
├── k3s/apps/ai-stack/
│   ├── llama-swap-configmap.yaml       # GENERATED
│   ├── llama-swap-deployment.yaml      # existing
│   └── models.yml                      # GENERATED (mirror)
├── MODELS.md                           # GENERATED
└── docs/
```

---

## Taskfile Commands

```yaml
# Taskfile.yml
version: '3'

tasks:
  model:status:
    desc: Compare models.yml vs live state on all machines
    # Queries koala (kubectl + llama-swap API) and iguana (ollama list)
    # Shows: declared slots, what's actually loaded, any drift

  model:plan:
    desc: Dry-run — show what model:apply would do
    # Diffs models.yml against live state
    # Output: PULL / REMOVE / UPDATE / RECONFIGURE actions per slot
    # No side effects

  model:apply:
    desc: Execute provisioning plan with approval gates
    # 1. Run model:plan to determine actions
    # 2. Pull new models (koala: HF download, iguana: ollama pull)
    # 3. Generate configs (configmap, litellm, MODELS.md)
    # 4. Apply configmap, restart llama-swap pod
    # 5. Deploy litellm config to piguard, restart
    # 6. APPROVAL GATE: delete old model files
    # 7. Run quick benchmark to verify
    # 8. Git commit

  model:eval:
    desc: Benchmark a model against its slot targets
    # Usage: task model:eval -- <slot-name>
    # Measures: tok/s, TTFT, VRAM, context stress test
    # Compares against benchmark_targets from models.yml
    # Appends results to benchmarks/results.jsonl

  model:remove:
    desc: Remove a model (approval required)
    # Usage: task model:remove -- <slot-name>
    # APPROVAL GATE: confirm before deleting
    # Updates models.yml, regenerates configs, deploys

  model:generate:
    desc: Regenerate all configs from models.yml (no deployment)
    # Pure generation, no side effects
    # Useful for reviewing what configs would look like
```

### Approval Gates

Interactive confirmation (`read -p`) required before:

- Deleting model files from disk
- Swapping a slot that currently has a model loaded
- Deploying LiteLLM config changes to piguard (affects all routing)

No confirmation needed for:

- Pulling new models
- Generating configs
- Running benchmarks
- Git commits to this repo

---

## Evaluation & Benchmarks

### Local Benchmarks (`task model:eval`)

Measured automatically during provisioning:

| Metric | How | koala | iguana |
|--------|-----|-------|--------|
| tok/s | Timed 500-token generation, 3-run average | llama-swap `/completion` API | ollama `/api/generate` |
| TTFT | Time to first token | Same APIs | Same APIs |
| VRAM usage | nvidia-smi (peak during generation) | `kubectl exec` nvidia-smi | N/A (unified memory) |
| Memory usage | Process RSS | kubectl top | `ollama ps` |
| Context stress | Progressive prompt sizes until failure | 8k → 16k → 32k → 64k → 128k → 256k | Same |
| Basic quality | Standard prompts, check for coherent output | Code completion + instruction following | Same |

Results are appended to `benchmarks/results.jsonl`:

```json
{"timestamp":"2026-04-23T14:30:00Z","slot":"koala/fast-coder","model":"Qwen3.5-9B-UD-Q4_K_XL","tok_s":58.2,"ttft_ms":142,"vram_gb":5.6,"max_ctx":262144}
```

### Research-Phase Evaluation (Conversational)

During model research conversations, we check:

- Published benchmarks (HumanEval, MBPP, MMLU, etc.) from model cards on HuggingFace
- Quantization options and sizes — will it fit the target hardware?
- Parameter profile match — which `koala-profiles.yml` profile applies?
- Community feedback (Reddit, HF discussions) for real-world quality signals

---

## Parameter Profiles

`params/koala-profiles.yml` — empirical reference for koala's 12GB VRAM:

```yaml
profiles:
  gpu-resident-small:
    description: "Models <=6GB, fully GPU-resident"
    fits: "Q4 quants up to ~9B dense, Q8 up to ~3B"
    ngl: 99
    batch_size: 2048
    ubatch_size: 512
    cache_type_k: q4_0
    cache_type_v: q4_0
    flash_attn: true
    notes: "Can push ctx_size high (128k+)"

  gpu-resident-medium:
    description: "Models 6-10GB, fits in VRAM with careful params"
    fits: "Q4 quants 9-14B dense"
    ngl: 60-64
    batch_size: 448-512
    ubatch_size: 128
    cache_type_k: q8_0
    cache_type_v: f16
    notes: "ctx_size 8k-16k safe, 32k possible with q4_0 KV cache"

  partial-offload:
    description: "Models >10GB, partial GPU offload"
    fits: "MoE models, large dense Q4"
    ngl: 10-20
    batch_size: 128
    ubatch_size: 64
    cache_type_k: q8_0
    cache_type_v: q5_0
    flash_attn: true
    notes: "Slower but quality trade-off. ctx_size 16-32k max"
```

These profiles are reference material, not automation. When adding a model to `models.yml`, you pick a profile as a starting point and set specific values. Profiles are updated when benchmarking reveals better settings.

---

## Workflow Summary

```
Research (conversational)          Provisioning (automated)
┌─────────────────────────┐       ┌──────────────────────────────┐
│                         │       │                              │
│ 1. Discover model       │       │ 4. task model:plan           │
│    (HF, Ollama, Unsloth)│       │    (dry-run, show diff)      │
│                         │       │                              │
│ 2. Check benchmarks,    │       │ 5. task model:apply          │
│    size, quantizations  │──────>│    (pull, configure, deploy) │
│                         │ edit  │    (approval gates)          │
│ 3. Agree on slot +      │models │                              │
│    target machine       │.yml   │ 6. task model:eval           │
│                         │       │    (benchmark, compare)      │
└─────────────────────────┘       │                              │
                                  │ 7. Results logged, configs   │
                                  │    committed, MODELS.md      │
                                  │    updated                   │
                                  └──────────────────────────────┘
```

---

## Migration Steps

1. Create `models.yml` from current state (existing `models.yml` + Ollama models + MODELS.md)
2. Copy LiteLLM config from piguard, split into generated routes + `extras.yaml`
3. Write `generate-configs.sh`, verify it produces equivalent configs
4. Build Taskfile with `model:generate` and `model:status` first
5. Add `model:plan` and `model:apply`
6. Add `model:eval` with benchmark scripts
7. Replace `update-models.sh` with the new workflow
8. Archive `litellm-infra` repo on gitea
