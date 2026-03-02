# Intel Arc GPU Environment Configuration
# Source this file before running llama-server:  source configs/env.sh

# === oneAPI Environment ===
if [[ -f /opt/intel/oneapi/setvars.sh ]]; then
    source /opt/intel/oneapi/setvars.sh 2>/dev/null
fi

# === Intel Arc GPU Settings ===

# CRITICAL: Allow VRAM allocations larger than 4GB (needed for most models)
export UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1

# Device hierarchy - use flat for best performance on single GPU
export ZE_FLAT_DEVICE_HIERARCHY=FLAT

# Select the discrete GPU (adjust index if iGPU is present)
# Use 'sycl-ls' to see available devices and their indices
# If you have an iGPU + dGPU: level_zero:1 selects the dGPU
# If you only have dGPU: level_zero:0 selects it
# Uncomment and adjust if you have iGPU conflicts:
# export ONEAPI_DEVICE_SELECTOR="level_zero:1"

# === Paths ===
# INFERENCE_ROOT: absolute path to the intel-gpu-inference directory,
# computed relative to this file so it works on any machine.
INFERENCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-$INFERENCE_ROOT/llama.cpp/build/bin/llama-server}"

# Models directory — models live under $HOME/models by convention
export MODELS_DIR="${MODELS_DIR:-$HOME/models}"
export DEFAULT_CTX="${DEFAULT_CTX:-32768}"

# Active model — comment/uncomment to switch
#export DEFAULT_MODEL="$HOME/models/Gemma-3-4B-VL-it-Gemini-Pro-Heretic-Uncensored-Thinking_F16.gguf"
#export DEFAULT_MODEL="$HOME/models/Ministral-3-14B-Instruct-2512-Q8_0.gguf"
#export DEFAULT_MODEL="$HOME/models/Qwen2.5-7B-Instruct-Q8_0.gguf"
#export DEFAULT_MODEL="$HOME/models/Qwen3-14b.Q8_0.gguf"
#export DEFAULT_MODEL="$HOME/models/Qwen3.5-35B-A3B-UD-IQ2_XXS.gguf"
export DEFAULT_MODEL="${DEFAULT_MODEL:-$HOME/models/Qwen3VL-8B-Instruct-Q8_0.gguf}"

# Vision projector (for multimodal inference). Leave blank or unset to skip --mmproj.
export MMPROJ_PATH="${MMPROJ_PATH:-$HOME/models/mmproj-Qwen3VL-8B-Instruct-F16.gguf}"

# === Server Defaults ===
export LLAMA_HOST="${LLAMA_HOST:-0.0.0.0}"
export LLAMA_PORT="${LLAMA_PORT:-8080}"
