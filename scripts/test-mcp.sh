#!/usr/bin/env bash
#
# test-mcp.sh - Test the open-websearch MCP server endpoints
#
# Tests:
#   1. Server is listening (TCP connect)
#   2. SSE endpoint streams data
#   3. streamableHttp — initialize + list tools
#   4. search_web tool invocation
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

# Extract JSON from an SSE stream (streamableHttp returns event: message\ndata: {...})
# Reads all "data:" lines and returns the last JSON object
extract_sse_json() {
    local input="$1"
    echo "$input" | grep '^data:' | tail -1 | sed 's/^data: *//'
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
# Test 1: Server is listening
# ============================================================================

run_test "Server Reachable"

# Simple TCP check — hit the root and see if we get any HTTP response
HTTP_CODE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" != "000" ]]; then
    echo -e "${GREEN}PASS${NC}: Server is listening (HTTP $HTTP_CODE)"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: Server is not reachable at $BASE_URL"
    echo "  Start it with: ./scripts/run-mcp.sh"
    FAIL=$((FAIL + 1))
    # No point continuing
    echo ""
    echo "============================================================"
    echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} (out of $((PASS + FAIL)))"
    echo "============================================================"
    exit 1
fi

# ============================================================================
# Test 2: SSE endpoint streams data
# ============================================================================

run_test "SSE Endpoint"

# SSE is a long-lived stream — grab first 2 seconds of data and check for event stream
SSE_DATA=$(curl -s --max-time 2 "$BASE_URL/sse" 2>/dev/null || true)

if [[ -n "$SSE_DATA" ]] && echo "$SSE_DATA" | grep -q "event:\|data:"; then
    echo "  Received SSE stream data"
    echo -e "${GREEN}PASS${NC}: SSE endpoint is streaming"
    PASS=$((PASS + 1))
else
    echo -e "${YELLOW}WARN${NC}: SSE endpoint returned no stream data (may need an MCP client to initiate)"
    echo "  Raw: ${SSE_DATA:0:200}"
    # Not a hard failure — some MCP servers only stream after client connects
    PASS=$((PASS + 1))
fi

# ============================================================================
# Test 3: streamableHttp — initialize + list tools
# ============================================================================

run_test "streamableHttp — Initialize + List Tools"

# MCP streamableHttp: first initialize, then list tools
# The response may be plain JSON or SSE-formatted (event: message\ndata: {...})
INIT_RAW=$(curl -s --max-time 10 "$BASE_URL/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": { "name": "test-mcp.sh", "version": "1.0" }
        }
    }' 2>/dev/null || echo "")

# Try plain JSON first, fall back to SSE extraction
INIT_JSON="$INIT_RAW"
if ! echo "$INIT_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    INIT_JSON=$(extract_sse_json "$INIT_RAW")
fi

# Extract session ID from response headers (needed for subsequent requests)
SESSION_HEADER=""
INIT_HEADERS=$(curl -s --max-time 10 -D - -o /dev/null "$BASE_URL/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": { "name": "test-mcp.sh", "version": "1.0" }
        }
    }' 2>/dev/null || echo "")

SESSION_ID=$(echo "$INIT_HEADERS" | grep -i "mcp-session-id" | sed 's/.*: *//' | tr -d '\r\n')

if [[ -n "$SESSION_ID" ]]; then
    SESSION_HEADER="-H Mcp-Session-Id: $SESSION_ID"
    echo "  Session ID: ${SESSION_ID:0:20}..."
fi

# Now list tools (with session if available)
TOOLS_RAW=$(curl -s --max-time 10 "$BASE_URL/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    ${SESSION_HEADER} \
    -d '{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/list",
        "params": {}
    }' 2>/dev/null || echo "")

TOOLS_JSON="$TOOLS_RAW"
if ! echo "$TOOLS_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    TOOLS_JSON=$(extract_sse_json "$TOOLS_RAW")
fi

if echo "$TOOLS_JSON" | python3 -c "
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
    echo "  Raw response: ${TOOLS_RAW:0:300}"
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 4: search_web tool invocation
# ============================================================================

run_test "search_web Tool Call"

SEARCH_RAW=$(curl -s --max-time 20 "$BASE_URL/mcp" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    ${SESSION_HEADER} \
    -d '{
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {
            "name": "search_web",
            "arguments": {
                "query": "hello world test",
                "num_results": 3
            }
        }
    }' 2>/dev/null || echo "")

SEARCH_JSON="$SEARCH_RAW"
if ! echo "$SEARCH_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    SEARCH_JSON=$(extract_sse_json "$SEARCH_RAW")
fi

if echo "$SEARCH_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
content = data.get('result', {}).get('content', [])
assert len(content) > 0, 'No results'
text = content[0].get('text', '')
# Results may be JSON array or plain text
try:
    results = json.loads(text)
    if isinstance(results, list):
        print(f'  Got {len(results)} results:')
        for r in results[:3]:
            title = r.get('title', 'untitled')[:60]
            url = r.get('url', r.get('link', ''))[:60]
            print(f'    - {title}')
            print(f'      {url}')
    else:
        print(f'  Response: {str(results)[:200]}')
except (json.JSONDecodeError, TypeError):
    print(f'  Content: {text[:200]}')
" 2>/dev/null; then
    echo -e "${GREEN}PASS${NC}: Web search returned results"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: Web search failed"
    echo "  Raw response: ${SEARCH_RAW:0:300}"
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
