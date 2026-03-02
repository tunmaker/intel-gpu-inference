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
# Load environment
# ============================================================================

if [[ -f "$PROJECT_DIR/configs/env.sh" ]]; then
    set +u
    source "$PROJECT_DIR/configs/env.sh"
    set -u
else
    echo "[ERROR] configs/env.sh not found. Run install.sh first."
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
            echo "  model_path          Path to GGUF model file (default: from configs/env.sh)"
            echo "  --ctx SIZE          Override context window size"
            echo "  Any other args      Passed directly to llama-server"
            echo ""
            echo "Environment variables:"
            echo "  LLAMA_HOST          Bind address (default: 0.0.0.0)"
            echo "  LLAMA_PORT          Listen port (default: 8080)"
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

# Auto-detect context size based on model file size (approximate VRAM usage)
if [[ -z "$CONTEXT_SIZE" ]]; then
    MODEL_SIZE_GB=$(awk "BEGIN {printf \"%.1f\", $(stat --format="%s" "$MODEL_PATH") / 1073741824}")

    # 16GB VRAM budget: model + KV cache + ~1.5GB overhead
    # KV cache size depends on model architecture, ~0.5-1MB per token for 7B models
    if awk "BEGIN {exit !($MODEL_SIZE_GB <= 4.5)}"; then
        CONTEXT_SIZE=16384   # Small Q4_0 model: lots of room
    elif awk "BEGIN {exit !($MODEL_SIZE_GB <= 8.0)}"; then
        CONTEXT_SIZE=8192    # Q8_0 7B model: comfortable
    elif awk "BEGIN {exit !($MODEL_SIZE_GB <= 12.0)}"; then
        CONTEXT_SIZE=4096    # 14B Q4_0: moderate context
    else
        CONTEXT_SIZE=2048    # Large model: minimal context
    fi

    echo "[INFO] Model size: ${MODEL_SIZE_GB}GB, auto-selected context: ${CONTEXT_SIZE} tokens"
fi

# GPU layers: offload everything to GPU (999 = all layers)
GPU_LAYERS="999"

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
echo "  Tool calling enabled (--chat-template qwen2vl)"
echo "  Vision enabled (Qwen3VL image/video tokens)"
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

exec "$SERVER_BIN" \
    --model "$MODEL_PATH" \
    "${MMPROJ_ARGS[@]+"${MMPROJ_ARGS[@]}"}" \
    --host "$HOST" \
    --port "$PORT" \
    --ctx-size "$CONTEXT_SIZE" \
    --n-gpu-layers $GPU_LAYERS \
    --cache-type-k q8_0 \
    --cache-type-v q8_0 \
    --flash-attn on \
    "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
