#!/usr/bin/env bash
#
# warmup-whisper.sh - Block until whisper-server answers a real transcription
#
# The first SYCL inference compiles its kernels, which takes ~50s on the A770.
# Run as ExecStartPost so the unit only turns active once a request is fast.

set -euo pipefail

PORT="${WHISPER_PORT:-9090}"
CLIP="$(mktemp --suffix=.wav)"
trap 'rm -f "$CLIP"' EXIT

ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=440:sample_rate=16000:duration=1" -ac 1 "$CLIP"

for _ in $(seq 1 120); do
    curl -sf "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break
    sleep 1
done

curl -sf --max-time 300 "http://127.0.0.1:${PORT}/inference" \
    -F "file=@${CLIP}" -F "response_format=json" >/dev/null
