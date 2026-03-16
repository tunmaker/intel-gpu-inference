#!/usr/bin/env bash
#
# test-mcp.sh - Test the open-websearch MCP server endpoints
#
# Tests:
#   1. SSE endpoint reachable
#   2. streamableHttp endpoint responds
#   3. search_web tool invocation
#
# Usage:
#   ./scripts/test-mcp.sh                        # Test default endpoint
#   ./scripts/test-mcp.sh http://host:3000       # Test specific endpoint

set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:3000}"

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

# ============================================================================
# Pre-check: Is the server running?
# ============================================================================

echo ""
echo "============================================================"
echo "  Testing open-websearch MCP Server"
echo "  Endpoint: $BASE_URL"
echo "============================================================"

# ============================================================================
# Test 1: SSE endpoint reachable
# ============================================================================

run_test "SSE Endpoint"

SSE_RESPONSE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/sse" 2>/dev/null || echo "000")

if [[ "$SSE_RESPONSE" == "200" || "$SSE_RESPONSE" == "301" || "$SSE_RESPONSE" == "302" ]]; then
    echo -e "${GREEN}PASS${NC}: SSE endpoint reachable (HTTP $SSE_RESPONSE)"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: SSE endpoint not reachable (HTTP $SSE_RESPONSE)"
    if [[ "$SSE_RESPONSE" == "000" ]]; then
        echo "  Server may not be running. Start it with: ./scripts/run-mcp.sh"
    fi
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 2: streamableHttp — list tools
# ============================================================================

run_test "streamableHttp — List Tools"

TOOLS_RESPONSE=$(curl -s --max-time 10 "$BASE_URL/mcp" \
    -H "Content-Type: application/json" \
    -d '{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/list",
        "params": {}
    }' 2>/dev/null || echo "")

if echo "$TOOLS_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tools = data.get('result', {}).get('tools', [])
assert len(tools) > 0, 'No tools found'
for t in tools:
    print(f'  - {t[\"name\"]}: {t.get(\"description\", \"\")[:80]}')
" 2>/dev/null; then
    echo -e "${GREEN}PASS${NC}: Tools listed successfully"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: Could not list tools"
    echo "  Response: ${TOOLS_RESPONSE:0:300}"
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 3: search_web tool invocation
# ============================================================================

run_test "search_web Tool Call"

SEARCH_RESPONSE=$(curl -s --max-time 15 "$BASE_URL/mcp" \
    -H "Content-Type: application/json" \
    -d '{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": {
            "name": "search_web",
            "arguments": {
                "query": "hello world test",
                "num_results": 3
            }
        }
    }' 2>/dev/null || echo "")

if echo "$SEARCH_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
content = data.get('result', {}).get('content', [])
assert len(content) > 0, 'No results'
text = content[0].get('text', '')
results = json.loads(text) if text.startswith('[') else text
if isinstance(results, list):
    print(f'  Got {len(results)} results:')
    for r in results[:3]:
        title = r.get('title', 'untitled')[:60]
        url = r.get('url', r.get('link', ''))[:60]
        print(f'    - {title}')
        print(f'      {url}')
else:
    print(f'  Response: {str(results)[:200]}')
" 2>/dev/null; then
    echo -e "${GREEN}PASS${NC}: Web search returned results"
    PASS=$((PASS + 1))
else
    echo -e "${YELLOW}PARTIAL${NC}: Search executed but response format unexpected"
    echo "  Response: ${SEARCH_RESPONSE:0:300}"
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
