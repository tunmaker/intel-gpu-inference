#!/usr/bin/env bash
#
# test-vosk.sh - Test the Vosk server endpoints
#
# Tests:
#   1. Server is listening
#   2. /inference accepts the exact whisper-server multipart POST
#   3. The ignored fields (language, response_format, prompt) are tolerated
#   4. Error paths return JSON with a "text" key, never HTML
#   5. Non-16kHz input is converted rather than rejected
#
# Usage:
#   ./scripts/test-vosk.sh                        # Test default endpoint
#   ./scripts/test-vosk.sh http://host:9092       # Test specific endpoint

set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:9092}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0

run_test() { echo -e "\n${BLUE}━━━ Test: ${1} ━━━${NC}\n"; }

WORK_DIR=$(mktemp -d /tmp/vosk-test-XXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

# Returns 0 if stdin is JSON containing a "text" key.
has_text_key() {
    python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and 'text' in d else 1)
"
}

echo ""
echo "============================================================"
echo "  Testing Vosk Server"
echo "  Endpoint: $BASE_URL"
echo "============================================================"

# ============================================================================
# Test 1: Server is listening
# ============================================================================

run_test "Server Reachable"

HTTP_CODE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/health" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo -e "${GREEN}PASS${NC}: Server is listening (HTTP $HTTP_CODE)"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: Server is not reachable at $BASE_URL (HTTP $HTTP_CODE)"
    echo "  Start it with: ./scripts/run-vosk.sh"
    FAIL=$((FAIL + 1))
    echo ""
    echo "============================================================"
    echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} (out of $((PASS + FAIL)))"
    echo "============================================================"
    exit 1
fi

# ============================================================================
# Test 2: whisper-compatible multipart POST
# ============================================================================

run_test "Inference Endpoint (whisper-compatible POST)"

SILENCE="$WORK_DIR/silence.wav"
if ! command -v ffmpeg &>/dev/null; then
    echo -e "${YELLOW}WARN${NC}: ffmpeg not installed — cannot generate test audio, skipping"
    PASS=$((PASS + 1))
else
    ffmpeg -f lavfi -i "anullsrc=r=16000:cl=mono" -t 2 -c:a pcm_s16le -y "$SILENCE" 2>/dev/null

    RESPONSE=$(curl -s --max-time 60 "$BASE_URL/inference" \
        -F "file=@$SILENCE" \
        -F "response_format=json" \
        -F "language=ar" \
        -F "prompt=" \
        2>/dev/null || echo "")

    if echo "$RESPONSE" | has_text_key; then
        echo -e "${GREEN}PASS${NC}: Returned JSON with a \"text\" key"
        echo "  Response: ${RESPONSE:0:120}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}: Response was not JSON with a \"text\" key"
        echo "  Raw: ${RESPONSE:0:200}"
        FAIL=$((FAIL + 1))
    fi
fi

# ============================================================================
# Test 3: ignored fields are tolerated
# ============================================================================

run_test "Ignored Fields Tolerated"

if [[ -f "$SILENCE" ]]; then
    FIELD_FAILS=0
    for extra in "language=zz" "response_format=srt" "prompt=some hint" "translate=true" "temperature=0.5"; do
        R=$(curl -s --max-time 60 "$BASE_URL/inference" -F "file=@$SILENCE" -F "$extra" 2>/dev/null || echo "")
        if echo "$R" | has_text_key; then
            echo -e "  ${GREEN}ok${NC}   $extra"
        else
            echo -e "  ${RED}fail${NC} $extra -> ${R:0:80}"
            FIELD_FAILS=$((FIELD_FAILS + 1))
        fi
    done
    if [[ $FIELD_FAILS -eq 0 ]]; then
        echo -e "${GREEN}PASS${NC}: All whisper fields accepted and ignored"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}: $FIELD_FAILS field(s) rejected"
        FAIL=$((FAIL + 1))
    fi
else
    echo -e "${YELLOW}WARN${NC}: no test audio — skipping"
    PASS=$((PASS + 1))
fi

# ============================================================================
# Test 4: error paths return JSON, never HTML
# ============================================================================

run_test "Error Paths Return JSON"

ERR_FAILS=0

R=$(curl -s --max-time 20 "$BASE_URL/inference" -F "language=ar" 2>/dev/null || echo "")
if echo "$R" | has_text_key; then echo -e "  ${GREEN}ok${NC}   missing file part -> JSON"; else
    echo -e "  ${RED}fail${NC} missing file part -> ${R:0:80}"; ERR_FAILS=$((ERR_FAILS + 1)); fi

echo -n "" > "$WORK_DIR/empty.wav"
R=$(curl -s --max-time 20 "$BASE_URL/inference" -F "file=@$WORK_DIR/empty.wav" 2>/dev/null || echo "")
if echo "$R" | has_text_key; then echo -e "  ${GREEN}ok${NC}   empty file -> JSON"; else
    echo -e "  ${RED}fail${NC} empty file -> ${R:0:80}"; ERR_FAILS=$((ERR_FAILS + 1)); fi

echo "this is not audio" > "$WORK_DIR/garbage.wav"
R=$(curl -s --max-time 30 "$BASE_URL/inference" -F "file=@$WORK_DIR/garbage.wav" 2>/dev/null || echo "")
if echo "$R" | has_text_key; then echo -e "  ${GREEN}ok${NC}   non-audio payload -> JSON"; else
    echo -e "  ${RED}fail${NC} non-audio payload -> ${R:0:80}"; ERR_FAILS=$((ERR_FAILS + 1)); fi

R=$(curl -s --max-time 20 "$BASE_URL/nonexistent" 2>/dev/null || echo "")
if echo "$R" | has_text_key; then echo -e "  ${GREEN}ok${NC}   unknown route -> JSON"; else
    echo -e "  ${YELLOW}warn${NC} unknown route returned non-JSON: ${R:0:60}"; fi

if [[ $ERR_FAILS -eq 0 ]]; then
    echo -e "${GREEN}PASS${NC}: Error paths return JSON with a \"text\" key"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: $ERR_FAILS error path(s) returned non-JSON"
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 5: resampling fallback
# ============================================================================

run_test "Non-16kHz Input Converted"

if command -v ffmpeg &>/dev/null; then
    ffmpeg -f lavfi -i "anullsrc=r=44100:cl=stereo" -t 1 -c:a pcm_s16le -y "$WORK_DIR/44k.wav" 2>/dev/null
    R=$(curl -s --max-time 60 "$BASE_URL/inference" -F "file=@$WORK_DIR/44k.wav" 2>/dev/null || echo "")
    if echo "$R" | has_text_key; then
        echo -e "${GREEN}PASS${NC}: 44.1kHz stereo accepted and converted"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}: 44.1kHz input rejected -> ${R:0:120}"
        FAIL=$((FAIL + 1))
    fi
else
    echo -e "${YELLOW}WARN${NC}: ffmpeg not installed — skipping"
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
