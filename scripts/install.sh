#!/usr/bin/env bash
#
# install.sh - Set up llama.cpp with SYCL backend for Intel Arc A770
#
# This script:
#   1. Detects/installs Intel GPU compute drivers
#   2. Installs oneAPI toolkit (compiler + MKL)
#   3. Builds llama.cpp with SYCL backend
#   4. Downloads a recommended default model
#
# Tested on: Ubuntu 22.04/24.04, Debian 12
# Target GPU: Intel Arc A770 (16GB)

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LLAMA_CPP_DIR="$PROJECT_DIR/llama.cpp"
# MODELS_DIR can be overridden via environment variable; default is ~/models
MODELS_DIR="${MODELS_DIR:-$HOME/models}"
LLAMA_CPP_REPO="https://github.com/ggml-org/llama.cpp.git"

# Default model to download (bartowski provides single-file GGUFs)
DEFAULT_MODEL_REPO="bartowski/Qwen2.5-7B-Instruct-GGUF"
DEFAULT_MODEL_FILE="Qwen2.5-7B-Instruct-Q8_0.gguf"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ============================================================================
# Pre-flight checks
# ============================================================================

if [[ $EUID -eq 0 ]]; then
    log_error "Do not run this script as root. It will use sudo when needed."
    exit 1
fi

# Check if sudo is available non-interactively
SUDO_AVAILABLE=true
if ! sudo -n true 2>/dev/null; then
    # Try with a terminal
    if ! sudo -v 2>/dev/null; then
        SUDO_AVAILABLE=false
        log_warn "sudo is not available without a password."
        log_warn "Steps requiring root will print commands for you to run manually."
    fi
fi

# Wrapper: run with sudo if available, otherwise print the command
run_sudo() {
    if $SUDO_AVAILABLE; then
        sudo "$@"
    else
        log_warn "Please run manually:  sudo $*"
        return 1
    fi
}

# Detect distro
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    DISTRO="$ID"
    DISTRO_VERSION="$VERSION_ID"
    log_info "Detected: $PRETTY_NAME"
else
    log_error "Cannot detect distribution. This script requires Ubuntu or Debian."
    exit 1
fi

if [[ "$DISTRO" != "ubuntu" && "$DISTRO" != "debian" ]]; then
    log_warn "This script is designed for Ubuntu/Debian. Proceeding anyway, but some steps may fail."
fi

# ============================================================================
# Step 1: Intel GPU Compute Drivers
# ============================================================================

install_intel_gpu_drivers() {
    log_info "=== Step 1: Intel GPU Compute Drivers ==="

    # Check if Intel GPU is present
    if ! lspci | grep -qi "VGA.*Intel.*Arc\|Display.*Intel.*Arc"; then
        if lspci | grep -qi "Intel.*Graphics"; then
            log_warn "Intel GPU detected but may not be an Arc discrete GPU."
            log_warn "This setup is optimized for Arc A770. Continuing anyway..."
        else
            log_error "No Intel GPU detected. Please verify your hardware."
            exit 1
        fi
    else
        log_ok "Intel Arc GPU detected"
    fi

    # Check if user is in render and video groups
    local groups_to_add=()
    if ! id -nG "$USER" | grep -qw "render"; then
        groups_to_add+=("render")
    fi
    if ! id -nG "$USER" | grep -qw "video"; then
        groups_to_add+=("video")
    fi

    if [[ ${#groups_to_add[@]} -gt 0 ]]; then
        log_info "Adding user to groups: ${groups_to_add[*]}"
        for group in "${groups_to_add[@]}"; do
            run_sudo usermod -aG "$group" "$USER" || true
        done
        log_warn "You were added to new groups. You may need to log out and back in for this to take effect."
    else
        log_ok "User is already in render and video groups"
    fi

    # Package names for Ubuntu 24.04+ (Noble) - use intel-graphics PPA
    # Package names for Ubuntu 22.04 (Jammy) - use Intel's repository
    local level_zero_runtime level_zero_gpu level_zero_dev
    if [[ "$DISTRO" == "ubuntu" && "${DISTRO_VERSION%%.*}" -ge 24 ]]; then
        # Ubuntu 24.04+: packages from intel-graphics PPA
        level_zero_runtime="libze1"
        level_zero_gpu="libze-intel-gpu1"
        level_zero_dev="libze-dev"
    else
        # Ubuntu 22.04: packages from Intel's repository
        level_zero_runtime="libze1"
        level_zero_gpu="libze-intel-gpu1"
        level_zero_dev="libze-dev"
    fi

    # Check if ALL required Intel compute runtime packages are installed
    local missing_pkgs=()
    for pkg in intel-opencl-icd "$level_zero_gpu" "$level_zero_runtime" "$level_zero_dev" clinfo; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
        log_ok "Intel compute runtime packages already installed"
    else
        log_info "Missing packages: ${missing_pkgs[*]}"

        if ! $SUDO_AVAILABLE; then
            log_warn "Cannot install packages without sudo. Please run these commands manually:"
            echo ""
            echo "  # Add Intel graphics repo (if not already added):"
            echo "  wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | sudo gpg --dearmor --yes --output /usr/share/keyrings/intel-graphics.gpg"
            echo "  echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu noble/lts/2350 unified' | sudo tee /etc/apt/sources.list.d/intel-graphics.list"
            echo "  sudo apt-get update"
            echo "  sudo apt-get install -y ${missing_pkgs[*]}"
            echo ""
            log_warn "After installing, re-run this script."
            log_warn "Continuing with build anyway (Level Zero backend may not work without these packages)..."
        else
            log_info "Installing Intel GPU compute runtime..."

            # Add Intel graphics repository if not present
            if [[ ! -f /etc/apt/sources.list.d/intel-gpu-prerequisites.list ]] && \
               [[ ! -f /etc/apt/sources.list.d/intel-graphics.list ]] && \
               [[ ! -f /etc/apt/sources.list.d/intel-gpu-jammy.list ]]; then

                sudo apt-get update -qq
                sudo apt-get install -y -qq gpg-agent wget

                wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
                    sudo gpg --dearmor --yes --output /usr/share/keyrings/intel-graphics.gpg

                local codename
                if [[ "$DISTRO" == "ubuntu" ]]; then
                    case "$DISTRO_VERSION" in
                        22.04) codename="jammy" ;;
                        24.04|"24.10"|"25.04"|"25.10") codename="noble" ;;
                        *)     codename="jammy"; log_warn "Untested Ubuntu version, using jammy repo" ;;
                    esac
                else
                    codename="jammy"
                    log_warn "Using Ubuntu jammy repository for Debian"
                fi

                echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu ${codename} unified" | \
                    sudo tee /etc/apt/sources.list.d/intel-gpu-prerequisites.list > /dev/null

                sudo apt-get update -qq
            fi

            sudo apt-get install -y -qq "${missing_pkgs[@]}"
            log_ok "Intel compute runtime installed"
        fi
    fi

    # Verify Level Zero device is accessible
    if command -v ze_tracer &>/dev/null || [[ -d /dev/dri ]]; then
        log_ok "DRI devices present in /dev/dri/"
    else
        log_warn "/dev/dri/ not found. GPU may not be accessible."
    fi
}

# ============================================================================
# Step 2: Intel oneAPI Toolkit
# ============================================================================

install_oneapi() {
    log_info "=== Step 2: Intel oneAPI Toolkit ==="

    # Check if oneAPI is already installed
    if [[ -f /opt/intel/oneapi/setvars.sh ]]; then
        log_ok "oneAPI toolkit already installed at /opt/intel/oneapi/"
        return
    fi

    if ! $SUDO_AVAILABLE; then
        log_error "Cannot install oneAPI without sudo. Please install manually:"
        log_error "  https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit-download.html"
        log_error "Or run:  sudo apt-get install -y intel-oneapi-compiler-dpcpp-cpp intel-oneapi-mkl-devel"
        exit 1
    fi

    log_info "Installing Intel oneAPI Base Toolkit (this may take a while, ~20GB)..."

    # Add oneAPI repository
    if [[ ! -f /etc/apt/sources.list.d/oneAPI.list ]] && \
       [[ ! -f /etc/apt/sources.list.d/intel-oneapi.list ]]; then

        wget -qO - https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB | \
            sudo gpg --dearmor --output /usr/share/keyrings/oneapi-archive-keyring.gpg

        echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" | \
            sudo tee /etc/apt/sources.list.d/intel-oneapi.list > /dev/null

        sudo apt-get update -qq
    fi

    # Install only what we need: DPC++ compiler and MKL
    sudo apt-get install -y \
        intel-oneapi-compiler-dpcpp-cpp \
        intel-oneapi-mkl-devel

    if [[ -f /opt/intel/oneapi/setvars.sh ]]; then
        log_ok "oneAPI toolkit installed successfully"
    else
        log_error "oneAPI installation failed. Please install manually:"
        log_error "  https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit-download.html"
        exit 1
    fi
}

# ============================================================================
# Step 3: Build llama.cpp with SYCL
# ============================================================================

build_llama_cpp() {
    log_info "=== Step 3: Building llama.cpp with SYCL backend ==="

    # Install build dependencies (only if missing)
    local build_deps_missing=()
    for dep in git cmake make g++ pkg-config; do
        if ! command -v "$dep" &>/dev/null; then
            build_deps_missing+=("$dep")
        fi
    done
    if [[ ${#build_deps_missing[@]} -gt 0 ]]; then
        log_info "Missing build tools: ${build_deps_missing[*]}"
        if $SUDO_AVAILABLE; then
            sudo apt-get install -y -qq git cmake build-essential pkg-config
        else
            # Check if the critical ones (git, cmake, g++) are present
            local critical_missing=false
            for dep in git cmake g++; do
                if ! command -v "$dep" &>/dev/null; then
                    critical_missing=true
                fi
            done
            if $critical_missing; then
                log_error "Missing critical build tools. Please run:"
                log_error "  sudo apt-get install -y git cmake build-essential pkg-config"
                exit 1
            else
                log_warn "Optional build tool(s) missing: ${build_deps_missing[*]}"
                log_warn "Build may still succeed. If not, run: sudo apt-get install -y git cmake build-essential pkg-config"
            fi
        fi
    else
        log_ok "Build dependencies already installed"
    fi

    # Source oneAPI environment
    log_info "Sourcing oneAPI environment..."
    set +u  # setvars.sh may use unset variables
    source /opt/intel/oneapi/setvars.sh 2>/dev/null || true
    set -u

    # Clone or update llama.cpp
    if [[ -d "$LLAMA_CPP_DIR" ]]; then
        log_info "llama.cpp directory exists, pulling latest..."
        cd "$LLAMA_CPP_DIR"
        git pull --ff-only || {
            log_warn "git pull failed. Using existing version."
        }
    else
        log_info "Cloning llama.cpp..."
        git clone "$LLAMA_CPP_REPO" "$LLAMA_CPP_DIR"
    fi

    cd "$LLAMA_CPP_DIR"

    # Skip rebuild if binary already exists
    if [[ -x "$LLAMA_CPP_DIR/build/bin/llama-server" ]] || [[ -x "$LLAMA_CPP_DIR/build/llama-server" ]]; then
        log_ok "llama-server already built, skipping rebuild (delete llama.cpp/build/ to force)"
        return
    fi

    # Clean previous build
    rm -rf build

    # Build with SYCL
    log_info "Configuring cmake with SYCL backend..."
    cmake -B build \
        -DGGML_SYCL=ON \
        -DCMAKE_C_COMPILER=icx \
        -DCMAKE_CXX_COMPILER=icpx \
        -DCMAKE_BUILD_TYPE=Release

    log_info "Building (this may take 5-15 minutes)..."
    cmake --build build --config Release -j "$(nproc)"

    # Verify build
    if [[ -x "$LLAMA_CPP_DIR/build/bin/llama-server" ]]; then
        log_ok "llama-server built successfully"
    elif [[ -x "$LLAMA_CPP_DIR/build/llama-server" ]]; then
        log_ok "llama-server built successfully"
    else
        log_error "Build failed. llama-server binary not found."
        log_error "Check build output above for errors."
        exit 1
    fi

    # Verify SYCL device detection
    log_info "Checking SYCL device detection..."
    export UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1
    if command -v sycl-ls &>/dev/null; then
        sycl-ls
    else
        log_warn "sycl-ls not in PATH. Verify device detection when running the server."
    fi
}

# ============================================================================
# Step 4: Download default model
# ============================================================================

download_model() {
    log_info "=== Step 4: Downloading default model ==="

    mkdir -p "$MODELS_DIR"

    local model_path="$MODELS_DIR/$DEFAULT_MODEL_FILE"

    if [[ -f "$model_path" ]]; then
        log_ok "Default model already downloaded: $model_path"
        return
    fi

    # Find or install huggingface-cli
    local hf_cli=""
    if command -v huggingface-cli &>/dev/null; then
        hf_cli="huggingface-cli"
    elif [[ -x "$HOME/.local/bin/huggingface-cli" ]]; then
        hf_cli="$HOME/.local/bin/huggingface-cli"
    else
        # Search in common locations (conda envs, pip --user)
        hf_cli=$(find "$HOME/miniconda3" "$HOME/.conda" "$HOME/.local/bin" \
            -name "huggingface-cli" -executable 2>/dev/null | head -1)
    fi

    if [[ -z "$hf_cli" ]]; then
        log_info "Installing huggingface-cli..."
        pip install --user huggingface-hub 2>/dev/null || pip3 install --user huggingface-hub
        hf_cli="$HOME/.local/bin/huggingface-cli"
        if [[ ! -x "$hf_cli" ]]; then
            # Try python module invocation as fallback
            hf_cli="python3 -m huggingface_hub.commands.huggingface_cli"
        fi
    fi

    log_info "Downloading $DEFAULT_MODEL_FILE from $DEFAULT_MODEL_REPO..."
    log_info "This is a ~7.5GB download and may take a while..."
    log_info "Using: $hf_cli"

    $hf_cli download "$DEFAULT_MODEL_REPO" \
        "$DEFAULT_MODEL_FILE" \
        --local-dir "$MODELS_DIR" \
        --local-dir-use-symlinks False

    if [[ -f "$model_path" ]]; then
        log_ok "Model downloaded: $model_path"
    else
        log_error "Model download failed. You can manually download it:"
        log_error "  huggingface-cli download $DEFAULT_MODEL_REPO $DEFAULT_MODEL_FILE --local-dir $MODELS_DIR"
        exit 1
    fi
}

# ============================================================================
# Step 5: Create environment config (XDG-compliant)
# ============================================================================

create_env_config() {
    log_info "=== Step 5: Creating environment configuration ==="

    mkdir -p "$HOME/.config/intel-gpu-inference"
    local env_file="$HOME/.config/intel-gpu-inference/env"

    if [[ -f "$env_file" ]]; then
        log_ok "Config already exists: $env_file"
        log_info "To regenerate, delete it and re-run install.sh"
        return
    fi

    # Find the llama-server binary
    local server_bin=""
    if [[ -x "$LLAMA_CPP_DIR/build/bin/llama-server" ]]; then
        server_bin="$LLAMA_CPP_DIR/build/bin/llama-server"
    elif [[ -x "$LLAMA_CPP_DIR/build/llama-server" ]]; then
        server_bin="$LLAMA_CPP_DIR/build/llama-server"
    fi

    cat > "$env_file" << EOF
# Intel Arc GPU Environment Configuration
# Source this file before running llama-server:  source ~/.config/intel-gpu-inference/env

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
export LLAMA_SERVER_BIN="$server_bin"
export MODELS_DIR="$MODELS_DIR"
export DEFAULT_MODEL="$MODELS_DIR/$DEFAULT_MODEL_FILE"

# === Server Defaults ===
export LLAMA_HOST="0.0.0.0"
export LLAMA_PORT="8080"
EOF

    chmod +x "$env_file"
    log_ok "Environment config created: $env_file"
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo ""
    echo "============================================================"
    echo "  Intel Arc A770 LLM Inference Stack Installer"
    echo "  Backend: llama.cpp with SYCL"
    echo "============================================================"
    echo ""

    install_intel_gpu_drivers
    echo ""
    install_oneapi
    echo ""
    build_llama_cpp
    echo ""
    download_model
    echo ""
    create_env_config

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}Installation complete!${NC}"
    echo "============================================================"
    echo ""
    echo "  Next steps:"
    echo "    1. Log out and back in (if you were added to new groups)"
    echo "    2. Run the server:  ./scripts/run.sh"
    echo "    3. Test it:         ./scripts/test.sh"
    echo ""
    echo "  Default model: $DEFAULT_MODEL_FILE"
    echo "  API endpoint:  http://127.0.0.1:8080/v1"
    echo ""
    echo "  See docs/models.md for model recommendations."
    echo "  See README.md for full documentation."
    echo ""
}

main "$@"
