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

Architecture inspection found 32 language layers: 24 GDN linear-attention layers and 8 full-attention layers. The required text-only rank-16 adapter contract is:

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
2. `--skip-merge` is supplied, the data matches the script-owned private-data SHA-256 `0584d6d796ad2fe0e1f551c20fb175487e13a2440effdb71bae0acd69e057bb3`, and the prompt matches script-owned SHA-256 `7ea77511b979a15df1ce28e20536b7920e47df42748d3a6e99adadaa5551bf62`.
3. Every config, tokenizer, chat-template, index, and weight-shard hash matches the script-owned contract; each Hugging Face metadata file has the pinned revision; and the index names exactly the two pinned shards.
4. Qwen3.5 resolves to BF16 LoRA, never QLoRA or full fine-tuning.
5. The actual adapter has the exact 248-module suffix distribution above, zero vision/MTP matches, and 32,464,896 trainable parameters at rank 16.
6. The Qwen response marker appears exactly once per rendered row and response-only masking leaves nonzero labels on every row.
7. CUDA BF16 support is present and the trainer completes exactly one step.

The manifest records every matched module name, target counts, trainable/total parameters, response-label counts, completed steps, timings, and peak CUDA memory. No benchmark corpus, quality score, D1 export, merged model, or release decision belongs in this lane.

## One-step execution receipt

Timestamp: 2026-07-15 13:56 EDT

Status: stopped fail-closed before training; no retry authorized

Committed trainer: `79f3c9554037868326ab33b47f9e7de8ea724d3c`. Its final named committed-diff review found no actionable defects before remote use. AlienSV then ran exactly one foreground invocation in the documented WSL exception environment: Python 3.12.3, PyTorch 2.10.0+cu128, Transformers 5.5.0, PEFT 0.19.1, TRL 0.24.0, Unsloth 2026.6.9, bitsandbytes 0.49.2, and datasets 4.3.0. CUDA and BF16 were available on the RTX 4090.

Before model load, the script verified the pinned base revision `851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a`, all seven config/tokenizer/template/index/shard hashes listed above, the exact two-shard index inventory, and the fixed private four-row SHA-256 `0584d6d796ad2fe0e1f551c20fb175487e13a2440effdb71bae0acd69e057bb3`. It separately calculated and recorded observed prompt SHA-256 `7ea77511b979a15df1ce28e20536b7920e47df42748d3a6e99adadaa5551bf62`; historical commit `79f3c955` did not enforce prompt identity.

The live Unsloth selector attached adapters to only 128 of the required 248 language modules:

| Live target family | Present | Required | Missing |
|---|---:|---:|---:|
| MLP `gate_proj`, `up_proj`, `down_proj` | 32 each | 32 each | 0 |
| full attention `q_proj`, `k_proj`, `v_proj`, `o_proj` | 8 each | 8 each | 0 |
| GDN `in_proj_a` | 0 | 24 | 24 |
| GDN `in_proj_b` | 0 | 24 | 24 |
| GDN `in_proj_qkv` | 0 | 24 | 24 |
| GDN `in_proj_z` | 0 | 24 | 24 |
| GDN `out_proj` | 0 | 24 | 24 |
| Total | 128 | 248 | 120 |

The exact target-coverage assertion stopped the process immediately after adapter attachment. It did not reach response masking, trainer construction, or `trainer.train()`. Completed optimizer steps: `0`. No adapter, checkpoint, merged model, D1 output, or quality score was created. The sanitized starting-manifest SHA-256 is `d615f2d852c9aaacf7f3d2b1e1b2b0159c6752638699dbd3de4c511c82666737`. GPU state returned to 0% utilization with 22,886 MiB free.

Decision: this is compatibility failure evidence, not model-quality evidence. Do not weaken the 248-module contract and do not retry. Any next attempt needs a separately reviewed plan that proves how GDN modules will be targeted in the installed stack, followed by fresh authorization for a new invocation.

## Post-run contract hardening

The historical receipt above is unchanged: commit `79f3c9554037868326ab33b47f9e7de8ea724d3c` ran once with the documented prompt hash and stopped at 0 optimizer steps. A later full-branch review found that the trainer recorded that prompt hash but did not yet enforce it. Beginning with commit `538342d48ee85a933f03b8fe4a5c481ef6f51eda`, the tracked future preflight contract enforces the same exact hash and rejects any mismatch before base-artifact validation or model import/load. This hardening did not trigger another GPU invocation and does not turn the historical compatibility failure into quality evidence.

A later tracked revision also atomically writes the populated adapter names, suffix counts, and parameter counts with status `adapter_validation_pending_not_complete` before enforcing target assertions. A mismatch is then atomically marked `blocked_adapter_validation_failed`. The old manifest hash above remains unchanged and did not contain these adapter diagnostics. This is future evidence hardening only; no remote retry occurred.

The future one-step contract also pins cosine scheduling with `warmup_ratio=0.0` and a positive learning rate. This prevents the only optimizer step from being consumed by a zero-learning-rate warmup. Normal Gemma and older-Qwen training remains at the historical `warmup_ratio=0.05`. The historical failed run never reached an optimizer step, so its 0-step receipt is unchanged.

Future runs atomically mark `training_in_progress_not_complete` before optimization. Training exceptions, step-count mismatches, save failures, and merge failures persist terminal non-success states with the best observed global step before re-raising. Failure receipts retain only the exception type and a SHA-256 of its message, not raw error text that could contain private training data or paths. Exact one-step completion is marked `training_complete_save_pending_not_complete` before adapter save, and compatibility becomes `complete` only after both model and tokenizer adapter saves succeed. The historical run never reached this lifecycle and remains unchanged.
