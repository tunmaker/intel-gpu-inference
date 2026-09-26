#!/usr/bin/env bash
#
# install-piper.sh - Install the Piper neural text-to-speech server (CPU)
#
# This script:
#   1. Creates a dedicated venv under the project directory
#   2. Installs piper-tts[http] from PyPI (OHF-Voice/piper1-gpl)
#   3. Downloads the Arabic, French and English medium voices
#   4. Appends piper config to the env file
#   5. Installs and starts a systemd user service
#
# Upstream is OHF-Voice/piper1-gpl. rhasspy/piper went read-only in Oct 2025
# and is not used here. The Debian package named "piper" is an unrelated
# gaming-mouse configurator.
#
# Usage:
#   ./scripts/install-piper.sh              # Install and start
#   ./scripts/install-piper.sh --update     # Upgrade piper-tts + refresh voices
#   ./scripts/install-piper.sh --no-service # Install only, no systemd service
#
# API endpoint: POST http://<host>:9091/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENV_DIR="$PROJECT_DIR/piper-venv"
ENV_FILE="$HOME/.config/intel-gpu-inference/env"
MODELS_DIR="${MODELS_DIR:-$HOME/models}"
VOICES_DIR="${PIPER_VOICES_DIR:-$MODELS_DIR/piper}"

DEFAULT_PIPER_VOICE="en_US-ryan-medium"
PIPER_VOICES=(
    "en_US-ryan-medium"
    "fr_FR-siwis-medium"
)

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
            echo "  --update      Upgrade piper-tts + refresh voices"
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
# Step 1: Create the venv
# ============================================================================

find_python() {
    for candidate in python3 python3.13 python3.12 python3.11; do
        if command -v "$candidate" &>/dev/null && \
           "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
            echo "$candidate"
            return
        fi
    done
}

create_venv() {
    log_info "=== Step 1: Creating Piper venv ==="

    if [[ -x "$VENV_DIR/bin/python" ]] && [[ "$FORCE_UPDATE" != "true" ]]; then
        log_ok "Venv already exists: $VENV_DIR"
        return
    fi

    local python_bin
    python_bin="$(find_python)"
    if [[ -z "$python_bin" ]]; then
        log_error "No Python >= 3.10 found. Install python3 and retry."
        exit 1
    fi

    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        log_info "Creating venv with $python_bin ($("$python_bin" --version))..."
        "$python_bin" -m venv "$VENV_DIR" || {
            log_error "venv creation failed. On Debian/Ubuntu install python3-venv:"
            log_error "  sudo apt-get install -y python3-venv"
            exit 1
        }
    fi

    log_ok "Venv ready: $VENV_DIR"
}

# ============================================================================
# Step 2: Install piper-tts
# ============================================================================

install_piper() {
    log_info "=== Step 2: Installing piper-tts ==="

    if [[ "$FORCE_UPDATE" != "true" ]] && \
       "$VENV_DIR/bin/python" -c "import piper.http_server, flask" 2>/dev/null; then
        log_ok "piper-tts already installed ($("$VENV_DIR/bin/pip" show piper-tts 2>/dev/null | awk '/^Version:/{print $2}')), skipping (use --update to upgrade)"
        return
    fi

    "$VENV_DIR/bin/pip" install --quiet --upgrade pip

    local pip_args=(install --quiet 'piper-tts[http]>=1.6.0')
    if [[ "$FORCE_UPDATE" == "true" ]]; then
        pip_args=(install --quiet --upgrade 'piper-tts[http]>=1.6.0')
    fi

    log_info "Installing piper-tts[http] from PyPI..."
    "$VENV_DIR/bin/pip" "${pip_args[@]}" || {
        log_error "pip install failed. Check network access to PyPI."
        exit 1
    }

    if ! "$VENV_DIR/bin/python" -c "import piper.http_server, flask" 2>/dev/null; then
        log_error "piper-tts installed but piper.http_server is not importable."
        exit 1
    fi

    log_ok "piper-tts $("$VENV_DIR/bin/pip" show piper-tts | awk '/^Version:/{print $2}') installed (CPU onnxruntime)"
}

# ============================================================================
# Step 3: Download voices
# ============================================================================

download_voices() {
    log_info "=== Step 3: Downloading Piper voices ==="

    mkdir -p "$VOICES_DIR"

    local missing=()
    for voice in "${PIPER_VOICES[@]}"; do
        if [[ -s "$VOICES_DIR/$voice.onnx" ]] && [[ -s "$VOICES_DIR/$voice.onnx.json" ]] && \
           [[ "$FORCE_UPDATE" != "true" ]]; then
            log_ok "Voice already present: $voice"
        else
            missing+=("$voice")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return
    fi

    log_info "Downloading ${#missing[@]} voice(s) (~61MB each) into $VOICES_DIR..."
    local download_args=(-m piper.download_voices --download-dir "$VOICES_DIR")
    if [[ "$FORCE_UPDATE" == "true" ]]; then
        download_args+=(--force-redownload)
    fi

    "$VENV_DIR/bin/python" "${download_args[@]}" "${missing[@]}" || {
        log_error "Voice download failed. Check network access to huggingface.co."
        log_error "Retry manually:"
        log_error "  $VENV_DIR/bin/python -m piper.download_voices --download-dir $VOICES_DIR ${missing[*]}"
        exit 1
    }

    for voice in "${PIPER_VOICES[@]}"; do
        if [[ ! -s "$VOICES_DIR/$voice.onnx" ]] || [[ ! -s "$VOICES_DIR/$voice.onnx.json" ]]; then
            log_error "Voice missing after download: $voice"
            exit 1
        fi
    done

    log_ok "All ${#PIPER_VOICES[@]} voices installed in $VOICES_DIR"
}

# ============================================================================
# Step 4: Append piper config to env file
# ============================================================================

configure_env() {
    log_info "=== Step 4: Configuring environment ==="

    mkdir -p "$HOME/.config/intel-gpu-inference"

    if [[ -f "$ENV_FILE" ]] && grep -q "Piper Text-to-Speech" "$ENV_FILE"; then
        log_ok "Piper config already present in $ENV_FILE"
        return
    fi

    local env_template="$PROJECT_DIR/configs/piper-server.env.template"
    if [[ ! -f "$env_template" ]]; then
        log_error "Template not found: $env_template"
        exit 1
    fi

    log_info "Appending piper config to $ENV_FILE..."

    {
        echo ""
        sed -e "s|__HOME__|$HOME|g" \
            -e "s|__INSTALL_DIR__|$PROJECT_DIR|g" \
            "$env_template" | grep -v "^#.*install-piper.sh\|^#.*Appended to\|^#.*For full options"
    } >> "$ENV_FILE"

    log_ok "Piper config added to $ENV_FILE"
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

    local template="$PROJECT_DIR/piper-server.service.template"
    if [[ ! -f "$template" ]]; then
        log_error "Service template not found: $template"
        exit 1
    fi

    mkdir -p "$HOME/.config/systemd/user"
    sed -e "s|__HOME__|$HOME|g" \
        -e "s|__INSTALL_DIR__|$PROJECT_DIR|g" \
        "$template" \
        > "$HOME/.config/systemd/user/piper-server.service"

    systemctl --user daemon-reload
    systemctl --user enable piper-server.service
    systemctl --user restart piper-server.service

    log_ok "piper-server service installed and started"
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo ""
    echo "============================================================"
    echo "  Piper Text-to-Speech Server Installer"
    echo "  CPU inference (onnxruntime)"
    if [[ "$FORCE_UPDATE" == "true" ]]; then
        echo "  Mode: UPDATE (upgrade piper-tts + refresh voices)"
    fi
    echo "============================================================"
    echo ""

    create_venv
    echo ""
    install_piper
    echo ""
    download_voices
    echo ""
    configure_env
    echo ""
    install_service

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}piper-server installed!${NC}"
    echo "============================================================"
    echo ""
    echo "  Endpoint:"
    echo "    POST http://0.0.0.0:9091/          (JSON in, WAV out)"
    echo "    GET  http://0.0.0.0:9091/voices    (installed voices)"
    echo ""
    echo "  Default voice: $DEFAULT_PIPER_VOICE"
    echo "  Voices:        ${PIPER_VOICES[*]}"
    echo "  Voices dir:    $VOICES_DIR"
    echo ""
    echo "  Management:"
    echo "    Status:   systemctl --user status piper-server"
    echo "    Logs:     journalctl --user -u piper-server -f"
    echo "    Restart:  systemctl --user restart piper-server"
    echo "    Test:     ./scripts/test-piper.sh"
    echo ""
    echo "  Config:     ~/.config/intel-gpu-inference/env"
    echo ""
}

main "$@"
