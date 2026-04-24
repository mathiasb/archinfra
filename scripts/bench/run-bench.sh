#!/usr/bin/env bash
set -euo pipefail

# run-bench.sh — benchmark a model slot for throughput, VRAM, and context stress
# Usage: run-bench.sh <slot-name>   (e.g. run-bench.sh koala/fast-coder)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODELS_YML="$REPO_ROOT/models.yml"
RESULTS_FILE="$REPO_ROOT/benchmarks/results.jsonl"
PROMPTS_DIR="$SCRIPT_DIR/prompts"

RUNS=3

# ── helpers ──────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

now_ns() { python3 -c "import time; print(int(time.time_ns()))"; }

json_extract() {
  # $1 = json string, $2 = python expression using 'd' as the parsed dict
  python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print($1)" <<< "$2"
}

# ── validate inputs ──────────────────────────────────────────────

SLOT="${1:-}"
[ -z "$SLOT" ] && die "Usage: run-bench.sh <slot-name>  (e.g. koala/fast-coder)"

command -v yq >/dev/null 2>&1 || die "yq is required but not found"
command -v curl >/dev/null 2>&1 || die "curl is required but not found"

[ -f "$MODELS_YML" ] || die "models.yml not found at $MODELS_YML"

# ── resolve slot config ──────────────────────────────────────────

MACHINE="${SLOT%%/*}"
SLOT_YQ=".slots.\"$SLOT\""

yq "$SLOT_YQ" "$MODELS_YML" | grep -q "null" && die "Slot '$SLOT' not found in models.yml"

MODEL=$(yq "$SLOT_YQ.model" "$MODELS_YML")
LITELLM_NAME=$(yq "$SLOT_YQ.litellm_name" "$MODELS_YML")
MIN_TOK_S=$(yq "$SLOT_YQ.benchmark_targets.min_tok_s // 0" "$MODELS_YML")

[ "$MODEL" = "null" ] && die "No model defined for slot '$SLOT'"

# Determine API endpoint and model name for the request
case "$MACHINE" in
  koala)
    HOST=$(yq '.hardware.koala.host' "$MODELS_YML")
    PORT=$(yq '.hardware.koala.llama_swap_port' "$MODELS_YML")
    API_BASE="http://${HOST}:${PORT}/v1"
    # llama-swap model name: strip the koala/ prefix from litellm_name
    API_MODEL="${LITELLM_NAME#koala/}"
    ;;
  iguana)
    HOST=$(yq '.hardware.iguana.host' "$MODELS_YML")
    PORT=$(yq '.hardware.iguana.ollama_port' "$MODELS_YML")
    API_BASE="http://${HOST}:${PORT}/v1"
    # ollama: use the model field directly
    API_MODEL="$MODEL"
    ;;
  *)
    die "Unknown machine '$MACHINE' — expected koala or iguana"
    ;;
esac

echo "========================================"
echo "Benchmark: $SLOT"
echo "Model:     $MODEL"
echo "API model: $API_MODEL"
echo "Endpoint:  $API_BASE"
echo "Target:    ${MIN_TOK_S} tok/s"
echo "========================================"
echo

# ── build JSON payload helper ────────────────────────────────────

build_chat_payload() {
  # $1 = prompt text, $2 = max_tokens, $3 = temperature
  python3 -c "
import json, sys
prompt = sys.stdin.read()
payload = {
    'model': '$API_MODEL',
    'messages': [{'role': 'user', 'content': prompt}],
    'max_tokens': $2,
    'temperature': $3
}
print(json.dumps(payload))
" <<< "$1"
}

# ── 1. Throughput benchmark ──────────────────────────────────────

CODE_PROMPT=$(cat "$PROMPTS_DIR/code-completion.txt")

echo "--- Throughput benchmark ($RUNS runs) ---"
echo "(First request may be slow if model is loading...)"
echo

TOTAL_TOKS=0
TOTAL_NS=0

for i in $(seq 1 "$RUNS"); do
  PAYLOAD=$(build_chat_payload "$CODE_PROMPT" 512 0.1)

  START=$(now_ns)
  RESPONSE=$(curl -s --max-time 120 \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$API_BASE/chat/completions") || die "curl failed on run $i"
  END=$(now_ns)

  ELAPSED_NS=$((END - START))

  COMPLETION_TOKENS=$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
usage = d.get('usage', {})
print(usage.get('completion_tokens', 0))
" <<< "$RESPONSE")

  [ "$COMPLETION_TOKENS" -eq 0 ] 2>/dev/null && die "No completion tokens in response. Response: $(echo "$RESPONSE" | head -c 500)"

  ELAPSED_S=$(python3 -c "print(f'{$ELAPSED_NS / 1e9:.2f}')")
  TOK_S=$(python3 -c "print(f'{$COMPLETION_TOKENS / ($ELAPSED_NS / 1e9):.1f}')")

  echo "  Run $i: ${COMPLETION_TOKENS} tokens in ${ELAPSED_S}s = ${TOK_S} tok/s"

  TOTAL_TOKS=$((TOTAL_TOKS + COMPLETION_TOKENS))
  TOTAL_NS=$((TOTAL_NS + ELAPSED_NS))
done

AVG_TOK_S=$(python3 -c "print(f'{$TOTAL_TOKS / ($TOTAL_NS / 1e9):.1f}')")
echo
echo "  Average: $AVG_TOK_S tok/s"
echo

# ── 2. VRAM check (koala only) ───────────────────────────────────

VRAM_GB="n/a"

if [ "$MACHINE" = "koala" ]; then
  echo "--- VRAM usage (koala) ---"
  KOALA_HOST=$(yq '.hardware.koala.host' "$MODELS_YML")

  VRAM_OUTPUT=$(ssh -o ConnectTimeout=5 "$KOALA_HOST" \
    "nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits" 2>/dev/null) || {
    echo "  WARNING: Could not SSH to koala for VRAM check"
    VRAM_OUTPUT=""
  }

  if [ -n "$VRAM_OUTPUT" ]; then
    VRAM_USED=$(echo "$VRAM_OUTPUT" | awk -F', ' '{print $1}')
    VRAM_TOTAL=$(echo "$VRAM_OUTPUT" | awk -F', ' '{print $2}')
    VRAM_USED_GB=$(python3 -c "print(f'{$VRAM_USED / 1024:.1f}')")
    VRAM_TOTAL_GB=$(python3 -c "print(f'{$VRAM_TOTAL / 1024:.1f}')")
    VRAM_GB="$VRAM_USED_GB"
    echo "  ${VRAM_USED_GB} GB / ${VRAM_TOTAL_GB} GB"
  fi
  echo
fi

# ── 3. Context stress test ───────────────────────────────────────

echo "--- Context stress test ---"

CONTEXT_SIZES=(8192 16384 32768 65536 131072 262144)
MAX_PADDING_BYTES=$((1024 * 1024))  # 1MB limit

CONTEXT_OK=true
for CTX in "${CONTEXT_SIZES[@]}"; do
  # ~4 chars per token
  PAD_BYTES=$((CTX * 4))

  if [ "$PAD_BYTES" -gt "$MAX_PADDING_BYTES" ]; then
    echo "  ${CTX} tokens: SKIPPED (padding > 1MB)"
    continue
  fi

  # Build a padding string of approximately the right size
  PADDING=$(python3 -c "print('The quick brown fox jumps over the lazy dog. ' * ($PAD_BYTES // 46))")

  PAYLOAD=$(build_chat_payload "$PADDING" 16 0.1)

  START=$(now_ns)
  RESPONSE=$(curl -s --max-time 30 \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$API_BASE/chat/completions" 2>&1) || RESPONSE=""
  END=$(now_ns)

  # Check if response contains completion tokens
  HAS_TOKENS=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    tokens = d.get('usage', {}).get('completion_tokens', 0)
    print('ok' if tokens > 0 else 'fail')
except:
    print('fail')
" <<< "$RESPONSE")

  ELAPSED_S=$(python3 -c "print(f'{($END - $START) / 1e9:.1f}')")

  if [ "$HAS_TOKENS" = "ok" ]; then
    echo "  ${CTX} tokens: ok (${ELAPSED_S}s)"
  else
    echo "  ${CTX} tokens: FAILED (${ELAPSED_S}s)"
    CONTEXT_OK=false
    break
  fi
done
echo

# ── 4. Verdict ───────────────────────────────────────────────────

PASS=false
if [ "$MIN_TOK_S" -gt 0 ] 2>/dev/null; then
  PASS=$(python3 -c "print('true' if $AVG_TOK_S >= $MIN_TOK_S else 'false')")
  if [ "$PASS" = "true" ]; then
    echo "PASS: $AVG_TOK_S tok/s >= $MIN_TOK_S tok/s target"
  else
    echo "FAIL: $AVG_TOK_S tok/s < $MIN_TOK_S tok/s target"
  fi
else
  echo "SKIP: no benchmark target defined for this slot"
  PASS="null"
fi
echo

# ── 5. Log result ────────────────────────────────────────────────

mkdir -p "$(dirname "$RESULTS_FILE")"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

python3 -c "
import json
result = {
    'timestamp': '$TIMESTAMP',
    'slot': '$SLOT',
    'model': '$MODEL',
    'tok_s': $AVG_TOK_S,
    'vram_gb': '$VRAM_GB' if '$VRAM_GB' == 'n/a' else float('$VRAM_GB'),
    'pass': $PASS if '$PASS' != 'null' else None
}
print(json.dumps(result))
" >> "$RESULTS_FILE"

echo "Result logged to $RESULTS_FILE"
