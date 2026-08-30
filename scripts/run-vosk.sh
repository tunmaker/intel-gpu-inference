#!/usr/bin/env bash
#
# run-vosk.sh - Launch the Vosk speech recognition server (CPU, Tunisian Derja)
#
# Usage:
#   ./scripts/run-vosk.sh                          # Run with default model
#   ./scripts/run-vosk.sh /path/to/model-dir       # Run with a specific model
#   VOSK_PORT=9093 ./scripts/run-vosk.sh           # Different port
#
# Endpoint:
#   POST http://<host>:<port>/inference  (multipart/form-data, same as whisper-server)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENV_DIR="$PROJECT_DIR/vosk-venv"

ENV_FILE="$HOME/.config/intel-gpu-inference/env"
if [[ -f "$ENV_FILE" ]]; then
    set +eu
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set -eu
fi

MODEL_PATH="${VOSK_MODEL:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: $0 [model_dir]"
            echo ""
            echo "Options:"
            echo "  model_dir           Unpacked Vosk model directory (default: from env config)"
            echo ""
            echo "Environment variables:"
            echo "  VOSK_MODEL          Model directory"
            echo "  VOSK_HOST           Bind address (default: 0.0.0.0)"
            echo "  VOSK_PORT           Listen port (default: 9092)"
            echo "  VOSK_MAX_UPLOAD_MB  Reject uploads above this size (default: 256)"
            echo ""
            echo "Endpoint:"
            echo "  POST http://<host>:<port>/inference"
            exit 0
            ;;
        *) MODEL_PATH="$1"; shift ;;
    esac
done

HOST="${VOSK_HOST:-0.0.0.0}"
PORT="${VOSK_PORT:-9092}"
export VOSK_MAX_UPLOAD_MB="${VOSK_MAX_UPLOAD_MB:-256}"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    echo "[ERROR] Vosk venv not found at $VENV_DIR. Run scripts/install-vosk.sh first."
    exit 1
fi

if [[ -z "$MODEL_PATH" ]]; then
    echo "[ERROR] No model specified. Set VOSK_MODEL in env or pass a model directory."
    exit 1
fi

if [[ ! -d "$MODEL_PATH" ]]; then
    echo "[ERROR] Model directory not found: $MODEL_PATH"
    echo "  Run scripts/install-vosk.sh to download it."
    exit 1
fi

if [[ ! -f "$MODEL_PATH/am/final.mdl" ]]; then
    echo "[ERROR] $MODEL_PATH does not look like a Vosk model (no am/final.mdl)."
    echo "  Point VOSK_MODEL at the unpacked directory, not the .zip."
    exit 1
fi

echo ""
echo "============================================================"
echo "  Vosk Speech Recognition Server - CPU"
echo "============================================================"
echo ""
echo "  Model:     $(basename "$MODEL_PATH")"
echo "  Endpoint:  http://${HOST}:${PORT}/inference"
echo "  Contract:  multipart 'file' -> {\"text\": ...}  (whisper-compatible)"
echo ""
echo "  Press Ctrl+C to stop the server"
echo ""
echo "============================================================"
echo ""

exec "$VENV_DIR/bin/python" "$SCRIPT_DIR/vosk_server.py" \
    --model "$MODEL_PATH" \
    --host "$HOST" \
    --port "$PORT"
