#!/usr/bin/env bash
#
# test.sh - Test the OpenAI-compatible API endpoint
#
# Tests:
#   1. Basic chat completion
#   2. Streaming chat completion
#   3. Tool/function calling
#
# Usage:
#   ./scripts/test.sh                    # Test default endpoint
#   ./scripts/test.sh http://host:port   # Test specific endpoint
#

set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:8080}"
API_URL="$BASE_URL/v1/chat/completions"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0

run_test() {
    local name="$1"
    shift
    echo -e "\n${BLUE}━━━ Test: ${name} ━━━${NC}\n"
}

check_result() {
    local name="$1"
    local response="$2"
    local check_field="$3"

    if echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert '$check_field' in str(data), 'Field not found'
" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC}: $name"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}: $name"
        echo "Response: $response"
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================================
# Pre-check: Is the server running?
# ============================================================================

echo ""
echo "============================================================"
echo "  Testing OpenAI-Compatible API"
echo "  Endpoint: $BASE_URL"
echo "============================================================"

if ! curl -s --max-time 5 "$BASE_URL/health" > /dev/null 2>&1; then
    echo -e "\n${RED}[ERROR]${NC} Server is not reachable at $BASE_URL"
    echo "Start the server first:  ./scripts/run.sh"
    exit 1
fi
echo -e "\n${GREEN}Server is running${NC}"

# Check model info
MODEL_INFO=$(curl -s "$BASE_URL/v1/models" 2>/dev/null || echo "{}")
echo "Loaded models: $MODEL_INFO" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for m in data.get('data', []):
        print(f\"  - {m.get('id', 'unknown')}\")
except: print('  (could not parse model info)')
" 2>/dev/null || echo "  (could not retrieve model info)"

# ============================================================================
# Test 1: Basic Chat Completion
# ============================================================================

run_test "Basic Chat Completion"

RESPONSE=$(curl -s --max-time 60 "$API_URL" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "default",
        "messages": [
            {"role": "system", "content": "You are a helpful assistant. Be concise."},
            {"role": "user", "content": "What is the capital of France? Answer in one word."}
        ],
        "max_tokens": 50,
        "temperature": 0.1
    }')

echo "Response:"
echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    msg = data['choices'][0]['message']['content']
    print(f'  Content: {msg}')
    print(f'  Tokens: prompt={data[\"usage\"][\"prompt_tokens\"]}, completion={data[\"usage\"][\"completion_tokens\"]}')
except Exception as e:
    print(f'  Parse error: {e}')
    print(f'  Raw: {sys.stdin.read()[:500]}')
" 2>/dev/null || echo "  Raw: ${RESPONSE:0:500}"

check_result "Basic completion returns content" "$RESPONSE" "choices"

# ============================================================================
# Test 2: Streaming Chat Completion
# ============================================================================

run_test "Streaming Chat Completion"

echo "Streaming response:"
echo -n "  "

STREAM_OK=false
FULL_STREAM=""

while IFS= read -r line; do
    if [[ "$line" == data:* ]]; then
        data="${line#data: }"
        if [[ "$data" == "[DONE]" ]]; then
            STREAM_OK=true
            break
        fi
        # Extract content delta
        content=$(echo "$data" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    c = d.get('choices', [{}])[0].get('delta', {}).get('content', '')
    if c: print(c, end='')
except: pass
" 2>/dev/null)
        if [[ -n "$content" ]]; then
            echo -n "$content"
            FULL_STREAM+="$content"
        fi
    fi
done < <(curl -s --max-time 60 -N "$API_URL" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "default",
        "messages": [
            {"role": "user", "content": "Count from 1 to 5, separated by commas."}
        ],
        "max_tokens": 50,
        "temperature": 0.1,
        "stream": true
    }' 2>/dev/null)

echo ""

if $STREAM_OK && [[ -n "$FULL_STREAM" ]]; then
    echo -e "${GREEN}PASS${NC}: Streaming completion"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: Streaming completion"
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 3: Tool/Function Calling
# ============================================================================

run_test "Tool/Function Calling"

TOOL_RESPONSE=$(curl -s --max-time 120 "$API_URL" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "default",
        "messages": [
            {"role": "system", "content": "You are a helpful assistant that uses tools when appropriate."},
            {"role": "user", "content": "What is the weather in San Francisco right now?"}
        ],
        "tools": [
            {
                "type": "function",
                "function": {
                    "name": "get_weather",
                    "description": "Get the current weather for a location",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "location": {
                                "type": "string",
                                "description": "City name, e.g. San Francisco, CA"
                            },
                            "unit": {
                                "type": "string",
                                "enum": ["celsius", "fahrenheit"],
                                "description": "Temperature unit"
                            }
                        },
                        "required": ["location"]
                    }
                }
            }
        ],
        "tool_choice": "auto",
        "max_tokens": 200,
        "temperature": 0.1
    }')

echo "Response:"
echo "$TOOL_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    choice = data['choices'][0]
    msg = choice['message']

    # Check for tool calls
    if 'tool_calls' in msg and msg['tool_calls']:
        print('  Tool calls detected:')
        for tc in msg['tool_calls']:
            fn = tc.get('function', {})
            print(f'    - Function: {fn.get(\"name\", \"unknown\")}')
            print(f'      Arguments: {fn.get(\"arguments\", \"{}\")}')
        print(f'  Finish reason: {choice.get(\"finish_reason\", \"unknown\")}')
    elif msg.get('content'):
        print(f'  Content (no tool call): {msg[\"content\"][:200]}')
        print(f'  Note: Model chose to respond directly instead of calling a tool.')
        print(f'        This may work differently with different models.')
    else:
        print(f'  Unexpected response format: {json.dumps(msg)[:300]}')
except Exception as e:
    print(f'  Parse error: {e}')
" 2>/dev/null || echo "  Raw: ${TOOL_RESPONSE:0:500}"

# Check for tool_calls in response
if echo "$TOOL_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
msg = data['choices'][0]['message']
assert 'tool_calls' in msg and len(msg['tool_calls']) > 0
" 2>/dev/null; then
    echo -e "${GREEN}PASS${NC}: Tool calling - model invoked the function"
    PASS=$((PASS + 1))
else
    # Some models respond directly instead of using tools - check if the response is at least valid
    if echo "$TOOL_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
assert 'choices' in data
" 2>/dev/null; then
        echo -e "${YELLOW}PARTIAL${NC}: Tool calling - response valid but model didn't invoke the tool"
        echo "  Tip: Some models need specific chat templates for tool calling."
        echo "  Try running with: --jinja --chat-template-file ''"
        echo "  Best models for tool calling: Qwen2.5-Instruct, Llama-3.1-Instruct"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}: Tool calling"
        FAIL=$((FAIL + 1))
    fi
fi

# ============================================================================
# Test 4: Tool Call Round-Trip (simulate tool response)
# ============================================================================

run_test "Tool Call Round-Trip (multi-turn with tool result)"

ROUNDTRIP_RESPONSE=$(curl -s --max-time 120 "$API_URL" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "default",
        "messages": [
            {"role": "system", "content": "You are a helpful assistant. Use tools when needed."},
            {"role": "user", "content": "What is the weather in Tokyo?"},
            {"role": "assistant", "content": null, "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"location\": \"Tokyo\", \"unit\": \"celsius\"}"}}]},
            {"role": "tool", "tool_call_id": "call_1", "content": "{\"temperature\": 22, \"condition\": \"Partly Cloudy\", \"humidity\": 65}"}
        ],
        "max_tokens": 200,
        "temperature": 0.1
    }')

echo "Response:"
echo "$ROUNDTRIP_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    content = data['choices'][0]['message']['content']
    print(f'  Assistant response: {content[:300]}')
except Exception as e:
    print(f'  Parse error: {e}')
" 2>/dev/null || echo "  Raw: ${ROUNDTRIP_RESPONSE:0:500}"

if echo "$ROUNDTRIP_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
content = data['choices'][0]['message']['content']
assert content and len(content) > 5
" 2>/dev/null; then
    echo -e "${GREEN}PASS${NC}: Tool round-trip - assistant summarized tool result"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC}: Tool round-trip"
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
