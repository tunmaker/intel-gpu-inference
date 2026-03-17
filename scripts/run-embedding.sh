#!/usr/bin/env bash
#
# run-embedding.sh - Launch llama.cpp server dedicated to embedding on Intel Arc A770
#
# Usage:
#   ./scripts/run-embedding.sh                              # Run with default model
#   ./scripts/run-embedding.sh /path/to/model.gguf          # Run with specific model
#   EMBEDDING_PORT=8086 ./scripts/run-embedding.sh          # Different port
#
# Endpoint:
#   POST http://<host>:<port>/v1/embeddings  (OpenAI-compatible)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ============================================================================
# Load environment (XDG-compliant config)
# ============================================================================
if [ -z "${ONEAPI_SETVARS_DONE:-}" ]; then
    source /opt/intel/oneapi/setvars.sh 2>/dev/null || true
fi

ENV_FILE="$HOME/.config/intel-gpu-inference/env"
if [[ -f "$ENV_FILE" ]]; then
    set +eu
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set -eu
else
    echo "[ERROR] Config not found: $ENV_FILE"
    echo "Run install.sh first to create the config."
    exit 1
fi

# ============================================================================
# Parse arguments
# ============================================================================

MODEL_PATH="${EMBEDDING_MODEL:-}"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: $0 [model_path] [extra llama-server args...]"
            echo ""
            echo "Options:"
            echo "  model_path          Path to GGUF embedding model (default: from env config)"
            echo "  Any other args      Passed directly to llama-server"
            echo ""
            echo "Environment variables:"
            echo "  EMBEDDING_MODEL     Model path (default: ~/models/nomic-embed-text-v1.5.Q8_0.gguf)"
            echo "  EMBEDDING_HOST      Bind address (default: 0.0.0.0)"
            echo "  EMBEDDING_PORT      Listen port (default: 8085)"
            echo "  EMBEDDING_CTX       Context size (default: 8192)"
            echo ""
            echo "Endpoint:"
            echo "  POST http://<host>:<port>/v1/embeddings"
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
    echo "[ERROR] No model specified. Provide a model path or set EMBEDDING_MODEL in env."
    echo "  Usage: $0 /path/to/model.gguf"
    exit 1
fi

if [[ ! -f "$MODEL_PATH" ]]; then
    echo "[ERROR] Model file not found: $MODEL_PATH"
    exit 1
fi

# Find llama-server binary (reuse the same build as the main server)
SERVER_BIN="${LLAMA_SERVER_BIN:-}"
if [[ -z "$SERVER_BIN" || ! -x "$SERVER_BIN" ]]; then
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
# Settings
# ============================================================================

HOST="${EMBEDDING_HOST:-0.0.0.0}"
PORT="${EMBEDDING_PORT:-8085}"
CONTEXT_SIZE="${EMBEDDING_CTX:-8192}"

# GPU layers: offload everything to GPU
GPU_LAYERS="999"

# SYCL runtime environment
export ZES_ENABLE_SYSMAN="${ZES_ENABLE_SYSMAN:-1}"
export UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS="${UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS:-1}"

# ============================================================================
# Launch
# ============================================================================

echo ""
echo "============================================================"
echo "  llama.cpp Embedding Server - Intel Arc A770"
echo "============================================================"
echo ""
echo "  Model:    $(basename "$MODEL_PATH")"
echo "  Context:  $CONTEXT_SIZE tokens"
echo "  GPU:      All layers offloaded"
echo "  Endpoint: http://${HOST}:${PORT}/v1/embeddings"
echo ""
echo "  SYCL:     split-mode=none, main-gpu=0"
echo "  Env:      ZES_ENABLE_SYSMAN=${ZES_ENABLE_SYSMAN}"
echo "            UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=${UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS}"
echo ""
echo "  Press Ctrl+C to stop the server"
echo ""
echo "============================================================"
echo ""

exec "$SERVER_BIN" \
    --model "$MODEL_PATH" \
    --host "$HOST" \
    --port "$PORT" \
    --ctx-size "$CONTEXT_SIZE" \
    --n-gpu-layers $GPU_LAYERS \
    --split-mode none \
    --main-gpu 0 \
    --embedding \
    --pooling cls \
    -ub 8192 \
    "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
