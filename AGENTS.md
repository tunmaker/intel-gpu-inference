# AGENTS.md - Agent Coding Guidelines

This project provides an Intel Arc GPU inference stack using llama.cpp with SYCL backend.

## Project Overview

- **Main purpose**: Local AI inference stack on Intel Arc A770 16GB (LLM, embeddings, speech-to-text, web search)
- **Language**: Shell scripts (Bash), Python (benchmarking), C++ (llama.cpp, whisper.cpp)
- **Submodules**: `llama.cpp/`, `whisper.cpp/`, `open-websearch/`

---

## Exposed Services

These services run on the host machine and are available for external agents to consume.

### llama-server — LLM Inference (port 8080)

OpenAI-compatible API for chat completions, embeddings, and tool/function calling.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat completion (streaming supported) |
| `/v1/embeddings` | POST | Text embeddings |
| `/v1/models` | GET | List available models |
| `/health` | GET | Server health check |

```bash
# Chat completion
curl http://<host>:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"default","messages":[{"role":"user","content":"Hello"}]}'

# Streaming
curl -N http://<host>:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"default","messages":[{"role":"user","content":"Hello"}],"stream":true}'

# Tool calling
curl http://<host>:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"default","messages":[{"role":"user","content":"Search for AI news"}],"tools":[{"type":"function","function":{"name":"search","description":"Web search","parameters":{"type":"object","properties":{"query":{"type":"string"}}}}}]}'
```

### embedding-server — Dedicated Embeddings (port 8085)

OpenAI-compatible embeddings API running a separate llama.cpp instance in embedding-only mode.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/embeddings` | POST | Generate text embeddings |
| `/health` | GET | Server health check |

```bash
# Generate embeddings
curl http://<host>:8085/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"input": "Your text here", "model": "embedding"}'

# Response: {"data":[{"embedding":[0.123, ...], "index":0}], ...}

# Batch embeddings
curl http://<host>:8085/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"input": ["text one", "text two"], "model": "embedding"}'
```

### whisper-server — Speech Recognition (port 9090)

Multilingual speech-to-text. Accepts audio files (WAV, MP3, FLAC, OGG, etc.) via multipart form upload. Supports Arabic, English, French, Chinese, and 90+ languages.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/inference` | POST | Transcribe audio (multipart/form-data) |

```bash
# Transcribe audio file
curl http://<host>:9090/inference \
  -F "file=@audio.wav" \
  -F "response_format=json" \
  -F "language=auto"

# Response: {"text": "transcribed text here"}
```

**Parameters** (form fields):
- `file` — audio file (required)
- `response_format` — `json`, `text`, `srt`, `vtt`, `verbose_json` (default: `json`)
- `language` — ISO 639-1 code or `auto` (default: `auto`)
- `translate` — `true` to translate to English

### open-websearch — MCP Web Search (port 3000)

Multi-engine web search via MCP protocol. No API keys required. Usable by MCP-compatible clients.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/mcp` | POST | MCP streamableHttp (initialize, tools/list, tools/call) |
| `/mcp` | GET | MCP server-to-client notifications (SSE) |
| `/sse` | GET | Legacy SSE transport |
| `/messages` | POST | Legacy SSE message handling |

```bash
# Initialize MCP session
curl http://<host>:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"my-agent","version":"1.0"}}}'

# List tools (use Mcp-Session-Id from initialize response)
curl http://<host>:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# Search the web
curl http://<host>:3000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search","arguments":{"query":"latest AI news","limit":5}}}'
```

**MCP client config** (for Claude Desktop, Cursor, etc.):
```json
{
  "mcpServers": {
    "web-search": {
      "transport": { "type": "sse", "url": "http://<host>:3000/sse" }
    }
  }
}
```

**Available tools**: `search`, `fetchWebContent`, `fetchGithubReadme`, `fetchLinuxDoArticle`, `fetchCsdnArticle`, `fetchJuejinArticle`

### Service Summary

| Service | Port | Protocol | Status |
|---------|------|----------|--------|
| llama-server | 8080 | HTTP (OpenAI-compatible) | `systemctl --user status llama-server` |
| embedding-server | 8085 | HTTP (OpenAI-compatible) | `systemctl --user status embedding-server` |
| whisper-server | 9090 | HTTP (multipart) | `systemctl --user status whisper-server` |
| open-websearch | 3000 | HTTP (MCP/SSE) | `systemctl --user status open-websearch` |

All services bind to `0.0.0.0` by default and are accessible on the local network.

---

## Build Commands

### Full Installation (Recommended)

```bash
./scripts/install.sh
```

This installs:
1. Intel GPU compute drivers
2. Intel oneAPI toolkit
3. Builds llama.cpp with SYCL backend
4. Downloads default model

### Manual Build (llama.cpp only)

```bash
# Source oneAPI environment
source /opt/intel/oneapi/setvars.sh

# Build with SYCL backend
cd llama.cpp
cmake -B build \
    -DGGML_SYCL=ON \
    -DCMAKE_C_COMPILER=icx \
    -DCMAKE_CXX_COMPILER=icpx \
    -DCMAKE_BUILD_TYPE=Release

cmake --build build --config Release -j $(nproc)
```

### CPU-only Build (for testing)

```bash
cd llama.cpp
cmake -B build
cmake --build build --config Release
```

### Rebuild from Scratch

```bash
cd llama.cpp
rm -rf build
cmake -B build -DGGML_SYCL=ON ...
cmake --build build --config Release -j $(nproc)
```

---

## Test Commands

### API Tests

```bash
# Start server first
./scripts/run.sh

# Run API tests (in another terminal)
./scripts/test.sh
```

Test script runs:
1. Basic chat completion
2. Streaming chat completion
3. Tool/function calling
4. Tool call round-trip (multi-turn)

### Run Single Test

Edit `scripts/test.sh` or run specific curl commands:

```bash
# Basic completion
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "default", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 50}'

# Streaming
curl -s -N http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "default", "messages": [{"role": "user", "content": "Count to 5"}], "stream": true}'
```

### llama.cpp Server Unit Tests

llama.cpp has its own test suite in `llama.cpp/tools/server/tests/`. To run:

```bash
cd llama.cpp
# Requires pytest and running server
pip install pytest httpx
pytest tools/server/tests/unit/ -v
```

---

## Code Style Guidelines

### General Principles

- Avoid adding third-party dependencies
- Consider cross-platform compatibility (Linux primarily)
- Keep code simple; avoid fancy modern constructs
- Follow existing patterns in the codebase

### Shell Scripts (Bash)

Follow the conventions in existing scripts:

```bash
# Use set -euo pipefail
set -euo pipefail

# Use uppercase for constants, lowercase for variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'  # No Color

# Helper functions with prefixes
log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
```

- Use 4 spaces for indentation
- Use `[[ ]]` for conditionals (Bash builtin)
- Always quote variables: `"$VAR"` not `$VAR`
- Use `local` for function-local variables

### C/C++ (llama.cpp)

Follow llama.cpp's coding guidelines (see `llama.cpp/CONTRIBUTING.md`):

**Formatting:**
- 4 spaces for indentation
- Brackets on same line: `void foo() {`
- Vertical alignment for readability
- Use `clang-format` (v15+) on new code

**Naming:**
- `snake_case` for functions, variables, types
- `SCREAMING_SNAKE_CASE` for enum values (prefixed with enum name)
- Pattern: `<class>_<method>` with `<method>` = `<action>_<noun>`

```cpp
// Good
llama_model_init();
llama_sampler_chain_remove();
int number_small;

// Avoid
int small_number;
int big_number;
```

**Types:**
- Use sized integers: `int32_t`, `uint64_t`, etc.
- `struct foo {}` not `typedef struct foo {} foo`
- Opaque types: `typedef struct llama_context * llama_context_t`

**Pointers/References:**
- `void * ptr`
- `int & a` (reference on left)

### Python (scripts/)

Follow PEP 8 with some project conventions:

```python
#!/usr/bin/env python3
"""Module docstring."""

import os
import sys
from typing import Optional, List

# Constants
SERVER = "http://localhost:8080"

def function_name(param: str, optional_param: Optional[int] = None) -> List[str]:
    """Docstring describing function."""
    result = []
    return result
```

- Use type hints where helpful
- 4 spaces indentation
- snake_case for functions/variables
- UPPER_SNAKE_CASE for constants

### File Naming

- Shell scripts: `lowercase-with-dashes.sh`
- Python: `snake_case.py`
- C/C++ headers: `name.h`
- C source: `name.c`
- C++ source: `name.cpp`

---

## Error Handling

### Shell Scripts

```bash
# Check command success
if ! some_command; then
    log_error "Command failed"
    exit 1
fi

# Validate required files
if [[ ! -f "$MODEL_PATH" ]]; then
    echo "[ERROR] Model not found: $MODEL_PATH"
    exit 1
fi
```

### Python

```python
import sys
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def main():
    try:
        result = risky_operation()
    except ValueError as e:
        logger.error(f"Invalid value: {e}")
        sys.exit(1)
```

---

## Important Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS` | Allow >4GB VRAM | `1` |
| `ZE_FLAT_DEVICE_HIERARCHY` | Device hierarchy | `FLAT` |
| `ONEAPI_DEVICE_SELECTOR` | Select GPU device | auto |
| `LLAMA_HOST` | LLM server bind address | `0.0.0.0` |
| `LLAMA_PORT` | LLM server port | `8080` |
| `EMBEDDING_MODEL` | Embedding model path | *(required)* |
| `EMBEDDING_HOST` | Embedding server bind address | `0.0.0.0` |
| `EMBEDDING_PORT` | Embedding server port | `8085` |
| `EMBEDDING_CTX` | Embedding context size | `8192` |
| `WHISPER_MODEL` | Whisper model path | `~/models/ggml-large-v3.bin` |
| `WHISPER_HOST` | Whisper server bind address | `0.0.0.0` |
| `WHISPER_PORT` | Whisper server port | `9090` |
| `WHISPER_LANGUAGE` | Language (auto, en, ar, fr, zh) | `auto` |
| `DEFAULT_SEARCH_ENGINE` | MCP search engine | `duckduckgo` |
| `PORT` | MCP server port | `3000` |

Config file: `~/.config/intel-gpu-inference/env`

---

## Common Tasks

### Run with Different Model

```bash
./scripts/run.sh /path/to/model.gguf
```

### Override Context Size

```bash
./scripts/run.sh --ctx 4096 models/model.gguf
```

### Check SYCL Device Detection

```bash
source /opt/intel/oneapi/setvars.sh
sycl-ls
```

---

## Related Documentation

- [llama.cpp CONTRIBUTING.md](llama.cpp/CONTRIBUTING.md)
- [llama.cpp AGENTS.md](llama.cpp/AGENTS.md) - Important AI usage policy
- [llama.cpp Build Docs](llama.cpp/docs/build.md)
- [README.md](README.md) - Project overview
- [docs/models.md](docs/models.md) - Model recommendations
- [docs/research.md](docs/research.md) - Research notes
