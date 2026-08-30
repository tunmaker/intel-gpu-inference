#!/usr/bin/env bash
#
# install-vosk.sh - Install the Vosk speech recognition server (CPU, Tunisian Derja)
#
# This script:
#   1. Creates a dedicated venv under the project directory
#   2. Installs vosk + flask from PyPI
#   3. Downloads and unpacks vosk-model-ar-tn-0.1-linto (~517MB)
#   4. Measures the resident size of the loaded model
#   5. Appends vosk config to the env file
#   6. Installs a systemd user service with MemoryMax derived from step 4
#
# The model is Kaldi (nnet3 + WFST), CPU-only. Kaldi's GPU decoders are
# CUDA-only, so there is no Arc path and none is attempted.
#
# Usage:
#   ./scripts/install-vosk.sh              # Install and start
#   ./scripts/install-vosk.sh --update     # Upgrade vosk + re-download model
#   ./scripts/install-vosk.sh --no-service # Install only, no systemd service
#
# API endpoint: POST http://<host>:9092/inference  (whisper-server compatible)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENV_DIR="$PROJECT_DIR/vosk-venv"
ENV_FILE="$HOME/.config/intel-gpu-inference/env"
MODELS_DIR="${MODELS_DIR:-$HOME/models}"
VOSK_DIR="$MODELS_DIR/vosk"

MODEL_NAME="vosk-model-ar-tn-0.1-linto"
MODEL_URL="https://alphacephei.com/vosk/models/${MODEL_NAME}.zip"
MODEL_PATH="$VOSK_DIR/$MODEL_NAME"

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
            echo "  --update      Upgrade vosk + re-download model"
            exit 0
            ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ $EUID -eq 0 ]]; then
    log_error "Do not run this script as root. It will use sudo when needed."
    exit 1
fi

# ============================================================================
# Step 1: Create the venv
# ============================================================================

find_python() {
    for candidate in python3 python3.12 python3.11 python3.10; do
        if command -v "$candidate" &>/dev/null && \
           "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
            echo "$candidate"
            return
        fi
    done
}

create_venv() {
    log_info "=== Step 1: Creating Vosk venv ==="

    if [[ -x "$VENV_DIR/bin/python" ]]; then
        log_ok "Venv already exists: $VENV_DIR"
        return
    fi

    local python_bin
    python_bin="$(find_python)"
    if [[ -z "$python_bin" ]]; then
        log_error "No Python >= 3.9 found. Install python3 and retry."
        exit 1
    fi

    log_info "Creating venv with $python_bin ($("$python_bin" --version))..."
    "$python_bin" -m venv "$VENV_DIR" || {
        log_error "venv creation failed. On Debian/Ubuntu install python3-venv:"
        log_error "  sudo apt-get install -y python3-venv"
        exit 1
    }

    log_ok "Venv ready: $VENV_DIR"
}

# ============================================================================
# Step 2: Install vosk + flask
# ============================================================================

install_vosk() {
    log_info "=== Step 2: Installing vosk + flask ==="

    if [[ "$FORCE_UPDATE" != "true" ]] && \
       "$VENV_DIR/bin/python" -c "import vosk, flask" 2>/dev/null; then
        log_ok "vosk $("$VENV_DIR/bin/pip" show vosk 2>/dev/null | awk '/^Version:/{print $2}') already installed (use --update to upgrade)"
        return
    fi

    "$VENV_DIR/bin/pip" install --quiet --upgrade pip

    local pip_args=(install --quiet vosk flask)
    if [[ "$FORCE_UPDATE" == "true" ]]; then
        pip_args=(install --quiet --upgrade vosk flask)
    fi

    log_info "Installing from PyPI..."
    "$VENV_DIR/bin/pip" "${pip_args[@]}" || {
        log_error "pip install failed. Check network access to PyPI."
        exit 1
    }

    if ! "$VENV_DIR/bin/python" -c "import vosk, flask" 2>/dev/null; then
        log_error "vosk installed but not importable."
        exit 1
    fi

    log_ok "vosk $("$VENV_DIR/bin/pip" show vosk | awk '/^Version:/{print $2}') installed (CPU Kaldi)"
}

# ============================================================================
# Step 3: Download and unpack the model
# ============================================================================

download_model() {
    log_info "=== Step 3: Downloading the Tunisian Derja model ==="

    mkdir -p "$VOSK_DIR"

    if [[ -f "$MODEL_PATH/am/final.mdl" ]] && [[ "$FORCE_UPDATE" != "true" ]]; then
        log_ok "Model already installed: $MODEL_PATH"
        return
    fi

    local zip_path="$VOSK_DIR/${MODEL_NAME}.zip"

    if [[ ! -s "$zip_path" ]] || [[ "$FORCE_UPDATE" == "true" ]]; then
        log_info "Downloading $MODEL_NAME (~517MB)..."
        if command -v wget &>/dev/null; then
            wget -O "$zip_path" "$MODEL_URL" || { log_error "Download failed."; exit 1; }
        elif command -v curl &>/dev/null; then
            curl -fL --retry 3 -o "$zip_path" "$MODEL_URL" || { log_error "Download failed."; exit 1; }
        else
            log_error "Neither wget nor curl found."
            exit 1
        fi
    else
        log_ok "Archive already downloaded: $zip_path"
    fi

    log_info "Unpacking..."
    rm -rf "$MODEL_PATH"
    # Python's zipfile is always present in the venv, so this needs no sudo and
    # no unzip package on the host.
    "$VENV_DIR/bin/python" - "$zip_path" "$VOSK_DIR" <<'PYEOF' || { log_error "Unpack failed."; exit 1; }
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
PYEOF

    if [[ ! -f "$MODEL_PATH/am/final.mdl" ]]; then
        log_error "Unpacked archive does not contain $MODEL_PATH/am/final.mdl"
        exit 1
    fi

    rm -f "$zip_path"
    log_ok "Model installed: $MODEL_PATH ($(du -sh "$MODEL_PATH" | cut -f1))"
}

# ============================================================================
# Step 4: Measure resident size, then size the cgroup limits from it
# ============================================================================

VOSK_MEM_HIGH="768M"
VOSK_MEM_MAX="1G"

measure_model() {
    log_info "=== Step 4: Measuring resident size of the loaded model ==="

    local measured
    measured=$("$VENV_DIR/bin/python" - "$MODEL_PATH" <<'PYEOF' 2>/dev/null || true
import resource, sys
from vosk import Model, KaldiRecognizer, SetLogLevel
SetLogLevel(-1)
model = Model(sys.argv[1])
rec = KaldiRecognizer(model, 16000)
rec.AcceptWaveform(b"\0" * 32000)
rec.FinalResult()
print(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024)
PYEOF
)

    if [[ -z "$measured" ]] || ! [[ "$measured" =~ ^[0-9]+$ ]]; then
        log_warn "Could not measure model memory; falling back to ${VOSK_MEM_MAX} cap."
        return
    fi

    # This measures process RSS, but the cgroup also charges page cache for the
    # ~1.4GB of model files, which ran ~60% above RSS when measured. Sizing off
    # RSS alone produces a cap the service sits against at idle, thrashing the
    # model out of cache on every reclaim. Hence 2x soft / 2.5x hard.
    local high=$(( measured * 2 ))
    local max=$(( measured * 5 / 2 ))
    (( high < 768 )) && high=768
    (( max < 1024 )) && max=1024

    VOSK_MEM_HIGH="${high}M"
    VOSK_MEM_MAX="${max}M"

    log_ok "Loaded model peak RSS: ${measured}MB  ->  MemoryHigh=${VOSK_MEM_HIGH} MemoryMax=${VOSK_MEM_MAX}"

    local avail
    avail=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
    log_info "Container reports ${avail}MB available right now."
    if (( max > avail )); then
        log_warn "MemoryMax (${max}MB) exceeds currently available memory (${avail}MB)."
        log_warn "whisper-server also spikes to several GB while transcribing; watch for OOM."
    fi
}

# ============================================================================
# Step 5: Append vosk config to env file
# ============================================================================

configure_env() {
    log_info "=== Step 5: Configuring environment ==="

    mkdir -p "$HOME/.config/intel-gpu-inference"

    if [[ -f "$ENV_FILE" ]] && grep -q "Vosk Speech Recognition" "$ENV_FILE"; then
        log_ok "Vosk config already present in $ENV_FILE"
        return
    fi

    local env_template="$PROJECT_DIR/configs/vosk-server.env.template"
    if [[ ! -f "$env_template" ]]; then
        log_error "Template not found: $env_template"
        exit 1
    fi

    log_info "Appending vosk config to $ENV_FILE..."

    {
        echo ""
        sed -e "s|__HOME__|$HOME|g" \
            -e "s|__INSTALL_DIR__|$PROJECT_DIR|g" \
            "$env_template" | grep -v "^#.*install-vosk.sh\|^#.*Appended to\|^#.*For full options"
    } >> "$ENV_FILE"

    log_ok "Vosk config added to $ENV_FILE"
}

# ============================================================================
# Step 6: Install systemd user service
# ============================================================================

install_service() {
    if ! $INSTALL_SERVICE; then
        log_info "Skipping systemd service installation (--no-service)"
        return
    fi

    log_info "=== Step 6: Installing systemd user service ==="

    local template="$PROJECT_DIR/vosk-server.service.template"
    if [[ ! -f "$template" ]]; then
        log_error "Service template not found: $template"
        exit 1
    fi

    mkdir -p "$HOME/.config/systemd/user"
    sed -e "s|__HOME__|$HOME|g" \
        -e "s|__INSTALL_DIR__|$PROJECT_DIR|g" \
        -e "s|__VOSK_MEM_HIGH__|$VOSK_MEM_HIGH|g" \
        -e "s|__VOSK_MEM_MAX__|$VOSK_MEM_MAX|g" \
        "$template" \
        > "$HOME/.config/systemd/user/vosk-server.service"

    systemctl --user daemon-reload
    systemctl --user enable vosk-server.service
    systemctl --user restart vosk-server.service

    log_ok "vosk-server service installed and started"
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo ""
    echo "============================================================"
    echo "  Vosk Speech Recognition Server Installer"
    echo "  Tunisian Derja (ar-tn), CPU-only Kaldi"
    if [[ "$FORCE_UPDATE" == "true" ]]; then
        echo "  Mode: UPDATE"
    fi
    echo "============================================================"
    echo ""

    create_venv
    echo ""
    install_vosk
    echo ""
    download_model
    echo ""
    measure_model
    echo ""
    configure_env
    echo ""
    install_service

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}vosk-server installed!${NC}"
    echo "============================================================"
    echo ""
    echo "  Endpoint:"
    echo "    POST http://0.0.0.0:9092/inference   (same contract as whisper-server)"
    echo ""
    echo "  Model:    $MODEL_NAME"
    echo "  Limits:   MemoryHigh=$VOSK_MEM_HIGH MemoryMax=$VOSK_MEM_MAX"
    echo ""
    echo "  Management:"
    echo "    Status:   systemctl --user status vosk-server"
    echo "    Logs:     journalctl --user -u vosk-server -f"
    echo "    Restart:  systemctl --user restart vosk-server"
    echo "    Test:     ./scripts/test-vosk.sh"
    echo ""
    echo "  Config:     ~/.config/intel-gpu-inference/env"
    echo ""
}

main "$@"
