#!/usr/bin/env bash
#
# run-piper.sh - Launch the Piper neural text-to-speech server (CPU)
#
# Usage:
#   ./scripts/run-piper.sh                                # Run with default voice
#   ./scripts/run-piper.sh en_US-lessac-medium            # Run with a specific voice
#   PIPER_PORT=9092 ./scripts/run-piper.sh                # Different port
#
# Endpoints:
#   POST http://<host>:<port>/            (JSON in, WAV out)
#   POST http://<host>:<port>/synthesize  (upstream name for the same handler)
#   GET  http://<host>:<port>/voices      (installed voices)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENV_DIR="$PROJECT_DIR/piper-venv"

# ============================================================================
# Load environment (XDG-compliant config)
# ============================================================================

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

VOICE="${PIPER_VOICE:-en_US-lessac-medium}"
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: $0 [voice] [extra piper.http_server args...]"
            echo ""
            echo "Options:"
            echo "  voice               Voice name or .onnx path (default: from env config)"
            echo "  Any other args      Passed directly to piper.http_server"
            echo ""
            echo "Environment variables:"
            echo "  PIPER_VOICE         Default voice (default: en_US-lessac-medium)"
            echo "  PIPER_VOICES_DIR    Voice directory (default: \$MODELS_DIR/piper)"
            echo "  PIPER_HOST          Bind address (default: 0.0.0.0)"
            echo "  PIPER_PORT          Listen port (default: 9091)"
            echo "  PIPER_NUM_THREADS   onnxruntime intra-op threads (default: 2)"
            echo "  PIPER_LENGTH_SCALE  Default speaking rate, <1.0 faster (default: 1.0)"
            echo ""
            echo "Endpoint:"
            echo "  POST http://<host>:<port>/"
            exit 0
            ;;
        --*)
            EXTRA_ARGS+=("$1")
            shift
            ;;
        *)
            VOICE="$1"
            shift
            ;;
    esac
done

# ============================================================================
# Settings
# ============================================================================

MODELS_DIR="${MODELS_DIR:-$HOME/models}"
VOICES_DIR="${PIPER_VOICES_DIR:-$MODELS_DIR/piper}"
HOST="${PIPER_HOST:-0.0.0.0}"
PORT="${PIPER_PORT:-9091}"
LENGTH_SCALE="${PIPER_LENGTH_SCALE:-1.0}"
export PIPER_NUM_THREADS="${PIPER_NUM_THREADS:-2}"

if [[ "$VOICE" == *.onnx ]]; then
    VOICE_PATH="$VOICE"
else
    VOICE_PATH="$VOICES_DIR/$VOICE.onnx"
fi

# ============================================================================
# Validate
# ============================================================================

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    echo "[ERROR] Piper venv not found at $VENV_DIR. Run scripts/install-piper.sh first."
    exit 1
fi

if [[ ! -f "$VOICE_PATH" ]]; then
    echo "[ERROR] Voice not found: $VOICE_PATH"
    echo "  Available in $VOICES_DIR:"
    ls -1 "$VOICES_DIR"/*.onnx 2>/dev/null | xargs -r -n1 basename || echo "    (none — run scripts/install-piper.sh)"
    exit 1
fi

if [[ ! -f "$VOICE_PATH.json" ]]; then
    echo "[ERROR] Voice config missing: $VOICE_PATH.json"
    exit 1
fi

# ============================================================================
# Launch
# ============================================================================

INSTALLED_VOICES=$(ls -1 "$VOICES_DIR"/*.onnx 2>/dev/null | xargs -r -n1 basename | sed 's/\.onnx$//' | paste -sd', ' -)

echo ""
echo "============================================================"
echo "  Piper Text-to-Speech Server - CPU"
echo "============================================================"
echo ""
echo "  Default voice: $(basename "$VOICE_PATH" .onnx)"
echo "  Installed:     ${INSTALLED_VOICES:-none}"
echo "  Voices dir:    $VOICES_DIR"
echo "  Endpoint:      http://${HOST}:${PORT}/"
echo ""
echo "  Threads:       $PIPER_NUM_THREADS (onnxruntime intra-op)"
echo "  Length scale:  $LENGTH_SCALE"
echo ""
echo "  Press Ctrl+C to stop the server"
echo ""
echo "============================================================"
echo ""

exec "$VENV_DIR/bin/python" "$SCRIPT_DIR/piper_http_shim.py" \
    --host "$HOST" \
    --port "$PORT" \
    --model "$VOICE_PATH" \
    --data-dir "$VOICES_DIR" \
    --length-scale "$LENGTH_SCALE" \
    "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
