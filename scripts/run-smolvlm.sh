#!/usr/bin/env bash
#
# run-smolvlm.sh - SmolVLM-256M as a scene captioner for the presence gate.
#
# This is not a general chat model. It answers one question per frame for the
# vision loop, and it exists because the alternative -- asking Qwen3.5-9B with
# its projector -- costs a 1024-token image prefill on the GPU that answers the
# household's actual questions.
#
# Two things about the cost, both measured on this host with a real 640x480
# frame and cache_prompt disabled, so each figure is a genuine re-encode:
#
#   llama-mtmd-cli, one shot ................. 14.6 s   SYCL kernel compilation
#   server, projector on CPU .................  3.8-6.1 s
#   server, projector on the A770 ............  0.36 s   <- what this uses
#
# So it MUST be a long-lived server, and the projector MUST stay on the GPU.
# --no-mmproj-offload looks like the right instinct -- the whole point is to keep
# the A770 free for Qwen -- and it costs a factor of ten. The projector is 104 MB
# of VRAM; a per-frame 1024-token Qwen image prefill is the thing worth avoiding,
# and this avoids it.
#
# 0.36 s of GPU per frame is still too much to run every second, which is why the
# caller gates on a free frame difference first and only captions on change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

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

MODEL="${SMOLVLM_MODEL:-$HOME/models/smolvlm/SmolVLM-256M-Instruct-Q8_0.gguf}"
MMPROJ="${SMOLVLM_MMPROJ:-$HOME/models/smolvlm/mmproj-SmolVLM-256M-Instruct-Q8_0.gguf}"
HOST="${SMOLVLM_HOST:-127.0.0.1}"
PORT="${SMOLVLM_PORT:-8091}"
THREADS="${SMOLVLM_THREADS:-4}"
CTX="${SMOLVLM_CTX:-4096}"

for f in "$MODEL" "$MMPROJ"; do
    if [[ ! -f "$f" ]]; then
        echo "[ERROR] missing $f"
        echo "        hf download ggml-org/SmolVLM-256M-Instruct-GGUF --local-dir ~/models/smolvlm \\"
        echo "           --include 'SmolVLM-256M-Instruct-Q8_0.gguf' --include 'mmproj-SmolVLM-256M-Instruct-Q8_0.gguf'"
        exit 1
    fi
done

SERVER_BIN="${LLAMA_SERVER_BIN:-$PROJECT_DIR/llama.cpp/build/bin/llama-server}"
[[ -x "$SERVER_BIN" ]] || { echo "[ERROR] llama-server not found at $SERVER_BIN"; exit 1; }

echo "SmolVLM-256M on CPU, ${THREADS} threads, http://${HOST}:${PORT}"

# -ngl 0 keeps the language layers on the CPU, where a 256M model is cheap. The
# projector is left to its default, which is the GPU: see the measurement above.
exec "$SERVER_BIN" \
    --model "$MODEL" \
    --mmproj "$MMPROJ" \
    --host "$HOST" \
    --port "$PORT" \
    --ctx-size "$CTX" \
    -ngl 0 \
    --threads "$THREADS" \
    --parallel 1 \
    --temp 0.0 \
    --log-disable
