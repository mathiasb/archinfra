# Model Management

Slot-based model management for the homelab AI stack.
Each slot has exactly one model. When a better model arrives, evaluate it, swap if it wins, delete the old one.

---

## Hardware Profiles

| Machine | GPU/Memory | Best For |
|---|---|---|
| koala | RTX 5070 12GB VRAM + 64GB DDR5 RAM | Fast GPU inference, small-medium dense models |
| iguana | M2 Ultra 64GB unified memory | Large models, long context, quality over speed |
| piguard | Raspberry Pi 4 | Routing only (LiteLLM), no inference |

---

## Model Slots

### koala (llama-swap, via LiteLLM as `koala/`)

| Slot | LiteLLM name | Current model | Criteria |
|---|---|---|---|
| fast-coder | `koala/qwen35-9b-fast` | qwen3.5-9B UD-Q4_K_XL | Best dense coding model ≤6GB VRAM, fully GPU-resident |
| quality-coder | `koala/qwen3-coder-30b` | Qwen3-Coder-30B-A3B UD-Q4_K_XL | Best MoE coding model, partial GPU offload |
| fast-general | `koala/phi4-mini` | Phi-4-mini | Fastest general model, tool calls, lightweight tasks |
| general | `koala/phi4-14b` | Phi-4 14B | Quality general model, fits in VRAM |

### iguana (Ollama, via LiteLLM as `iguana/` or direct)

| Slot | LiteLLM name | Current model | Criteria |
|---|---|---|---|
| quality-coder | `qwen3-coder-next` | Qwen3-Coder-Next 51GB | Best large coding model, long context agentic work |
| general | `qwen3.5-35b` | Qwen3.5-35B | Best general model ≤30GB, reasoning + chat |
| reasoning | `deepseek-r1-tuned` | DeepSeek-R1 14B tuned | Best reasoning/thinking model ≤15GB |
| embed | `nomic-embed` | nomic-embed-text | Embeddings for RAG |
| rerank | `iguana/rerank` | Qwen3-Reranker-0.6B | Search result reranking |

### iguana (mlx-openai-server)

| Slot | Endpoint | Current model | Criteria |
|---|---|---|---|
| stt | `http://iguana:8100/v1` | whisper-large-v3-mlx | Best STT, Neural Engine accelerated |

---

## Use Case → Model Mapping

| Use case | Primary | Fallback |
|---|---|---|
| Agentic coding (fast, many tool calls) | `koala/qwen35-9b-fast` | `koala/qwen3-coder-30b` |
| Agentic coding (quality, complex tasks) | `qwen3-coder-next` | `koala/qwen3-coder-30b` |
| Chat / general assistant (OpenWebUI) | `qwen3.5-35b` | `koala/phi4-14b` |
| Reasoning / planning | `deepseek-r1-tuned` | `qwen3.5-35b` |
| Embeddings (RAG) | `nomic-embed` | — |
| Reranking | `iguana/rerank` | — |
| Speech to text | `iguana/whisper` | — |
| Quick one-off tasks | `koala/phi4-mini` | `koala/qwen35-9b-fast` |

---

## Current Model Inventory

### iguana

| Model | Size | Slot | Status |
|---|---|---|---|
| qwen3-coder-next | 51GB | quality-coder | ✅ keep |
| qwen3.5:35b | 23GB | general | ✅ keep |
| devstral-tuned | 15GB | coding alt | ✅ keep (agentic coding alternative) |
| deepseek-r1-tuned | 9GB | reasoning | ✅ keep |
| qwen3-14b-tuned | 9.3GB | — | ⚠️ redundant (koala has qwen3-14b incoming) |
| nomic-embed-text | 274MB | embed | ✅ keep |
| Qwen3-Reranker-0.6B | 1.2GB | rerank | ✅ keep |
| gemma4:26b | 17GB | — | ⚠️ review — no clear slot |
| gemma4:31b | 19GB | — | ⚠️ duplicate of above, remove one |
| glm-4.7-flash | 31GB | — | ❌ remove — poor perf (28 tok/s), no slot |
| glm-4.7-flash-chat | 31GB | — | ❌ remove — duplicate of above |
| gpt-oss:20b | 13GB | — | ⚠️ review — redundant with qwen3-coder-next |
| qwen3-coder-30b-tuned | 17GB | — | ⚠️ redundant — koala already has this |
| LFM2.5-1.2B | 2.3GB | — | ❌ remove — too small, no slot |

### koala

| Model | Size | Slot | Status |
|---|---|---|---|
| qwen3.5-9B UD-Q4_K_XL | ~6GB | fast-coder | ✅ keep |
| Qwen3-Coder-30B UD-Q4_K_XL | ~19GB | quality-coder | ✅ keep |
| Phi-4-mini | ~4GB | fast-general | ✅ keep |
| Phi-4 14B | ~9GB | general | ✅ keep |
| llama-3.2-3b | ~2GB | — | ⚠️ review — superseded by phi4-mini |
| deepseek-coder-v2-lite | ~9GB | — | ⚠️ review — redundant with qwen3-coder-30b |

---

## Model Evaluation Process

### When to evaluate a new model

- Listed on Hugging Face trending or Ollama library
- Claims >10% improvement on coding/reasoning benchmarks vs current slot holder
- Fits within slot's hardware constraints

### Evaluation steps

```bash
# 1. Pull the model
ollama pull <model>  # iguana
# or
huggingface-cli download <repo> <file> --local-dir /data/models/huggingface/  # koala

# 2. Run autotune benchmark (iguana)
cd ~/benchmarks
# run autotune script against new model

# 3. Compare tok/s and quality against current slot holder

# 4. If new model wins: update slot, delete old model
ollama rm <old-model>

# 5. Update this file and LiteLLM config on piguard
```

### Benchmark targets by slot

| Slot | Min tok/s (iguana) | Min tok/s (koala GPU) |
|---|---|---|
| fast-coder | — | >50 tok/s |
| quality-coder | >15 tok/s | >10 tok/s |
| general | >20 tok/s | — |
| reasoning | >15 tok/s | — |

---

## Cleanup Actions (pending)

- [ ] Remove `glm-4.7-flash` and `glm-4.7-flash-chat` from iguana (62GB freed)
- [ ] Remove `LFM2.5-1.2B` from iguana
- [ ] Decide on `gemma4` — keep 26b or 31b, not both
- [ ] Decide on `gpt-oss:20b` — keep or remove
- [ ] Remove `qwen3-coder-30b-tuned` from iguana (koala handles this)
- [ ] Remove `qwen3-14b-tuned` from iguana once koala qwen3-14b is set up
- [ ] Remove `llama-3.2-3b` from koala if phi4-mini covers its use cases
- [ ] Remove `deepseek-coder-v2-lite` from koala if qwen3-coder-30b covers its use cases

---

## LiteLLM Config Location

`/home/mathias/litellm-infra/config.yaml` on piguard.
Update whenever slots change. Restart LiteLLM after changes:

```bash
ssh mathias@piguard "cd /home/mathias/litellm-infra && docker compose restart litellm"
```
