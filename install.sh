#!/usr/bin/env bash
#
# install.sh - Top-level installer for Intel GPU inference stack
#
# Usage:
#   ./install.sh                    # Install llama-server service
#   ./install.sh --with-mcp         # Also install MCP web search server
#   ./install.sh --update              # Pull latest submodules + rebuild all
#   ./install.sh --with-whisper        # Also install whisper STT (retired; not in --all)
#   ./install.sh --with-embedding      # Also install embedding server
#   ./install.sh --with-piper          # Also install Piper text-to-speech
#   ./install.sh --with-vosk           # Also install Vosk STT (Tunisian Derja)
#   ./install.sh --all                 # Install everything (mcp + embedding + piper + vosk)
#   ./install.sh --update --all        # Update + reinstall everything

set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse flags
WITH_MCP=false
WITH_WHISPER=false
WITH_EMBEDDING=false
WITH_PIPER=false
WITH_VOSK=false
UPDATE=false
for arg in "$@"; do
    case "$arg" in
        --with-mcp)       WITH_MCP=true ;;
        --with-whisper)   WITH_WHISPER=true ;;
        --with-embedding) WITH_EMBEDDING=true ;;
        --with-piper)     WITH_PIPER=true ;;
        --with-vosk)      WITH_VOSK=true ;;
        # whisper is deliberately NOT in --all: retired in favour of vosk (9092).
        # Install it explicitly with --with-whisper if you need non-Derja languages.
        --all)            WITH_MCP=true; WITH_EMBEDDING=true; WITH_PIPER=true; WITH_VOSK=true ;;
        --update)         UPDATE=true ;;
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

# 2b. Secret-scanning pre-commit hook
if [ -d "$INSTALL_DIR/.git" ] && [ -f "$INSTALL_DIR/.githooks/pre-commit" ]; then
    chmod +x "$INSTALL_DIR/.githooks/pre-commit"
    git -C "$INSTALL_DIR" config core.hooksPath .githooks
    echo "[intel-gpu-inference] pre-commit secret scan enabled"
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

# 8. (Optional) llama.cpp embedding server
if [[ "$WITH_EMBEDDING" == "true" ]]; then
    echo ""
    echo "[intel-gpu-inference] Installing llama.cpp embedding server..."
    bash "$INSTALL_DIR/scripts/install-embedding.sh"
fi

# 9. (Optional) Piper text-to-speech server
if [[ "$WITH_PIPER" == "true" ]]; then
    echo ""
    echo "[intel-gpu-inference] Installing Piper text-to-speech server..."
    if [[ "$UPDATE" == "true" ]]; then
        bash "$INSTALL_DIR/scripts/install-piper.sh" --update
    else
        bash "$INSTALL_DIR/scripts/install-piper.sh"
    fi
fi

# 10. (Optional) Vosk speech-to-text server (Tunisian Derja)
if [[ "$WITH_VOSK" == "true" ]]; then
    echo ""
    echo "[intel-gpu-inference] Installing Vosk speech recognition server..."
    if [[ "$UPDATE" == "true" ]]; then
        bash "$INSTALL_DIR/scripts/install-vosk.sh" --update
    else
        bash "$INSTALL_DIR/scripts/install-vosk.sh"
    fi
fi
