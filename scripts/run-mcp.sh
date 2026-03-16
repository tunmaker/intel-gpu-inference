#!/usr/bin/env bash
#
# run-mcp.sh - Launch open-websearch MCP server for web search tools
#
# Usage:
#   ./scripts/run-mcp.sh                              # Run with defaults
#   DEFAULT_SEARCH_ENGINE=bing ./scripts/run-mcp.sh   # Override engine
#   PORT=4000 ./scripts/run-mcp.sh                    # Different port
#
# Endpoints:
#   SSE:             http://<host>:<port>/sse
#   streamableHttp:  http://<host>:<port>/mcp

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WEBSEARCH_DIR="$PROJECT_DIR/open-websearch"

# ============================================================================
# Load environment (XDG-compliant config)
# ============================================================================

ENV_FILE="$HOME/.config/intel-gpu-inference/env"
if [[ -f "$ENV_FILE" ]]; then
    set +eu
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set -eu
fi

# ============================================================================
# Defaults
# ============================================================================

export DEFAULT_SEARCH_ENGINE="${DEFAULT_SEARCH_ENGINE:-duckduckgo}"
export PORT="${PORT:-3000}"
export ENABLE_CORS="${ENABLE_CORS:-true}"

# ============================================================================
# Validate
# ============================================================================

if [[ ! -f "$WEBSEARCH_DIR/build/index.js" ]]; then
    echo "[ERROR] open-websearch not built. Run scripts/install-mcp.sh first."
    exit 1
fi

if ! command -v node &>/dev/null; then
    echo "[ERROR] Node.js not found. Install Node.js >= 18."
    exit 1
fi

# ============================================================================
# Launch
# ============================================================================

echo ""
echo "============================================================"
echo "  open-websearch MCP Server"
echo "============================================================"
echo ""
echo "  Engine:  $DEFAULT_SEARCH_ENGINE"
echo "  SSE:     http://0.0.0.0:${PORT}/sse"
echo "  HTTP:    http://0.0.0.0:${PORT}/mcp"
echo "  CORS:    $ENABLE_CORS"
echo ""
echo "  Press Ctrl+C to stop the server"
echo ""
echo "============================================================"
echo ""

cd "$WEBSEARCH_DIR"
exec node build/index.js
