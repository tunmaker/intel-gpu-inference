#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Build llama.cpp if not already built
if [ ! -x "$INSTALL_DIR/llama.cpp/build/bin/llama-server" ] &&
   [ ! -x "$INSTALL_DIR/llama.cpp/build/llama-server" ]; then
    echo "[intel-gpu-inference] llama-server not built — running scripts/install.sh first..."
    bash "$INSTALL_DIR/scripts/install.sh"
fi

# 2. XDG config
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

# 3. Service file
mkdir -p "$HOME/.config/systemd/user"
sed -e "s|__HOME__|$HOME|g" \
    -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
    "$INSTALL_DIR/llama-server.service.template" \
    > "$HOME/.config/systemd/user/llama-server.service"

# 4. Enable + start
systemctl --user daemon-reload
systemctl --user enable llama-server.service
systemctl --user start llama-server.service
echo "llama-server installed and started"
