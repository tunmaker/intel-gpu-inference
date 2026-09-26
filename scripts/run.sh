#!/usr/bin/env bash
#
# run.sh - Launch llama.cpp server with optimal settings for Intel Arc A770 16GB
#
# Usage:
#   ./scripts/run.sh                          # Run with default model
#   ./scripts/run.sh /path/to/model.gguf      # Run with specific model
#   ./scripts/run.sh --ctx 4096               # Override context size
#   LLAMA_PORT=9090 ./scripts/run.sh          # Run on different port
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ============================================================================
# Load environment (XDG-compliant config)
# ============================================================================
if [ -z "${ONEAPI_SETVARS_DONE:-}" ]; then
    # Only reached when run.sh is called directly from an interactive shell.
    # When started via systemd, ONEAPI_SETVARS_DONE=1 is set in the EnvironmentFile
    # (snapshotted by install.sh), so this block is skipped — avoiding a hang in
    # non-TTY contexts where setvars.sh can block waiting for device enumeration.
    source /opt/intel/oneapi/setvars.sh 2>/dev/null || true
fi

ENV_FILE="$HOME/.config/intel-gpu-inference/env"
if [[ -f "$ENV_FILE" ]]; then
    set +eu
    # shellcheck disable=SC1090
    source "$ENV_FILE"  # set -e disabled: env file may re-source setvars.sh which returns non-zero when already loaded
    set -eu
else
    echo "[ERROR] Config not found: $ENV_FILE"
    echo "Run install.sh first to create the config."
    exit 1
fi

# ============================================================================
# Parse arguments
# ============================================================================

MODEL_PATH="${DEFAULT_MODEL:-}"
CONTEXT_SIZE="${DEFAULT_CTX:-}"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ctx|--context)
            CONTEXT_SIZE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [model_path] [--ctx SIZE] [extra llama-server args...]"
            echo ""
            echo "Options:"
            echo "  model_path          Path to GGUF model file (default: from ~/.config/intel-gpu-inference/env)"
            echo "  --ctx SIZE          Override context window size"
            echo "  Any other args      Passed directly to llama-server"
            echo ""
            echo "Environment variables:"
            echo "  LLAMA_HOST                            Bind address (default: 127.0.0.1)"
            echo "  LLAMA_PORT                            Listen port (default: 8080)"
            echo "  ZES_ENABLE_SYSMAN                       GPU VRAM detection (default: 1)"
            echo "  UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS  Allow >4GB VRAM allocs (default: 1)"
            echo "  ONEAPI_DEVICE_SELECTOR                  Device selector, e.g. level_zero:0"
            echo "  Config:                               ~/.config/intel-gpu-inference/env"
            echo ""
            echo "Examples:"
            echo "  $0                                              # Default model"
            echo "  $0 ~/models/llama-3.1-8b-q8_0.gguf             # Specific model"
            echo "  $0 --ctx 4096                                   # Smaller context"
            echo "  LLAMA_PORT=9090 $0                              # Different port
  LLAMA_HOST=127.0.0.1 $0                        # Restrict to localhost only"
            exit 0
            ;;
        *.gguf)
            MODEL_PATH="$1"
            shift
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

# ============================================================================
# Validate
# ============================================================================

if [[ -z "$MODEL_PATH" ]]; then
    echo "[ERROR] No model specified. Provide a model path or run install.sh to download the default."
    echo "  Usage: $0 /path/to/model.gguf"
    exit 1
fi

if [[ ! -f "$MODEL_PATH" ]]; then
    echo "[ERROR] Model file not found: $MODEL_PATH"
    exit 1
fi

# Find llama-server binary
SERVER_BIN="${LLAMA_SERVER_BIN:-}"
if [[ -z "$SERVER_BIN" || ! -x "$SERVER_BIN" ]]; then
    # Search common locations
    for candidate in \
        "$PROJECT_DIR/llama.cpp/build/bin/llama-server" \
        "$PROJECT_DIR/llama.cpp/build/llama-server" \
        "$(command -v llama-server 2>/dev/null || true)"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            SERVER_BIN="$candidate"
            break
        fi
    done
fi

if [[ -z "$SERVER_BIN" || ! -x "$SERVER_BIN" ]]; then
    echo "[ERROR] llama-server binary not found. Run install.sh first."
    exit 1
fi

# ============================================================================
# Determine optimal settings for Arc A770 16GB
# ============================================================================

HOST="${LLAMA_HOST:-127.0.0.1}"
PORT="${LLAMA_PORT:-8080}"

if [[ -z "$CONTEXT_SIZE" ]]; then
    CONTEXT_SIZE=131072
    echo "[INFO] Using default context size: ${CONTEXT_SIZE} tokens (set DEFAULT_CTX in env or use --ctx to override)"
fi

# GPU layers: offload everything to GPU (999 = all layers)
GPU_LAYERS="999"

# ============================================================================
# SYCL runtime environment (Intel Arc recommended)
# ============================================================================

# Enable GPU VRAM detection via sysman
export ZES_ENABLE_SYSMAN="${ZES_ENABLE_SYSMAN:-1}"
# Allow VRAM allocations larger than 4GB (required for most models)
export UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS="${UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS:-1}"
export ONEAPI_DEVICE_SELECTOR="${ONEAPI_DEVICE_SELECTOR:-level_zero:0,1}"
# 16,8 exhausts the A380 (reported as OUT_OF_HOST_MEMORY); re-tune on any model, quant or ctx change.
TENSOR_SPLIT="${TENSOR_SPLIT:-17,7}"

# ============================================================================
# Launch server
# ============================================================================

echo ""
echo "============================================================"
echo "  llama.cpp Server - Intel Arc A770"
echo "============================================================"
echo ""
echo "  Model:    $(basename "$MODEL_PATH")"
echo "  Context:  $CONTEXT_SIZE tokens"
echo "  GPU:      All layers offloaded"
echo "  Endpoint: http://${HOST}:${PORT}/v1"
echo ""
echo "  SYCL:     split-mode=layer, tensor-split=${TENSOR_SPLIT}"
echo "            ONEAPI_DEVICE_SELECTOR=${ONEAPI_DEVICE_SELECTOR}"
echo "  Env:      ZES_ENABLE_SYSMAN=${ZES_ENABLE_SYSMAN}"
echo "            UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=${UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS}"
echo ""
echo "  Flash attention auto, KV cache f16, mmap enabled"
echo "  Streaming enabled"
echo ""
echo "  Press Ctrl+C to stop the server"
echo ""
echo "============================================================"
echo ""

# Build --mmproj arg only if MMPROJ_PATH is set and the file exists
MMPROJ_ARGS=()
if [[ -n "${MMPROJ_PATH:-}" && -f "${MMPROJ_PATH}" ]]; then
    MMPROJ_ARGS=(--mmproj "$MMPROJ_PATH")
elif [[ -n "${MMPROJ_PATH:-}" ]]; then
    echo "[WARN] MMPROJ_PATH is set but file not found: $MMPROJ_PATH (running without --mmproj)"
fi

SPEC_ARGS=()
if [[ -n "${DRAFT_MODEL:-}" && -f "${DRAFT_MODEL}" ]]; then
    SPEC_ARGS=(--spec-type draft-mtp --spec-draft-model "$DRAFT_MODEL" --spec-draft-n-max "${DRAFT_N_MAX:-4}")
    echo "  Speculative decoding: MTP drafter $(basename "$DRAFT_MODEL"), n-max ${DRAFT_N_MAX:-4}"
elif [[ -n "${DRAFT_MODEL:-}" ]]; then
    echo "[WARN] DRAFT_MODEL is set but file not found: $DRAFT_MODEL (running without speculative decoding)"
fi

# --- Legacy configs (commented out) ---

# Config A: Ministral 14B — flash attn on, q8_0 KV cache (pre-rebuild)
# 82 graph splits, CLIP falls back to CPU, 32K context
# exec "$SERVER_BIN" \
#     --model "$MODEL_PATH" \
#     "${MMPROJ_ARGS[@]+"${MMPROJ_ARGS[@]}"}" \
#     --host "$HOST" \
#     --port "$PORT" \
#     --ctx-size "$CONTEXT_SIZE" \
#     --n-gpu-layers $GPU_LAYERS \
#     --split-mode none \
#     --main-gpu 0 \
#     --cache-type-k q8_0 \
#     --cache-type-v q8_0 \
#     --flash-attn on \
#     --mmap \
#     "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

# Config B: Ministral 14B — no flash attn, f16 KV cache (post-rebuild, pre-Qwen3.5)
# 2 graph splits, CLIP on GPU, 24K context
# Benchmarked: 2.2x faster prompt eval, 1.7x faster generation, 2.9x faster vision
# exec "$SERVER_BIN" \
#     --model "$MODEL_PATH" \
#     "${MMPROJ_ARGS[@]+"${MMPROJ_ARGS[@]}"}" \
#     --host "$HOST" \
#     --port "$PORT" \
#     --ctx-size 24576 \
#     --n-gpu-layers $GPU_LAYERS \
#     --split-mode none \
#     --main-gpu 0 \
#     --fit off \
#     --mmap \
#     "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

# Config C: Qwen3.5-9B Q8_0 — thinking mode, general chat (commented out)
# Hybrid SSM+attention arch: only 8/32 layers use KV cache → 131K context fits in VRAM
# Unsloth recommended: temp=1.0, top_p=0.95, top_k=20, repeat_penalty=1.5 (thinking mode)
# exec "$SERVER_BIN" \
#     --model "$MODEL_PATH" \
#     "${MMPROJ_ARGS[@]+"${MMPROJ_ARGS[@]}"}" \
#     --host "$HOST" \
#     --port "$PORT" \
#     --ctx-size "$CONTEXT_SIZE" \
#     --n-gpu-layers $GPU_LAYERS \
#     --split-mode none \
#     --main-gpu 0 \
#     --fit off \
#     --mmap \
#     --temp 1.0 \
#     --top-p 0.95 \
#     --top-k 20 \
#     --min-p 0.0 \
#     --repeat-penalty 1.5 \
#     --chat-template-kwargs '{"enable_thinking":true}' \
#     "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"


# Config E: Gemma 4 12B-it Q4_0 — general-purpose agent, orchestrator, vision (commented out)
# Needs MTP drafter + mmproj from the gemma-4-12B-it directory; see the env file.
# exec "$SERVER_BIN" \
#     --model "$MODEL_PATH" \
#     "${MMPROJ_ARGS[@]+"${MMPROJ_ARGS[@]}"}" \
#     "${SPEC_ARGS[@]+"${SPEC_ARGS[@]}"}" \
#     --host "$HOST" \
#     --port "$PORT" \
#     --ctx-size "$CONTEXT_SIZE" \
#     --n-gpu-layers $GPU_LAYERS \
#     --split-mode none \
#     --main-gpu 0 \
#     --fit off \
#     --mmap \
#     --flash-attn on \
#     --temp 1.0 \
#     --top-p 0.95 \
#     --top-k 64 \
#     --min-p 0.0 \
#     "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

# Prompt cache, measured on this host (30 Aug 2026), 5.9k-token prompt:
#   identical prompt ............ 0.09 s prefill, 100% cached
#   tail changed (MEMORY.md) .... 1.20 s prefill,  91% cached
#   anything changed earlier .... 9.09 s prefill,   0% cached
# Slots, measured 1 Sep 2026. Left on its own, -np resolves to "auto", which also
# turns on --kv-unified: one shared KV buffer, and idle slots are CLEARED whenever
# a new task arrives. Two callers pinned to different slots therefore still destroy
# each other's prefix:
#   prime slot 0 ......................... cache_n=1815, prefill  93 ms
#   three unrelated prompts on slot 1 .... (slot 0 now cleared)
#   slot 0, byte-identical prompt ........ cache_n=   0, prefill 3152 ms
# --no-kv-unified gives each sequence its own KV allocation, so a slot keeps its
# prefix while other slots work. --ctx-size is the TOTAL and is divided equally by
# --parallel; there is no per-slot sizing. Two slots, 131072/2 = 65536 each:
# slot 0 is the voice session alone (its warm prefix is the wake-word latency),
# slot 1 is everything else -- main UI, subagents, cron turns, image probes.
# Four 32k slots looked generous until a research subagent piled nine web
# searches into one prompt; OpenClaw budgets (contextTokens) are set per lane so
# voice compacts early and the shared lane can actually use the room.
# Pin callers with "id_slot" in the request body.
#
# Exact-prefix reuse is the whole mechanism. --cache-reuse below does nothing at
# all, and the server says so on every start:
#   srv load_model: cache_reuse is not supported by multimodal, it will be disabled
# Loading --mmproj switches it off outright, so the earlier note blaming the hybrid
# SSM architecture was measuring a flag that was never active. Both may well be
# true, but the mmproj disable happens first and unconditionally. The flag is kept
# for the day this runs without a projector; until then, do not budget on it.
# --- Previous config (fallback): Qwen3.5-9B Q8_0 — hybrid SSM, vision, 131K ctx ---
# SYCL flash attention + fused Gated Delta Net (requires llama.cpp build >= 8369).
# Hybrid SSM+attention: only 8/32 layers hold KV cache, so 131K context fits in 16GB
# alongside the F16 vision projector.
# Unsloth agentic profile: temp=0.6, no repeat penalty (repeat penalty mangles tool JSON).
# Thinking disabled — no <think> block on every turn, which is latency the voice path pays for.
# exec "$SERVER_BIN" \
#     --model "$MODEL_PATH" \
#     "${MMPROJ_ARGS[@]+"${MMPROJ_ARGS[@]}"}" \
#     "${SPEC_ARGS[@]+"${SPEC_ARGS[@]}"}" \
#     --host "$HOST" \
#     --port "$PORT" \
#     --ctx-size "$CONTEXT_SIZE" \
#     --n-gpu-layers $GPU_LAYERS \
#     --split-mode none \
#     --main-gpu 0 \
#     --fit off \
#     --load-mode mmap \
#     --flash-attn on \
#     --parallel 2 \
#     --no-kv-unified \
#     --cache-reuse 256 \
#     --temp 0.6 \
#     --top-p 0.95 \
#     --top-k 20 \
#     --min-p 0.0 \
#     --reasoning off \
#     "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

# --- Active config: Qwen3.8-27B IQ4_XS — agentic assistant, tool calling, vision ---
# Dense attention, NOT the hybrid SSM of Qwen3.5-9B: all 64 layers hold KV, so the
# cache costs 256 KiB/token at f16 against roughly 8 KiB/token before. 131072 is
# therefore out of reach at any quant -- full 262144 context would want 68 GB of KV
# alone -- and q4_0 is what buys usable context here: 2.4 GB at 32768 instead of 8.6 GB.
# Measured on this host (22 Sep 2026), A770 16GB, llama-bench:
#   UD-IQ4_XS  (13.26 GiB) .... pp256 189.0 t/s, tg64 9.25 t/s
#   UD-Q3_K_XL (12.23 GiB) .... pp256 188.5 t/s, tg64 8.71 t/s
# IQ4_XS is the larger file and still the faster one, so the note in docs/models.md
# about legacy quants beating K-quants extends to I-quants: Q3_K_XL's mixed-precision
# dequant costs more per byte than IQ4_XS's uniform one. It is also 4.25 bpw against
# ~3.5, so there is no axis on which Q3_K_XL wins; it stays only as a fallback.
# One slot: --parallel 1 leaves nothing to pin with id_slot, and the voice/shared
# lane split documented above cannot apply. Raise --parallel only by taking context
# away, since --no-kv-unified divides --ctx-size equally between slots.
# Vision needs the A380 (layer split below): weights plus the F16 projector overflow the A770 alone.
# Qwen3.8 instruct (non-thinking) profile: temp=0.7, top-p=0.80. Unsloth also
# documents presence-penalty 1.5 for this mode, left off here because penalties
# mangle tool JSON -- the same reason repeat-penalty is absent.
exec "$SERVER_BIN" \
    --model "$MODEL_PATH" \
    "${MMPROJ_ARGS[@]+"${MMPROJ_ARGS[@]}"}" \
    "${SPEC_ARGS[@]+"${SPEC_ARGS[@]}"}" \
    --host "$HOST" \
    --port "$PORT" \
    --ctx-size "$CONTEXT_SIZE" \
    --n-gpu-layers $GPU_LAYERS \
    --split-mode layer \
    --tensor-split "$TENSOR_SPLIT" \
    --batch-size 1024 \
    --ubatch-size 256 \
    --fit off \
    --load-mode mmap \
    --flash-attn on \
    --cache-type-k q4_0 \
    --cache-type-v q4_0 \
    --parallel 1 \
    --no-kv-unified \
    --cache-reuse 256 \
    --temp 0.7 \
    --top-p 0.80 \
    --top-k 20 \
    --min-p 0.0 \
    --reasoning off \
    "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
