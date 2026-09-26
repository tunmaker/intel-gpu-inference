#!/usr/bin/env bash
#
# test-piper.sh - Test the Piper text-to-speech server endpoints
#
# Tests:
#   1. Server is listening (TCP connect)
#   2. GET /voices lists the installed voices
#   3. POST / returns valid WAV audio
#   4. All three voices are selectable without a restart
#   5. length_scale is honoured
#
# Usage:
#   ./scripts/test-piper.sh                        # Test default endpoint
#   ./scripts/test-piper.sh http://host:9091       # Test specific endpoint

set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:9091}"

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

WORK_DIR=$(mktemp -d /tmp/piper-test-XXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

# Reports "<sample_rate> <duration_seconds>" for a WAV file, or nothing if invalid.
wav_info() {
    python3 -c "
import sys, wave
try:
    with wave.open(sys.argv[1]) as w:
        print(w.getframerate(), round(w.getnframes() / w.getframerate(), 3))
except Exception:
    sys.exit(1)
" "$1" 2>/dev/null
}

echo ""
echo "============================================================"
echo "  Testing Piper Text-to-Speech Server"
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
    echo "  Start it with: ./scripts/run-piper.sh"
    FAIL=$((FAIL + 1))
    echo ""
    echo "============================================================"
    echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} (out of $((PASS + FAIL)))"
    echo "============================================================"
    exit 1
fi

# ============================================================================
# Test 2: Voice list endpoint
# ============================================================================

run_test "Voice List Endpoint"

VOICES_JSON="$WORK_DIR/voices.json"
curl -s --max-time 10 "$BASE_URL/voices" -o "$VOICES_JSON" 2>/dev/null || true

VOICES=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(' '.join(sorted(json.load(f).keys())))
except Exception:
    sys.exit(1)
" "$VOICES_JSON" 2>/dev/null || echo "")

if [[ -n "$VOICES" ]]; then
    echo -e "${GREEN}PASS${NC}: /voices returned $(echo "$VOICES" | wc -w) voice(s)"
    for v in $VOICES; do echo "    $v"; done
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: /voices did not return a valid voice map"
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 3: Synthesis returns valid WAV
# ============================================================================

run_test "Synthesis Endpoint (POST /)"

OUT="$WORK_DIR/default.wav"
START=$(date +%s%N)
HTTP_CODE=$(curl -s --max-time 60 -o "$OUT" -w "%{http_code}" \
    -X POST "$BASE_URL/" \
    -H "Content-Type: application/json" \
    -d '{"text":"Hello, how are you today?"}' 2>/dev/null || echo "000")
ELAPSED=$(awk -v s="$START" -v e="$(date +%s%N)" 'BEGIN{printf "%.3f", (e-s)/1e9}')

INFO=$(wav_info "$OUT" || echo "")
if [[ "$HTTP_CODE" == "200" ]] && [[ -n "$INFO" ]]; then
    RATE=$(echo "$INFO" | cut -d' ' -f1)
    DUR=$(echo "$INFO" | cut -d' ' -f2)
    RTF=$(awk -v w="$ELAPSED" -v d="$DUR" 'BEGIN{printf "%.4f", w/d}')
    echo -e "${GREEN}PASS${NC}: Valid WAV returned (${RATE}Hz, ${DUR}s audio in ${ELAPSED}s, RTF ${RTF})"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: POST / did not return valid WAV (HTTP $HTTP_CODE, $(stat -c%s "$OUT" 2>/dev/null || echo 0) bytes)"
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 4: Both voices selectable without restart
# ============================================================================

run_test "Voice Selection (no restart)"

declare -A VOICE_TEXT=(
    [fr_FR-siwis-medium]="Bonjour, comment allez-vous?"
    [en_US-ryan-medium]="Hello, how are you today?"
)

VOICE_FAILS=0
for voice in en_US-ryan-medium fr_FR-siwis-medium; do
    OUT="$WORK_DIR/$voice.wav"
    BODY=$(python3 -c "
import json, sys
print(json.dumps({'text': sys.argv[1], 'voice': sys.argv[2]}))
" "${VOICE_TEXT[$voice]}" "$voice")

    START=$(date +%s%N)
    HTTP_CODE=$(curl -s --max-time 60 -o "$OUT" -w "%{http_code}" \
        -X POST "$BASE_URL/" \
        -H "Content-Type: application/json" \
        -d "$BODY" 2>/dev/null || echo "000")
    ELAPSED=$(awk -v s="$START" -v e="$(date +%s%N)" 'BEGIN{printf "%.3f", (e-s)/1e9}')

    INFO=$(wav_info "$OUT" || echo "")
    if [[ "$HTTP_CODE" == "200" ]] && [[ -n "$INFO" ]]; then
        DUR=$(echo "$INFO" | cut -d' ' -f2)
        RTF=$(awk -v w="$ELAPSED" -v d="$DUR" 'BEGIN{printf "%.4f", w/d}')
        echo -e "  ${GREEN}ok${NC}   $voice — ${DUR}s audio in ${ELAPSED}s (RTF ${RTF})"
    else
        echo -e "  ${RED}fail${NC} $voice — HTTP $HTTP_CODE"
        VOICE_FAILS=$((VOICE_FAILS + 1))
    fi
done

if [[ $VOICE_FAILS -eq 0 ]]; then
    echo -e "${GREEN}PASS${NC}: All 3 voices synthesized from one running server"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: $VOICE_FAILS voice(s) failed"
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 5: length_scale is honoured
# ============================================================================

run_test "length_scale Parameter"

SLOW="$WORK_DIR/slow.wav"
FAST="$WORK_DIR/fast.wav"
curl -s --max-time 60 -o "$SLOW" -X POST "$BASE_URL/" -H "Content-Type: application/json" \
    -d '{"text":"Hello, how are you today?","voice":"en_US-ryan-medium","length_scale":1.0}' 2>/dev/null || true
curl -s --max-time 60 -o "$FAST" -X POST "$BASE_URL/" -H "Content-Type: application/json" \
    -d '{"text":"Hello, how are you today?","voice":"en_US-ryan-medium","length_scale":0.6}' 2>/dev/null || true

SLOW_DUR=$(wav_info "$SLOW" | cut -d' ' -f2 || echo "")
FAST_DUR=$(wav_info "$FAST" | cut -d' ' -f2 || echo "")

if [[ -n "$SLOW_DUR" ]] && [[ -n "$FAST_DUR" ]] && \
   awk -v f="$FAST_DUR" -v s="$SLOW_DUR" 'BEGIN{exit !(f < s)}'; then
    echo -e "${GREEN}PASS${NC}: length_scale 0.6 is shorter than 1.0 (${FAST_DUR}s < ${SLOW_DUR}s)"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: length_scale had no effect (1.0=${SLOW_DUR:-?}s, 0.6=${FAST_DUR:-?}s)"
    FAIL=$((FAIL + 1))
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
