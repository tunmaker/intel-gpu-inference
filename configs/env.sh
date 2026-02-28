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
export LLAMA_SERVER_BIN="/home/tunmaker/intel-gpu-inference/llama.cpp/build/bin/llama-server"
export MODELS_DIR="/home/tunmaker/data/data/models"
export DEFAULT_MODEL="/home/tunmaker/data/data/models/Qwen2.5-7B-Instruct-Q8_0.gguf"

# === Server Defaults ===
export LLAMA_HOST="0.0.0.0"
export LLAMA_PORT="8080"
