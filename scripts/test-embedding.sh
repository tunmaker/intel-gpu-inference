#!/usr/bin/env bash
#
# test-embedding.sh - Test the llama.cpp embedding server endpoints
#
# Tests:
#   1. Server is listening (TCP connect)
#   2. /health endpoint returns OK
#   3. /v1/embeddings returns a valid vector
#
# Usage:
#   ./scripts/test-embedding.sh                        # Test default endpoint
#   ./scripts/test-embedding.sh http://host:8085       # Test specific endpoint

set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:8085}"

RED='\033[0;31m'
GREEN='\033[0;32m'
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
echo "  Testing llama.cpp Embedding Server"
echo "  Endpoint: $BASE_URL"
echo "============================================================"

# ============================================================================
# Test 1: Server is listening
# ============================================================================

run_test "Server Reachable"

HTTP_CODE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/health" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" != "000" ]]; then
    echo -e "${GREEN}PASS${NC}: Server is listening (HTTP $HTTP_CODE)"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: Server is not reachable at $BASE_URL"
    echo "  Start it with: systemctl --user start embedding-server"
    echo "         or run: ./scripts/run-embedding.sh"
    FAIL=$((FAIL + 1))
    echo ""
    echo "============================================================"
    echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} (out of $((PASS + FAIL)))"
    echo "============================================================"
    exit 1
fi

# ============================================================================
# Test 2: /health returns OK status
# ============================================================================

run_test "Health Check"

HEALTH=$(curl -s --max-time 5 "$BASE_URL/health" 2>/dev/null || echo "")

if echo "$HEALTH" | python3 -c "
import sys, json
data = json.load(sys.stdin)
status = data.get('status', '')
print(f'  Status: {status}')
sys.exit(0 if status == 'ok' else 1)
" 2>/dev/null; then
    echo -e "${GREEN}PASS${NC}: Health check returned ok"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: Health check failed or model not loaded"
    echo "  Raw: ${HEALTH:0:200}"
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 3: /v1/embeddings returns a valid vector
# ============================================================================

run_test "Embedding Endpoint"

RESPONSE=$(curl -s --max-time 30 "$BASE_URL/v1/embeddings" \
    -H "Content-Type: application/json" \
    -d '{"input": "Hello world", "model": "embedding"}' \
    2>/dev/null || echo "")

if echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
vec = data['data'][0]['embedding']
print(f'  Dimensions: {len(vec)}')
print(f'  First values: {vec[:4]}')
sys.exit(0 if len(vec) > 0 else 1)
" 2>/dev/null; then
    echo -e "${GREEN}PASS${NC}: Embedding returned valid vector"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: Embedding endpoint did not return a valid vector"
    echo "  Raw: ${RESPONSE:0:300}"
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
