# Intel Arc GPU LLM Inference: Research Findings

*Last updated: February 2026*

## Executive Summary

Five approaches were evaluated for running local LLM inference on the Intel Arc A770 (16GB VRAM). **llama.cpp with the SYCL backend** is the recommended solution based on maturity, tool calling support, active maintenance, and practical performance.

---

## 1. llama.cpp with SYCL Backend

**Status: Active | Maturity: Moderate-High | RECOMMENDED**

### Overview
llama.cpp's SYCL backend provides native Intel GPU acceleration via oneAPI/Level Zero. It is the most battle-tested path for consumer Intel Arc GPUs.

### Pros
- **Verified on Arc A770** (release b4040+, also tested on A750, B580)
- **Full OpenAI-compatible API** via `llama-server` (`/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`)
- **Native tool/function calling** with model-specific parsers (Llama 3.x, Qwen 2.5, Mistral Nemo, Hermes, Functionary, DeepSeek R1)
- **All GGUF quantization formats** supported (Q4_0, Q4_K_M, Q5_K_M, Q8_0, etc.)
- **Full 16GB VRAM accessible** with `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1`
- Independently maintained, not dependent on archived Intel projects
- Streaming support, batch processing, embeddings, grammar-constrained output

### Cons
- **oneAPI toolkit is large** (~20GB download)
- **K-quant performance gap**: Q4_K_M runs at ~1/3 the speed of Q4_0 on Intel GPUs (legacy quants have optimized MUL_MAT kernels, K-quants do not yet)
- **iGPU conflict**: Systems with integrated + discrete GPU may need `ONEAPI_DEVICE_SELECTOR` workaround
- Maintained by volunteers, not a full Intel team
- Requires building from source with Intel compilers (icx/icpx)

### Performance (Arc A770)
| Model | Quantization | Generation Speed |
|-------|-------------|-----------------|
| Llama-2-7B | Q4_0 | ~55 tokens/sec |
| 7B models | Q4_K_M | ~16-20 tokens/sec |
| 7B models | Q8_0 | ~25-30 tokens/sec |

### Setup Complexity
Moderate. Requires oneAPI toolkit, Intel compilers, cmake build. Well-documented upstream.

---

## 2. IPEX-LLM (Intel Extension for PyTorch LLM)

**Status: ARCHIVED (Jan 28, 2026) | Maturity: Was High | NOT RECOMMENDED**

### Overview
Was Intel's flagship solution for LLM inference on Intel GPUs. Provided pre-built llama.cpp/Ollama binaries with Intel GPU acceleration, plus PyTorch-native INT4/INT8 inference.

### Pros (historical)
- Intel-backed, polished documentation
- Pre-built portable binaries (no compilation needed)
- Custom INT4/FP4 quantization with good performance (~70 t/s for Mistral 7B)
- Integrations with HuggingFace, LangChain, vLLM, Ollama

### Cons
- **Archived by Intel on January 28, 2026** - repository is read-only, no future updates
- Known slowdown bug under sustained load
- Community fork exists but lacks official backing
- Users reported difficulty replicating Intel's advertised benchmarks

### Verdict
Do not build new infrastructure on IPEX-LLM. Existing installations may continue working but will receive no updates.

---

## 3. vLLM with Intel XPU

**Status: Active (Docker-only) | Maturity: Low-Moderate for consumer Arc**

### Overview
vLLM provides excellent tool calling and OpenAI API compatibility, but Intel XPU support on consumer Arc GPUs is limited and Docker-dependent.

### Pros
- Best-in-class tool/function calling implementation
- Full OpenAI-compatible API
- Continuous batching, PagedAttention
- `intel/llm-scaler-vllm:1.2` Docker image available (Dec 2025)

### Cons
- **Docker-based only** (no practical native install for Arc)
- **No 4-bit quantization** without IPEX-LLM (FP16 only = 7B model uses ~14GB VRAM)
- Primary focus is data center GPUs (Gaudi, Max), not consumer Arc
- Kernel migration to native XPU support (vllm-xpu-kernels) is in-progress (RFC for v0.15-0.16)
- High setup complexity

### Verdict
Monitor for future native XPU support. Not practical for native Arc A770 installation today.

---

## 4. Text Generation WebUI (oobabooga)

**Status: Experimental | Maturity: Low | NOT RECOMMENDED**

### Overview
Popular LLM web UI with multiple backend options. Intel Arc support is experimental and community-driven.

### Pros
- Nice web interface for interactive use
- Multiple backend options (llama.cpp, ExLlamaV2, etc.)

### Cons
- Docker images for Intel Arc described as "blind-built and untested"
- IPEX-LLM integration path depends on archived project
- Users report significant difficulty getting GPU acceleration working
- No native tool/function calling support
- Not production-oriented

### Verdict
If you want a web UI, run llama.cpp server + Open WebUI instead.

---

## 5. Ollama with Intel GPU

**Status: Experimental | Maturity: Low-Moderate**

### Overview
Ollama has no official Intel GPU support. Two workaround paths exist: IPEX-LLM portable build (archived) and experimental Vulkan backend (v0.12.6-rc0+).

### Pros
- Simple model management (pull/run workflow)
- OpenAI-compatible API
- Vulkan support is promising for future native Intel GPU use
- Basic tool calling support

### Cons
- No official Intel GPU support in stable releases
- IPEX-LLM path depends on archived project, has known slowdown bug
- Vulkan is experimental, generally slower than SYCL on Intel hardware
- Requires building from source for Vulkan path
- Tool calling is more limited than llama.cpp or vLLM

### Verdict
Wait for Vulkan support to mature in official releases. Use llama.cpp server directly.

---

## Decision Matrix

| Criterion | llama.cpp SYCL | IPEX-LLM | vLLM XPU | WebUI | Ollama |
|-----------|:-:|:-:|:-:|:-:|:-:|
| Works on Arc A770 | ++ | +(archived) | +(Docker) | - | +/- |
| OpenAI-compatible API | ++ | + | ++ | + | + |
| **Tool/function calling** | **++** | + | **++** | -- | + |
| Quantization (4-bit GGUF) | ++ | ++ | -- | + | + |
| Native install (no Docker) | ++ | + | -- | - | - |
| Actively maintained | + | -- | + | - | +/- |
| Setup ease | + | + | -- | - | + |

**Legend:** ++ Excellent | + Good | +/- Mixed | - Poor | -- Very Poor

## Final Recommendation

**llama.cpp with SYCL backend** is the clear choice:
1. Only solution that checks all boxes (tool calling, OpenAI API, quantization, native install, active maintenance)
2. Best balance of performance, stability, and features on Arc A770
3. Use **Q4_0 quantization** for maximum speed, or **Q8_0** for best quality (both are optimized legacy quants)
4. Recommended models: Qwen2.5-7B-Instruct (best tool calling), Llama-3.1-8B-Instruct (general purpose)

## Sources

- [llama.cpp SYCL Backend Docs](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/SYCL.md)
- [Intel: Run LLMs on GPUs Using llama.cpp](https://www.intel.com/content/www/us/en/developer/articles/technical/run-llms-on-gpus-using-llama-cpp.html)
- [llama.cpp Function Calling Docs](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)
- [llama.cpp Server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [IPEX-LLM GitHub (archived)](https://github.com/intel/ipex-llm)
- [vLLM Tool Calling Docs](https://docs.vllm.ai/en/latest/features/tool_calling/)
- [Intel llm-scaler GitHub](https://github.com/intel/llm-scaler)
- [Ollama Vulkan Support](https://www.phoronix.com/news/ollama-Experimental-Vulkan)
