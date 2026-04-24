# Model Inventory

> Auto-generated from `models.yml` — do not edit manually.
> Regenerate with: `scripts/model-generate.sh`

## Hardware Profiles

| Machine | GPU | Memory | Platform | Host |
|---------|-----|--------|----------|------|
| koala | RTX 5070 | 12 GB VRAM, 64 GB RAM | llama-swap | 10.0.1.20:31234 |
| iguana | M2 Ultra | 64 GB unified | ollama | 10.0.1.25:11434 |

## koala — llama-swap (k3s)

| Slot | Model | LiteLLM Name | Port | Context | Use Case |
|------|-------|-------------|------|---------|----------|
| quality-coder | unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF | `koala/qwen3-coder-30b` | 5800 | 32768 | Agentic coding (quality, complex tasks) |
| fast-general | unsloth/Phi-4-mini-instruct-GGUF | `koala/phi4-mini` | 5801 | 8192 | Quick one-off tasks, tool calls |
| general | bartowski/phi-4-GGUF | `koala/phi4-14b` | 5802 | 8192 | Chat / general assistant |
| llama-3.2-3b | bartowski/Llama-3.2-3B-Instruct-GGUF | `koala/llama-3.2-3b` | 5803 | 8192 | Lightweight inference (under review — may be superseded by phi4-mini) |
| deepseek-coder-v2-lite | bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF | `koala/deepseek-coder-v2-lite` | 5804 | 12000 | Coding (under review — may be superseded by qwen3-coder-30b) |
| fast-coder | unsloth/Qwen3.5-9B-GGUF | `koala/qwen35-9b-fast` | 5805 | 262144 | Agentic coding (fast, many tool calls) |

## iguana — ollama

| Slot | Model | LiteLLM Name | Type | Use Case |
|------|-------|-------------|------|----------|
| quality-coder | qwen3-coder-next | `qwen3-coder-next` | chat | Agentic coding (quality, complex tasks) |
| general | qwen3.5:35b | `qwen3.5-35b` | chat | Chat / general assistant (OpenWebUI) |
| reasoning | deepseek-r1-tuned | `deepseek-r1-tuned` | chat | Reasoning / planning |
| embed | nomic-embed-text | `nomic-embed` | embedding | Embeddings (RAG) |
| rerank | Qwen3-Reranker-0.6B | `iguana/rerank` | reranker | Search result reranking |
| stt | mlx-community/whisper-large-v3-mlx | `iguana/whisper` | stt | Speech to text |

## Management Commands

```bash
# Regenerate all configs from models.yml
scripts/model-generate.sh

# Apply llama-swap config to k3s
kubectl apply -f k3s/apps/ai-stack/llama-swap-configmap.yaml
kubectl rollout restart deployment/llama-swap -n ai-stack

# Validate a slot is responding
curl http://10.0.1.20:31234/v1/models
```
