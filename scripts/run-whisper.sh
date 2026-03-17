#!/usr/bin/env bash
#
# run-whisper.sh - Launch whisper.cpp server for speech recognition on Intel Arc A770
#
# Usage:
#   ./scripts/run-whisper.sh                              # Run with default model
#   ./scripts/run-whisper.sh /path/to/model.bin           # Run with specific model
#   WHISPER_PORT=9091 ./scripts/run-whisper.sh            # Different port
#
# Endpoint:
#   POST http://<host>:<port>/inference  (multipart/form-data with audio file)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WHISPER_CPP_DIR="$PROJECT_DIR/whisper.cpp"

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
fi

# ============================================================================
# Parse arguments
# ============================================================================

MODEL_PATH="${WHISPER_MODEL:-}"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: $0 [model_path] [extra whisper-server args...]"
            echo ""
            echo "Options:"
            echo "  model_path          Path to whisper model file (default: from env config)"
            echo "  Any other args      Passed directly to whisper-server"
            echo ""
            echo "Environment variables:"
            echo "  WHISPER_MODEL       Model path (default: ~/models/ggml-large-v3.bin)"
            echo "  WHISPER_HOST        Bind address (default: 0.0.0.0)"
            echo "  WHISPER_PORT        Listen port (default: 9090)"
            echo "  WHISPER_LANGUAGE    Language: auto, en, ar, fr, zh (default: auto)"
            echo ""
            echo "Endpoint:"
            echo "  POST http://<host>:<port>/inference"
            exit 0
            ;;
        *.bin)
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
    echo "[ERROR] No model specified. Provide a model path or set WHISPER_MODEL in env."
    echo "  Usage: $0 /path/to/model.bin"
    exit 1
fi

if [[ ! -f "$MODEL_PATH" ]]; then
    echo "[ERROR] Model file not found: $MODEL_PATH"
    exit 1
fi

# Find whisper-server binary
SERVER_BIN=""
for candidate in \
    "$WHISPER_CPP_DIR/build/bin/whisper-server" \
    "$WHISPER_CPP_DIR/build/whisper-server" \
    "$(command -v whisper-server 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        SERVER_BIN="$candidate"
        break
    fi
done

if [[ -z "$SERVER_BIN" ]]; then
    echo "[ERROR] whisper-server binary not found. Run scripts/install-whisper.sh first."
    exit 1
fi

# ============================================================================
# Settings
# ============================================================================

HOST="${WHISPER_HOST:-0.0.0.0}"
PORT="${WHISPER_PORT:-9090}"
LANGUAGE="${WHISPER_LANGUAGE:-auto}"

# SYCL runtime environment
export ZES_ENABLE_SYSMAN="${ZES_ENABLE_SYSMAN:-1}"
export UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS="${UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS:-1}"

# ============================================================================
# Launch
# ============================================================================

echo ""
echo "============================================================"
echo "  whisper.cpp Server - Intel Arc A770"
echo "============================================================"
echo ""
echo "  Model:     $(basename "$MODEL_PATH")"
echo "  Language:   $LANGUAGE"
echo "  Endpoint:  http://${HOST}:${PORT}/inference"
echo ""
echo "  SYCL:      GPU-accelerated inference"
echo "  Env:       ZES_ENABLE_SYSMAN=${ZES_ENABLE_SYSMAN}"
echo "             UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=${UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS}"
echo ""
echo "  Press Ctrl+C to stop the server"
echo ""
echo "============================================================"
echo ""

exec "$SERVER_BIN" \
    --model "$MODEL_PATH" \
    --host "$HOST" \
    --port "$PORT" \
    --language "$LANGUAGE" \
    --convert \
    "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
