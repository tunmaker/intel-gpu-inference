# Recommended Models for Intel Arc A770 16GB

*Optimized for llama.cpp with SYCL backend*

## Important Notes on Quantization for Intel GPUs

**Legacy quants (Q4_0, Q5_0, Q8_0) are FASTER than K-quants (Q4_K_M, Q5_K_M) on Intel GPUs.**
This is because legacy quants have optimized MUL_MAT SYCL kernels, while K-quants do not yet.

- **Q4_0**: Best speed, acceptable quality (~55 t/s for 7B)
- **Q8_0**: Best quality among fast quants (~25-30 t/s for 7B)
- **Q4_K_M**: Better quality than Q4_0 but ~3x slower on Intel (~16-20 t/s for 7B)

**Recommendation**: Use Q8_0 when it fits in VRAM (best quality with optimized kernels), fall back to Q4_0 for larger models.

---

## VRAM Budget Guidelines

With 16GB VRAM, approximate model size limits:

| Model Parameters | Q4_0 Size | Q8_0 Size | Fits in 16GB? | Context Budget |
|:---:|:---:|:---:|:---:|:---:|
| 3B | ~1.8 GB | ~3.4 GB | Yes (Q8_0) | 16K-32K+ |
| 7B-8B | ~4.0 GB | ~7.5 GB | Yes (Q8_0) | 8K-16K |
| 14B | ~8.0 GB | ~14.5 GB | Q4_0 yes, Q8_0 tight | 4K-8K |
| 22B-24B | ~12.5 GB | ~22 GB | Q4_0 only | 2K-4K |
| 32B | ~17 GB | ~32 GB | No | -- |

*VRAM usage = model weights + KV cache (context) + overhead. Leave ~2-3 GB for KV cache and runtime overhead.*

---

## Tier 1: Best for 16GB (7B-8B models at Q8_0)

These models fit comfortably at Q8_0 with room for 8K+ context.

### Qwen2.5-7B-Instruct (RECOMMENDED DEFAULT)
- **Why**: Best-in-class tool/function calling for its size. Excellent at structured output, code, and reasoning.
- **GGUF source**: `Qwen/Qwen2.5-7B-Instruct-GGUF` or community quants on HuggingFace
- **Recommended quant**: Q8_0 (~7.5 GB) for quality, Q4_0 (~4.0 GB) for speed
- **Context**: 8192 tokens at Q8_0, up to 32K at Q4_0
- **Tool calling**: Native support via `--jinja` flag and Hermes/Qwen2.5 parser
- **Best for**: Tool calling, coding, structured output, general chat

### Llama-3.1-8B-Instruct
- **Why**: Strong general-purpose model with good instruction following. Well-tested with llama.cpp tool calling.
- **GGUF source**: `bartowski/Meta-Llama-3.1-8B-Instruct-GGUF` or official Meta quants
- **Recommended quant**: Q8_0 (~8.0 GB), Q4_0 (~4.5 GB)
- **Context**: 8192 tokens at Q8_0
- **Tool calling**: Native Llama 3.x parser in llama-server
- **Best for**: General chat, instruction following, balanced performance

### Mistral-7B-Instruct-v0.3
- **Why**: Fast, efficient, good at following instructions. Proven tool calling support.
- **GGUF source**: `MistralAI/Mistral-7B-Instruct-v0.3-GGUF` or community quants
- **Recommended quant**: Q8_0 (~7.5 GB), Q4_0 (~4.0 GB)
- **Context**: 8192 tokens at Q8_0
- **Tool calling**: Native Mistral Nemo parser
- **Best for**: Fast responses, chat, tool calling

### Phi-3.5-mini-instruct (3.8B)
- **Why**: Surprisingly capable for its size. Fits at Q8_0 with tons of context headroom.
- **GGUF source**: `bartowski/Phi-3.5-mini-instruct-GGUF`
- **Recommended quant**: Q8_0 (~4.0 GB) - room for 16K-32K context
- **Context**: Up to 32K tokens
- **Best for**: Fast iteration, long context, resource-light tasks

---

## Tier 2: Larger Models (14B at Q4_0)

Fit at Q4_0 with limited context. Higher quality reasoning at the cost of speed and context length.

### Qwen2.5-14B-Instruct
- **Why**: Significant quality jump over 7B for reasoning and coding tasks. Excellent tool calling.
- **GGUF source**: `Qwen/Qwen2.5-14B-Instruct-GGUF` or community quants
- **Recommended quant**: Q4_0 (~8.0 GB), leaves ~8 GB for context
- **Context**: 4096-8192 tokens
- **Tool calling**: Yes, via Hermes/Qwen parser
- **Best for**: Complex reasoning, coding, when quality > speed

### Mistral-Nemo-Instruct-2407 (12B)
- **Why**: Strong multilingual support, good instruction following, well-tested tool calling.
- **GGUF source**: `bartowski/Mistral-Nemo-Instruct-2407-GGUF`
- **Recommended quant**: Q4_0 (~7.0 GB)
- **Context**: 4096-8192 tokens
- **Tool calling**: Yes, native Mistral Nemo parser
- **Best for**: Multilingual tasks, chat, tool calling

---

## Tier 3: Maximum Model Size (20B-24B at Q4_0)

These push VRAM limits. Expect limited context and slower performance.

### DeepSeek-R1-Distill-Qwen-14B
- **Why**: Strong reasoning capabilities from R1 distillation. Good at chain-of-thought.
- **GGUF source**: `bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF`
- **Recommended quant**: Q4_0 (~8.0 GB)
- **Context**: 4096 tokens
- **Tool calling**: Via DeepSeek R1 parser
- **Best for**: Complex reasoning, math, analysis

### Codestral-22B (Mistral)
- **Why**: Dedicated coding model, excellent for code generation and analysis.
- **GGUF source**: `bartowski/Codestral-22B-v0.1-GGUF`
- **Recommended quant**: Q4_0 (~12.5 GB) - tight fit, 2K-4K context
- **Context**: 2048-4096 tokens
- **Best for**: Code generation (if coding is primary use case)

---

## Model Selection by Use Case

| Use Case | Primary Pick | Alternative |
|----------|-------------|-------------|
| **Tool/Function Calling** | Qwen2.5-7B-Instruct Q8_0 | Llama-3.1-8B-Instruct Q8_0 |
| **General Chat** | Llama-3.1-8B-Instruct Q8_0 | Mistral-7B-Instruct-v0.3 Q8_0 |
| **Coding** | Qwen2.5-14B-Instruct Q4_0 | Qwen2.5-7B-Instruct Q8_0 |
| **Reasoning/Analysis** | DeepSeek-R1-Distill-Qwen-14B Q4_0 | Qwen2.5-14B-Instruct Q4_0 |
| **Long Context** | Phi-3.5-mini-instruct Q8_0 | Qwen2.5-7B-Instruct Q4_0 |
| **Speed** | Phi-3.5-mini-instruct Q4_0 | Mistral-7B-Instruct-v0.3 Q4_0 |
| **Max Quality (7B class)** | Qwen2.5-7B-Instruct Q8_0 | Llama-3.1-8B-Instruct Q8_0 |

---

## How to Download Models

```bash
# Install huggingface-cli if not present
pip install huggingface-hub

# Download a specific GGUF file
huggingface-cli download Qwen/Qwen2.5-7B-Instruct-GGUF \
    qwen2.5-7b-instruct-q8_0.gguf \
    --local-dir ~/intel-gpu-inference/models

# Or download from bartowski (often has more quant options)
huggingface-cli download bartowski/Meta-Llama-3.1-8B-Instruct-GGUF \
    Meta-Llama-3.1-8B-Instruct-Q8_0.gguf \
    --local-dir ~/intel-gpu-inference/models
```

## Performance Expectations Summary

| Model | Quant | VRAM | Speed (est.) | Context |
|-------|-------|------|-------------|---------|
| Phi-3.5-mini (3.8B) | Q8_0 | ~4 GB | 70-90 t/s | 32K |
| Qwen2.5-7B | Q4_0 | ~4 GB | 50-55 t/s | 16K+ |
| Qwen2.5-7B | Q8_0 | ~7.5 GB | 25-30 t/s | 8K |
| Llama-3.1-8B | Q8_0 | ~8 GB | 25-30 t/s | 8K |
| Qwen2.5-14B | Q4_0 | ~8 GB | 20-25 t/s | 4-8K |
| Codestral-22B | Q4_0 | ~12.5 GB | 10-15 t/s | 2-4K |

*Speeds are estimates for Intel Arc A770 with SYCL backend. Actual performance varies by prompt length, batch size, and system configuration.*
