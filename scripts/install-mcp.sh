#!/usr/bin/env bash
#
# install-mcp.sh - Install the open-websearch MCP server for web search tools
#
# This script:
#   1. Ensures Node.js 20+ is installed
#   2. Clones and builds open-websearch
#   3. Appends MCP config to the env file
#   4. Installs and starts a systemd user service
#
# Usage:
#   ./scripts/install-mcp.sh              # Install and start
#   ./scripts/install-mcp.sh --no-service # Install only, no systemd service
#
# The MCP server exposes web search tools via:
#   SSE:             http://<host>:3000/sse
#   streamableHttp:  http://<host>:3000/mcp

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WEBSEARCH_DIR="$PROJECT_DIR/open-websearch"
ENV_FILE="$HOME/.config/intel-gpu-inference/env"

MIN_NODE_MAJOR=20

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

SUDO_AVAILABLE=true
if ! sudo -n true 2>/dev/null; then
    if ! sudo -v 2>/dev/null; then
        SUDO_AVAILABLE=false
        log_warn "sudo is not available without a password."
        log_warn "Steps requiring root will print commands for you to run manually."
    fi
fi

run_sudo() {
    if $SUDO_AVAILABLE; then
        sudo "$@"
    else
        log_warn "Please run manually:  sudo $*"
        return 1
    fi
}

# ============================================================================
# Step 1: Ensure Node.js 18+
# ============================================================================

install_nodejs() {
    log_info "=== Step 1: Checking Node.js ==="

    if command -v node &>/dev/null; then
        local node_version
        node_version=$(node --version | sed 's/^v//')
        local node_major="${node_version%%.*}"
        if [[ "$node_major" -ge "$MIN_NODE_MAJOR" ]]; then
            log_ok "Node.js $node_version already installed"
            return
        else
            log_warn "Node.js $node_version is too old (need >= $MIN_NODE_MAJOR)"
        fi
    fi

    log_info "Installing Node.js $MIN_NODE_MAJOR via NodeSource..."

    if ! $SUDO_AVAILABLE; then
        log_error "Cannot install Node.js without sudo. Please install Node.js >= $MIN_NODE_MAJOR manually:"
        log_error "  https://nodejs.org/en/download/package-manager"
        exit 1
    fi

    # NodeSource setup script
    curl -fsSL "https://deb.nodesource.com/setup_${MIN_NODE_MAJOR}.x" | sudo -E bash -
    sudo apt-get install -y nodejs

    if command -v node &>/dev/null; then
        log_ok "Node.js $(node --version) installed"
    else
        log_error "Node.js installation failed."
        exit 1
    fi
}

# ============================================================================
# Step 2: Clone and build open-websearch
# ============================================================================

build_websearch() {
    log_info "=== Step 2: Building open-websearch MCP server ==="

    if [[ ! -f "$WEBSEARCH_DIR/package.json" ]]; then
        log_info "Initializing open-websearch submodule..."
        cd "$PROJECT_DIR"
        git submodule update --init open-websearch
    else
        log_info "open-websearch submodule already initialized"
    fi

    cd "$WEBSEARCH_DIR"

    # Skip rebuild if dist/ already exists
    if [[ -f "$WEBSEARCH_DIR/build/index.js" ]]; then
        log_ok "open-websearch already built (delete open-websearch/dist/ to force rebuild)"
        return
    fi

    log_info "Installing npm dependencies..."
    npm install

    log_info "Building..."
    npm run build

    if [[ -f "$WEBSEARCH_DIR/build/index.js" ]]; then
        log_ok "open-websearch built successfully"
    else
        log_error "Build failed. build/index.js not found."
        exit 1
    fi
}

# ============================================================================
# Step 3: Append MCP config to env file
# ============================================================================

configure_env() {
    log_info "=== Step 3: Configuring environment ==="

    mkdir -p "$HOME/.config/intel-gpu-inference"

    if [[ -f "$ENV_FILE" ]] && grep -q "open-websearch MCP" "$ENV_FILE"; then
        log_ok "MCP config already present in $ENV_FILE"
        return
    fi

    local env_template="$PROJECT_DIR/configs/open-websearch.env.template"
    if [[ ! -f "$env_template" ]]; then
        log_error "Template not found: $env_template"
        exit 1
    fi

    log_info "Appending MCP config to $ENV_FILE..."

    {
        echo ""
        echo "# === open-websearch MCP Server ==="
        cat "$env_template" | grep -v "^#.*install-mcp.sh\|^#.*Appended to\|^#.*For full options"
    } >> "$ENV_FILE"

    log_ok "MCP config added to $ENV_FILE"
}

# ============================================================================
# Step 4: Install systemd user service
# ============================================================================

install_service() {
    if ! $INSTALL_SERVICE; then
        log_info "Skipping systemd service installation (--no-service)"
        return
    fi

    log_info "=== Step 4: Installing systemd user service ==="

    local template="$PROJECT_DIR/open-websearch.service.template"
    if [[ ! -f "$template" ]]; then
        log_error "Service template not found: $template"
        exit 1
    fi

    mkdir -p "$HOME/.config/systemd/user"
    sed -e "s|__HOME__|$HOME|g" \
        -e "s|__INSTALL_DIR__|$PROJECT_DIR|g" \
        "$template" \
        > "$HOME/.config/systemd/user/open-websearch.service"

    systemctl --user daemon-reload
    systemctl --user enable open-websearch.service
    systemctl --user start open-websearch.service

    log_ok "open-websearch service installed and started"
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo ""
    echo "============================================================"
    echo "  open-websearch MCP Server Installer"
    echo "  Web search tools for LLM agents (no API keys required)"
    echo "============================================================"
    echo ""

    install_nodejs
    echo ""
    build_websearch
    echo ""
    configure_env
    echo ""
    install_service

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}MCP server installed!${NC}"
    echo "============================================================"
    echo ""
    echo "  Endpoints:"
    echo "    SSE:             http://0.0.0.0:3000/sse"
    echo "    streamableHttp:  http://0.0.0.0:3000/mcp"
    echo ""
    echo "  Tools available:"
    echo "    search_web           Multi-engine web search"
    echo "    fetchArticle         Fetch article content"
    echo "    fetchGithubReadme    Fetch GitHub README files"
    echo ""
    echo "  Management:"
    echo "    Status:   systemctl --user status open-websearch"
    echo "    Logs:     journalctl --user -u open-websearch -f"
    echo "    Restart:  systemctl --user restart open-websearch"
    echo "    Test:     ./scripts/test-mcp.sh"
    echo ""
    echo "  Config:     ~/.config/intel-gpu-inference/env"
    echo ""
}

main "$@"
