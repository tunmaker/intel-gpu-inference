#!/usr/bin/env bash
#
# install-whisper.sh - Install whisper.cpp speech recognition server with SYCL backend
#
# This script:
#   1. Initializes whisper.cpp submodule and pulls latest
#   2. Builds whisper.cpp with SYCL backend (Intel Arc GPU)
#   3. Downloads the whisper large-v3 model
#   4. Appends whisper config to the env file
#   5. Installs and starts a systemd user service
#
# Usage:
#   ./scripts/install-whisper.sh              # Install and start
#   ./scripts/install-whisper.sh --update     # Pull latest + force rebuild
#   ./scripts/install-whisper.sh --no-service # Install only, no systemd service
#
# API endpoint: POST http://<host>:9090/inference

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WHISPER_CPP_DIR="$PROJECT_DIR/whisper.cpp"
ENV_FILE="$HOME/.config/intel-gpu-inference/env"
MODELS_DIR="${MODELS_DIR:-$HOME/models}"

DEFAULT_WHISPER_MODEL="ggml-large-v3.bin"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ============================================================================
# Parse arguments
# ============================================================================

INSTALL_SERVICE=true
FORCE_UPDATE=false
export FORCE_UPDATE
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-service) INSTALL_SERVICE=false; shift ;;
        --update) FORCE_UPDATE=true; export FORCE_UPDATE; shift ;;
        --help|-h)
            echo "Usage: $0 [--no-service] [--update]"
            echo ""
            echo "Options:"
            echo "  --no-service  Skip systemd service installation"
            echo "  --update      Pull latest + force rebuild"
            exit 0
            ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

# ============================================================================
# Pre-flight checks
# ============================================================================

if [[ $EUID -eq 0 ]]; then
    log_error "Do not run this script as root. It will use sudo when needed."
    exit 1
fi

# ============================================================================
# Step 1: Initialize submodule and pull latest
# ============================================================================

init_submodule() {
    log_info "=== Step 1: Initializing whisper.cpp submodule ==="

    cd "$PROJECT_DIR"
    if [[ ! -f "$WHISPER_CPP_DIR/CMakeLists.txt" ]]; then
        log_info "Initializing whisper.cpp submodule..."
        git submodule update --init whisper.cpp
    fi

    cd "$WHISPER_CPP_DIR"
    log_info "Updating whisper.cpp to latest master..."
    git checkout master 2>/dev/null || true
    git pull --ff-only || {
        log_warn "git pull failed. Using existing version."
    }
    log_info "whisper.cpp at: $(git log --oneline -1)"
}

# ============================================================================
# Step 2: Build whisper.cpp with SYCL
# ============================================================================

build_whisper() {
    log_info "=== Step 2: Building whisper.cpp with SYCL backend ==="

    # Source oneAPI environment
    log_info "Sourcing oneAPI environment..."
    set +u
    source /opt/intel/oneapi/setvars.sh 2>/dev/null || true
    set -u

    cd "$WHISPER_CPP_DIR"

    # Skip rebuild if binary exists and --update was not passed
    if [[ "${FORCE_UPDATE:-false}" != "true" ]] && \
       { [[ -x "$WHISPER_CPP_DIR/build/bin/whisper-server" ]] || [[ -x "$WHISPER_CPP_DIR/build/whisper-server" ]]; }; then
        log_ok "whisper-server already built, skipping rebuild (use --update to force)"
        return
    fi

    # Check build dependencies
    for dep in cmake icx icpx; do
        if ! command -v "$dep" &>/dev/null; then
            log_error "Required tool not found: $dep"
            log_error "Ensure oneAPI toolkit is installed. Run scripts/install.sh first."
            exit 1
        fi
    done

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
    if [[ -x "$WHISPER_CPP_DIR/build/bin/whisper-server" ]]; then
        log_ok "whisper-server built successfully"
    elif [[ -x "$WHISPER_CPP_DIR/build/whisper-server" ]]; then
        log_ok "whisper-server built successfully"
    else
        log_error "Build failed. whisper-server binary not found."
        log_error "Check build output above for errors."
        exit 1
    fi
}

# ============================================================================
# Step 3: Download whisper model
# ============================================================================

download_model() {
    log_info "=== Step 3: Downloading whisper model ==="

    local model_path="$MODELS_DIR/$DEFAULT_WHISPER_MODEL"

    if [[ -f "$model_path" ]]; then
        log_ok "Model already exists: $model_path"
        return
    fi

    mkdir -p "$MODELS_DIR"

    # Use whisper.cpp's built-in download script
    local download_script="$WHISPER_CPP_DIR/models/download-ggml-model.sh"
    if [[ -x "$download_script" ]]; then
        log_info "Downloading large-v3 model (~3GB)..."
        bash "$download_script" large-v3

        # Move from whisper.cpp/models/ to ~/models/
        if [[ -f "$WHISPER_CPP_DIR/models/$DEFAULT_WHISPER_MODEL" ]]; then
            mv "$WHISPER_CPP_DIR/models/$DEFAULT_WHISPER_MODEL" "$model_path"
            log_ok "Model installed: $model_path"
        else
            log_error "Download script did not produce expected file."
            log_error "Try manually: bash $download_script large-v3"
            exit 1
        fi
    else
        # Fallback: direct download from Hugging Face
        local model_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$DEFAULT_WHISPER_MODEL"
        log_info "Downloading large-v3 model from Hugging Face (~3GB)..."
        if command -v wget &>/dev/null; then
            wget -O "$model_path" "$model_url"
        elif command -v curl &>/dev/null; then
            curl -L -o "$model_path" "$model_url"
        else
            log_error "Neither wget nor curl found. Please install one and retry."
            exit 1
        fi

        if [[ -f "$model_path" ]]; then
            log_ok "Model downloaded: $model_path"
        else
            log_error "Model download failed."
            exit 1
        fi
    fi
}

# ============================================================================
# Step 4: Append whisper config to env file
# ============================================================================

configure_env() {
    log_info "=== Step 4: Configuring environment ==="

    mkdir -p "$HOME/.config/intel-gpu-inference"

    if [[ -f "$ENV_FILE" ]] && grep -q "whisper.cpp Speech Recognition" "$ENV_FILE"; then
        log_ok "Whisper config already present in $ENV_FILE"
        return
    fi

    local env_template="$PROJECT_DIR/configs/whisper-server.env.template"
    if [[ ! -f "$env_template" ]]; then
        log_error "Template not found: $env_template"
        exit 1
    fi

    log_info "Appending whisper config to $ENV_FILE..."

    {
        echo ""
        sed -e "s|__HOME__|$HOME|g" \
            -e "s|__INSTALL_DIR__|$PROJECT_DIR|g" \
            "$env_template" | grep -v "^#.*install-whisper.sh\|^#.*Appended to\|^#.*For full options"
    } >> "$ENV_FILE"

    log_ok "Whisper config added to $ENV_FILE"
}

# ============================================================================
# Step 5: Install systemd user service
# ============================================================================

install_service() {
    if ! $INSTALL_SERVICE; then
        log_info "Skipping systemd service installation (--no-service)"
        return
    fi

    log_info "=== Step 5: Installing systemd user service ==="

    local template="$PROJECT_DIR/whisper-server.service.template"
    if [[ ! -f "$template" ]]; then
        log_error "Service template not found: $template"
        exit 1
    fi

    mkdir -p "$HOME/.config/systemd/user"
    sed -e "s|__HOME__|$HOME|g" \
        -e "s|__INSTALL_DIR__|$PROJECT_DIR|g" \
        "$template" \
        > "$HOME/.config/systemd/user/whisper-server.service"

    systemctl --user daemon-reload
    systemctl --user enable whisper-server.service
    systemctl --user start whisper-server.service

    log_ok "whisper-server service installed and started"
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo ""
    echo "============================================================"
    echo "  whisper.cpp Speech Recognition Server Installer"
    echo "  SYCL backend for Intel Arc A770"
    if [[ "$FORCE_UPDATE" == "true" ]]; then
        echo "  Mode: UPDATE (pull latest + rebuild)"
    fi
    echo "============================================================"
    echo ""

    init_submodule
    echo ""
    build_whisper
    echo ""
    download_model
    echo ""
    configure_env
    echo ""
    install_service

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}whisper-server installed!${NC}"
    echo "============================================================"
    echo ""
    echo "  Endpoint:"
    echo "    POST http://0.0.0.0:9090/inference"
    echo ""
    echo "  Model:    $DEFAULT_WHISPER_MODEL (multilingual: ar, en, fr, zh)"
    echo "  Language:  auto-detect"
    echo ""
    echo "  Management:"
    echo "    Status:   systemctl --user status whisper-server"
    echo "    Logs:     journalctl --user -u whisper-server -f"
    echo "    Restart:  systemctl --user restart whisper-server"
    echo "    Test:     ./scripts/test-whisper.sh"
    echo ""
    echo "  Config:     ~/.config/intel-gpu-inference/env"
    echo ""
}

main "$@"
