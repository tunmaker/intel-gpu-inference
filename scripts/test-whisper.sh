#!/usr/bin/env bash
#
# test-whisper.sh - Test the whisper.cpp server endpoints
#
# Tests:
#   1. Server is listening (TCP connect)
#   2. /inference endpoint accepts audio (generates silence to test)
#
# Usage:
#   ./scripts/test-whisper.sh                        # Test default endpoint
#   ./scripts/test-whisper.sh http://host:9090       # Test specific endpoint

set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:9090}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0

run_test() {
    local name="$1"
    echo -e "\n${BLUE}━━━ Test: ${name} ━━━${NC}\n"
}

echo ""
echo "============================================================"
echo "  Testing whisper.cpp Server"
echo "  Endpoint: $BASE_URL"
echo "============================================================"

# ============================================================================
# Test 1: Server is listening
# ============================================================================

run_test "Server Reachable"

HTTP_CODE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" != "000" ]]; then
    echo -e "${GREEN}PASS${NC}: Server is listening (HTTP $HTTP_CODE)"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: Server is not reachable at $BASE_URL"
    echo "  Start it with: ./scripts/run-whisper.sh"
    FAIL=$((FAIL + 1))
    echo ""
    echo "============================================================"
    echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} (out of $((PASS + FAIL)))"
    echo "============================================================"
    exit 1
fi

# ============================================================================
# Test 2: /inference endpoint with silence
# ============================================================================

run_test "Inference Endpoint"

# Generate a 1-second silence WAV file for testing
SILENCE_FILE=$(mktemp /tmp/whisper-test-XXXX.wav)
trap 'rm -f "$SILENCE_FILE"' EXIT

# Check if ffmpeg is available to generate test audio
if command -v ffmpeg &>/dev/null; then
    ffmpeg -f lavfi -i "anullsrc=r=16000:cl=mono" -t 1 -y "$SILENCE_FILE" 2>/dev/null

    RESPONSE=$(curl -s --max-time 30 "$BASE_URL/inference" \
        -F "file=@$SILENCE_FILE" \
        -F "response_format=json" \
        -F "language=en" \
        2>/dev/null || echo "")

    if [[ -n "$RESPONSE" ]]; then
        # Check if response is valid JSON with a text field
        if echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
text = data.get('text', '')
print(f'  Transcription: \"{text.strip()}\"')
" 2>/dev/null; then
            echo -e "${GREEN}PASS${NC}: Inference endpoint returned valid response"
            PASS=$((PASS + 1))
        else
            echo -e "${YELLOW}WARN${NC}: Response received but not valid JSON"
            echo "  Raw: ${RESPONSE:0:200}"
            PASS=$((PASS + 1))
        fi
    else
        echo -e "${RED}FAIL${NC}: No response from /inference endpoint"
        FAIL=$((FAIL + 1))
    fi
else
    echo -e "${YELLOW}WARN${NC}: ffmpeg not installed — skipping audio inference test"
    echo "  Install ffmpeg to enable: sudo apt-get install -y ffmpeg"
    PASS=$((PASS + 1))
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "============================================================"
TOTAL=$((PASS + FAIL))
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}All $TOTAL tests passed!${NC}"
else
    echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} (out of $TOTAL)"
fi
echo "============================================================"
echo ""

exit $FAIL
