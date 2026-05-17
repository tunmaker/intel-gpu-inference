#!/usr/bin/env bash
#
# run-embedding-2.sh - Second bge-m3 embedding server instance on port 8086.
# Shares the same model/config as run-embedding.sh; intended to run alongside
# it for added parallelism. Each process loads its own copy of the model into
# GPU memory.
#
# Usage:
#   ./scripts/run-embedding-2.sh                    # defaults, port 8086
#   EMBEDDING_PORT_2=9000 ./scripts/run-embedding-2.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export EMBEDDING_PORT="${EMBEDDING_PORT_2:-8086}"

exec "$SCRIPT_DIR/run-embedding.sh" "$@"
