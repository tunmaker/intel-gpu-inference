#!/usr/bin/env bash
# usage: wait-for-model-load.sh <unit>:<port> [...] — blocks until each already-running service reports /health
set -uo pipefail

TIMEOUT="${MODEL_LOAD_WAIT:-300}"
deadline=$(( $(date +%s) + TIMEOUT ))

for spec in "$@"; do
    unit="${spec%%:*}"
    port="${spec##*:}"
    state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
    case "$state" in active|activating|reloading) ;; *) continue ;; esac
    echo "[wait] $unit is starting — holding model load until it is ready"
    while (( $(date +%s) < deadline )); do
        if curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:${port}/health"; then
            echo "[wait] $unit ready"
            break
        fi
        sleep 3
    done
done
exit 0
