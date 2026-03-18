#!/usr/bin/env bash
#
# install-embedding.sh - Install dedicated llama.cpp embedding server
#
# This script:
#   1. Verifies llama-server binary exists (built by main install.sh)
#   2. Appends embedding config to the env file
#   3. Installs and starts a systemd user service
#
# Usage:
#   ./scripts/install-embedding.sh              # Install and start
#   ./scripts/install-embedding.sh --no-service # Install only, no systemd service
#
# API endpoint: POST http://<host>:8085/v1/embeddings

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$HOME/.config/intel-gpu-inference/env"

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
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-service) INSTALL_SERVICE=false; shift ;;
        --help|-h)
            echo "Usage: $0 [--no-service]"
            echo ""
            echo "Options:"
            echo "  --no-service  Skip systemd service installation"
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
# Step 1: Verify llama-server binary exists
# ============================================================================

verify_binary() {
    log_info "=== Step 1: Verifying llama-server binary ==="

    local found=false
    for candidate in \
        "$PROJECT_DIR/llama.cpp/build/bin/llama-server" \
        "$PROJECT_DIR/llama.cpp/build/llama-server" \
        "$(command -v llama-server 2>/dev/null || true)"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            log_ok "llama-server found: $candidate"
            found=true
            break
        fi
    done

    if ! $found; then
        log_error "llama-server binary not found. Run install.sh first to build llama.cpp."
        exit 1
    fi
}

# ============================================================================
# Step 2: Append embedding config to env file
# ============================================================================

configure_env() {
    log_info "=== Step 2: Configuring environment ==="

    mkdir -p "$HOME/.config/intel-gpu-inference"

    if [[ -f "$ENV_FILE" ]] && grep -q "llama.cpp Embedding Server" "$ENV_FILE"; then
        log_ok "Embedding config already present in $ENV_FILE"
        return
    fi

    local env_template="$PROJECT_DIR/configs/embedding-server.env.template"
    if [[ ! -f "$env_template" ]]; then
        log_error "Template not found: $env_template"
        exit 1
    fi

    log_info "Appending embedding config to $ENV_FILE..."

    {
        echo ""
        sed -e "s|__HOME__|$HOME|g" \
            -e "s|__INSTALL_DIR__|$PROJECT_DIR|g" \
            "$env_template" | grep -v "^#.*install-embedding.sh\|^#.*Appended to\|^#.*For full options"
    } >> "$ENV_FILE"

    log_ok "Embedding config added to $ENV_FILE"
}

# ============================================================================
# Step 3: Install systemd user service
# ============================================================================

install_service() {
    if ! $INSTALL_SERVICE; then
        log_info "Skipping systemd service installation (--no-service)"
        return
    fi

    log_info "=== Step 3: Installing systemd user service ==="

    local template="$PROJECT_DIR/embedding-server.service.template"
    if [[ ! -f "$template" ]]; then
        log_error "Service template not found: $template"
        exit 1
    fi

    mkdir -p "$HOME/.config/systemd/user"
    sed -e "s|__HOME__|$HOME|g" \
        -e "s|__INSTALL_DIR__|$PROJECT_DIR|g" \
        "$template" \
        > "$HOME/.config/systemd/user/embedding-server.service"

    systemctl --user daemon-reload
    systemctl --user enable embedding-server.service
    systemctl --user start embedding-server.service

    log_ok "embedding-server service installed and started"
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo ""
    echo "============================================================"
    echo "  llama.cpp Embedding Server Installer"
    echo "  SYCL backend for Intel Arc A770"
    echo "============================================================"
    echo ""

    verify_binary
    echo ""
    configure_env
    echo ""
    install_service

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}embedding-server installed!${NC}"
    echo "============================================================"
    echo ""
    echo "  Endpoint:"
    echo "    POST http://0.0.0.0:8085/v1/embeddings"
    echo ""
    echo "  Model:    set EMBEDDING_MODEL in ~/.config/intel-gpu-inference/env"
    echo ""
    echo "  Management:"
    echo "    Status:   systemctl --user status embedding-server"
    echo "    Logs:     journalctl --user -u embedding-server -f"
    echo "    Restart:  systemctl --user restart embedding-server"
    echo ""
    echo "  Config:     ~/.config/intel-gpu-inference/env"
    echo ""
    echo "  Test:"
    echo "    curl http://localhost:8085/v1/embeddings \\"
    echo "      -H 'Content-Type: application/json' \\"
    echo "      -d '{\"input\": \"Hello world\", \"model\": \"embedding\"}'"
    echo ""
}

main "$@"
