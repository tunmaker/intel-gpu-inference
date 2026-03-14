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
    CONTEXT_SIZE=24576
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
echo "  SYCL:     split-mode=none, main-gpu=0"
echo "  Env:      ZES_ENABLE_SYSMAN=${ZES_ENABLE_SYSMAN}"
echo "            UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=${UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS}"
echo ""
echo "  Flash attention off, KV cache f16, mmap enabled"
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

# Old config: flash attention on, q8_0 KV cache, 82 graph splits, CLIP falls back to CPU
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

# Optimized config: no flash attention, f16 KV cache, 2 graph splits, CLIP on GPU
# Benchmarked: 2.2x faster prompt eval, 1.7x faster generation, 2.9x faster vision
exec "$SERVER_BIN" \
    --model "$MODEL_PATH" \
    "${MMPROJ_ARGS[@]+"${MMPROJ_ARGS[@]}"}" \
    --host "$HOST" \
    --port "$PORT" \
    --ctx-size "$CONTEXT_SIZE" \
    --n-gpu-layers $GPU_LAYERS \
    --split-mode none \
    --main-gpu 0 \
    --fit off \
    --mmap \
    "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
