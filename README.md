# Intel Arc A770 LLM Inference Stack

Local LLM inference on **Intel Arc A770 16GB** using **llama.cpp with SYCL backend**.

- OpenAI-compatible API (`/v1/chat/completions`, `/v1/embeddings`)
- Native tool/function calling for agentic workflows
- MCP web search server (optional, no API keys)
- SYCL flash attention + fused Gated Delta Net for Qwen3.5
- Runs as systemd user services with auto-restart

## Prerequisites

- **GPU**: Intel Arc A770 16GB (also works on A750, B580)
- **OS**: Ubuntu 22.04/24.04 or Debian 12
- **Kernel**: 6.2+
- **Disk**: ~30GB free (oneAPI + llama.cpp + model)

## Deploy

```bash
git clone <repo-url> ~/intel-gpu-inference
cd ~/intel-gpu-inference
git submodule update --init --recursive

# Install everything (drivers, oneAPI, llama.cpp build, systemd service)
./scripts/install.sh

# Or with MCP web search
./install.sh --with-mcp
```

`install.sh` handles Intel GPU drivers, oneAPI toolkit, llama.cpp SYCL build, environment config, and systemd service setup. Log out and back in if prompted for group changes.

## Models

We use [Unsloth](https://unsloth.ai) GGUF quantizations — they work great with llama.cpp thanks to Dynamic 2.0 quants that upcast important layers.

Prefer **Q8_0** when the model fits in VRAM, fall back to **Q4_0** for larger models. Legacy quants (Q4_0, Q8_0) are significantly faster than K-quants on Intel GPUs due to optimized SYCL MUL_MAT kernels.

## Default Paths

| Path | Description |
|------|-------------|
| `~/models/` | GGUF model files |
| `~/intel-gpu-inference/llama.cpp/` | llama.cpp source and SYCL build |
| `~/intel-gpu-inference/open-websearch/` | MCP web search server (if installed) |
| `~/.config/intel-gpu-inference/env` | Environment config (all services) |
| `~/.config/systemd/user/` | Installed systemd unit files |

## Services

### llama-server — LLM Inference

OpenAI-compatible API serving GGUF models on the Intel Arc GPU.

```bash
# Manual
./scripts/run.sh                          # default model from env config
./scripts/run.sh /path/to/model.gguf      # specific model
./scripts/run.sh --ctx 4096               # override context size

# systemd
systemctl --user status llama-server
systemctl --user restart llama-server
journalctl --user -u llama-server -f
```

**API**: `http://<host>:8080/v1`
**Test**: `./scripts/test.sh`

### open-websearch — MCP Web Search (Optional)

Multi-engine web search via [MCP protocol](https://modelcontextprotocol.io). No API keys required. Supports DuckDuckGo, Bing, Brave, and others.

```bash
# Install
./scripts/install-mcp.sh

# Manual
./scripts/run-mcp.sh

# systemd
systemctl --user status open-websearch
systemctl --user restart open-websearch
journalctl --user -u open-websearch -f
```

**Endpoints**: `http://<host>:3000/sse` (SSE) | `http://<host>:3000/mcp` (streamableHttp)
**Test**: `./scripts/test-mcp.sh`

**MCP client config:**
```json
{
  "mcpServers": {
    "web-search": {
      "transport": { "type": "sse", "url": "http://<host>:3000/sse" }
    }
  }
}
```

**Tools**: `search_web`, `fetchArticle`, `fetchGithubReadme`

## Configuration

All services read from `~/.config/intel-gpu-inference/env`. Edit and restart the relevant service.

| Variable | Default | Description |
|----------|---------|-------------|
| `DEFAULT_MODEL` | `~/models/Qwen3VL-8B-Instruct-Q8_0.gguf` | Active model path |
| `MMPROJ_PATH` | `~/models/mmproj-Qwen3VL-8B-Instruct-F16.gguf` | Vision projector (blank to disable) |
| `LLAMA_HOST` | `0.0.0.0` | Server bind address |
| `LLAMA_PORT` | `8080` | Server port |
| `DEFAULT_SEARCH_ENGINE` | `duckduckgo` | MCP search engine |
| `PORT` | `3000` | MCP server port |
| `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS` | `1` | Allow >4GB VRAM allocations |
| `ONEAPI_DEVICE_SELECTOR` | auto | GPU selection (set if iGPU conflict) |

## Directory Structure

```
intel-gpu-inference/
├── install.sh                        # Top-level installer (service + optional MCP)
├── llama-server.service.template     # systemd unit template
├── open-websearch.service.template   # systemd unit template (MCP)
├── scripts/
│   ├── install.sh                    # Full build installer (drivers, oneAPI, llama.cpp)
│   ├── install-mcp.sh               # MCP web search installer
│   ├── run.sh                        # llama-server launcher
│   ├── run-mcp.sh                    # MCP web search launcher
│   ├── test.sh                       # LLM API test suite
│   └── test-mcp.sh                   # MCP server test suite
├── configs/
│   ├── llama-server.env.template     # Environment template
│   └── open-websearch.env.template   # MCP environment template
├── docs/
│   ├── research.md                   # Evaluation of Intel GPU inference options
│   └── models.md                     # Model recommendations for 16GB VRAM
├── llama.cpp/                        # Submodule: source and SYCL build
└── open-websearch/                   # Submodule: MCP web search server
```

## Links

### llama.cpp
- [SYCL Backend (Linux)](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/SYCL.md#linux)
- [Server API Reference](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [Function Calling](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)

### Intel
- [GPU Drivers (Ubuntu 22.04)](https://dgpu-docs.intel.com/driver/client/overview.html#ubuntu-22-04)
- [GPU Drivers (Ubuntu 24.04+)](https://dgpu-docs.intel.com/driver/client/overview.html#ubuntu-latest)
- [oneAPI Base Toolkit](https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit-download.html)

### Models
- [Unsloth GGUF Models](https://unsloth.ai/docs/models)
- [Unsloth Dynamic 2.0 Quants](https://unsloth.ai/blog/dynamic-4bit)
- [docs/models.md](docs/models.md) — VRAM-tested recommendations for Arc A770

### MCP
- [Model Context Protocol](https://modelcontextprotocol.io)
- [open-websearch](https://github.com/Aas-ee/open-webSearch) — Multi-engine search MCP server
