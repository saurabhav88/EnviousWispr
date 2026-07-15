# Qwen3.5 reserve BF16 LoRA preflight — 2026-07-15

Status: compatibility experiment only. This is not model-quality evidence, does not use D1, and does not select a release model.

## Product boundary

The preferred product remains one universal offline EG-1 download. A small language-specific LoRA is only a fallback if one universal adapter cannot meet the frozen multilingual gates. Requiring users to download multiple full-size base models remains out of scope.

Qwen3.5-4B is the reserve universal-base challenger, not the current primary. The only authorized run in this lane is one optimizer step on two to four new private synthetic rows. It must not run a quality evaluation or merge weights.

## Why this is BF16 LoRA

The [official Unsloth Qwen3.5 fine-tuning guide](https://unsloth.ai/docs/models/qwen3.5/fine-tune) says:

- Qwen3.5-4B BF16 LoRA needs about 10 GB VRAM.
- Transformers v5 is required.
- Qwen3.5 is a unified language model with a vision encoder and supports text-only fine-tuning controls.
- QLoRA/4-bit training is not recommended because Qwen3.5 has higher-than-normal quantization differences.

Therefore the trainer keeps its existing Gemma and older-Qwen 4-bit QLoRA path unchanged, but refuses Qwen3.5 QLoRA. Qwen3.5 loads in 16-bit mode with full fine-tuning disabled and adapters limited to language attention and MLP modules. Vision and MTP modules are forbidden.

## Pinned base and machine evidence

The local base is the official [Qwen/Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B), pinned by its local Hugging Face cache metadata to revision `851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a`.

| Evidence | Value |
|---|---:|
| `config.json` SHA-256 | `ddc63e1c717afa86c865bb5e01313d89d72bb53b97ad4a8a03ba8510c0621670` |
| `tokenizer.json` SHA-256 | `5f9e4d4901a92b997e463c1f46055088b6cca5ca61a6522d1b9f64c4bb81cb42` |
| `tokenizer_config.json` SHA-256 | `316230d6a809701f4db5ea8f8fc862bc3a6f3229c937c174e674ff3ca0a64ac8` |
| `chat_template.jinja` SHA-256 | `a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715` |
| model index SHA-256 | `cf3f798ee02ba45f9622aa8892a47369ab667d0afbf154ee7c2212de42e6302d` |
| model shard 1 SHA-256 | `26a93f066e1916adb13453dae5a0c707c0fbc71299ed98779571a907b8e74c61` |
| model shard 2 SHA-256 | `cb544bd9bfae93dc59b0f22b292f5933573854a7f9b97835c67060d7d910e188` |
| BF16 tensor bytes | 9,319,737,856 |
| language parameters | 4,205,751,296 |
| vision parameters | 333,514,240 |
| MTP parameters | 120,599,552 |
| total parameters | 4,659,865,088 |

Architecture inspection found 32 language layers: 24 GDN linear-attention layers and 8 full-attention layers. The current Unsloth selector, with vision off and language attention/MLP on, produced this exact rank-16 target contract:

| Target family | Modules |
|---|---:|
| MLP `gate_proj`, `up_proj`, `down_proj` | 32 each |
| GDN `in_proj_a`, `in_proj_b`, `in_proj_qkv`, `in_proj_z`, `out_proj` | 24 each |
| full attention `q_proj`, `k_proj`, `v_proj`, `o_proj` | 8 each |
| Total target modules | 248 |
| Vision/MTP target modules | 0 |
| Rank-16 trainable parameters | 32,464,896 |

That adapter is expected to be roughly 124 MiB if saved as float32 PEFT safetensors, or roughly 62 MiB as a 16-bit LoRA GGUF. These are storage estimates, not measured delivery artifacts.

## Runtime decision

Native Windows CUDA is the project-primary training path because prior WSL runs had device-readiness failures. The existing native `eg1-ml-winvenv` currently has PyTorch/Transformers but not PEFT, TRL, Unsloth, bitsandbytes, or datasets. This lane will not mutate that shared environment.

The existing WSL environment has the complete current trainer stack: Python 3.12.3, PyTorch 2.10.0+cu128, Transformers 5.5.0, PEFT 0.19.1, TRL 0.24.0, Unsloth 2026.6.9, and bitsandbytes 0.49.2. It may run the single foreground compatibility step only as a documented exception after a fresh GPU/import check. Missing optional `flash-linear-attention` and `causal-conv1d` packages force Unsloth's slower Torch fallback. No result from this exception is launch-ready until the native Windows path is proven or the CTO approves WSL.

## Fail-closed one-step contract

Qwen3.5 currently refuses every launch that omits `--preflight-only`; a future full training run needs a separately reviewed change. The script owns one fixed preflight contract, so callers cannot substitute expected hashes or revisions on the command line. The preflight flag means exactly `max_steps=1` and writes `compatibility_preflight_not_quality_evidence` into the manifest. It refuses to start unless all of these are true:

1. The input contains two to four new private synthetic non-benchmark rows. Every row has only `input`, `output`, and the exact private-preflight provenance marker; unchanged benchmark/D1 schemas are rejected.
2. `--skip-merge` is supplied, and the data matches the script-owned private-data SHA-256 `0584d6d796ad2fe0e1f551c20fb175487e13a2440effdb71bae0acd69e057bb3`.
3. Every config, tokenizer, chat-template, index, and weight-shard hash matches the script-owned contract; each Hugging Face metadata file has the pinned revision; and the index names exactly the two pinned shards.
4. Qwen3.5 resolves to BF16 LoRA, never QLoRA or full fine-tuning.
5. The actual adapter has the exact 248-module suffix distribution above, zero vision/MTP matches, and 32,464,896 trainable parameters at rank 16.
6. The Qwen response marker appears exactly once per rendered row and response-only masking leaves nonzero labels on every row.
7. CUDA BF16 support is present and the trainer completes exactly one step.

The manifest records every matched module name, target counts, trainable/total parameters, response-label counts, completed steps, timings, and peak CUDA memory. No benchmark corpus, quality score, D1 export, merged model, or release decision belongs in this lane.
