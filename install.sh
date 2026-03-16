#!/usr/bin/env bash
#
# install.sh - Top-level installer for Intel GPU inference stack
#
# Usage:
#   ./install.sh                    # Install llama-server service
#   ./install.sh --with-mcp         # Also install MCP web search server
#   ./install.sh --update           # Pull latest submodules + rebuild all
#   ./install.sh --with-whisper      # Also install whisper speech recognition
#   ./install.sh --update --with-mcp --with-whisper # Update everything

set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse flags
WITH_MCP=false
WITH_WHISPER=false
UPDATE=false
for arg in "$@"; do
    case "$arg" in
        --with-mcp)     WITH_MCP=true ;;
        --with-whisper) WITH_WHISPER=true ;;
        --update)       UPDATE=true ;;
    esac
done

# 1. Init submodules
echo "[intel-gpu-inference] Initializing submodules..."
cd "$INSTALL_DIR"
git submodule update --init --recursive

# 2. Build llama.cpp
if [[ "$UPDATE" == "true" ]]; then
    echo "[intel-gpu-inference] Updating and rebuilding llama.cpp..."
    bash "$INSTALL_DIR/scripts/install.sh" --update
elif [ ! -x "$INSTALL_DIR/llama.cpp/build/bin/llama-server" ] &&
     [ ! -x "$INSTALL_DIR/llama.cpp/build/llama-server" ]; then
    echo "[intel-gpu-inference] llama-server not built — running scripts/install.sh..."
    bash "$INSTALL_DIR/scripts/install.sh"
else
    echo "[intel-gpu-inference] llama-server already built (use --update to rebuild)"
fi

# 3. XDG config
mkdir -p "$HOME/.config/intel-gpu-inference"
if [ ! -f "$HOME/.config/intel-gpu-inference/env" ]; then
    sed -e "s|__HOME__|$HOME|g" \
        -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
        "$INSTALL_DIR/configs/llama-server.env.template" \
        > "$HOME/.config/intel-gpu-inference/env"
    echo "Config installed at ~/.config/intel-gpu-inference/env — edit before starting"
else
    echo "Config already exists at ~/.config/intel-gpu-inference/env — skipping"
fi

# 4. Service file
mkdir -p "$HOME/.config/systemd/user"
sed -e "s|__HOME__|$HOME|g" \
    -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
    "$INSTALL_DIR/llama-server.service.template" \
    > "$HOME/.config/systemd/user/llama-server.service"

# 5. Enable + start
systemctl --user daemon-reload
systemctl --user enable llama-server.service
systemctl --user restart llama-server.service
echo "llama-server installed and started"

# 6. (Optional) MCP web search server
if [[ "$WITH_MCP" == "true" ]]; then
    echo ""
    echo "[intel-gpu-inference] Installing open-websearch MCP server..."
    if [[ "$UPDATE" == "true" ]]; then
        bash "$INSTALL_DIR/scripts/install-mcp.sh" --update
    else
        bash "$INSTALL_DIR/scripts/install-mcp.sh"
    fi
fi

# 7. (Optional) whisper.cpp speech recognition server
if [[ "$WITH_WHISPER" == "true" ]]; then
    echo ""
    echo "[intel-gpu-inference] Installing whisper.cpp speech recognition server..."
    if [[ "$UPDATE" == "true" ]]; then
        bash "$INSTALL_DIR/scripts/install-whisper.sh" --update
    else
        bash "$INSTALL_DIR/scripts/install-whisper.sh"
    fi
fi
