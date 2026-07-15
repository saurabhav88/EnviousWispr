<!-- tier: 2 -->
# EG-1 Model Provenance (how the model was MADE)

When to load: any question about how EG-1 was trained — "is it a full fine-tune or a LoRA," base model, training method/config, training data, per-language coverage, "did we build our own model from scratch," or how to build EG-2/EG-3 (retrain recipe). This is the "how it was made" record; [`eg1-operations.md`](eg1-operations.md) is the "how it runs / how it ships" record (hosting, runtime flags, unload matrix, licensing). Do not duplicate — cross-link.

Source of record: GitHub issue **#1265** (closed, founder-approved 2026-07-02) — its "Method of record" + results comments are authoritative; research + citations in `docs/competitive-analysis/2026-07-02-tune-base-model-vs-fluid1.md`. Training data lives (gitignored, Docs/dev-tooling lane) in `scripts/eval/runs/bakeoff-1265/train_sft_v{1,2}.jsonl`. Epic: **#1190**. Wiring into the app: **#1269 / #1271**.

## FACT: eg1-headline-what-it-is
| Question | Answer |
|---|---|
| Full fine-tune or LoRA? | **QLoRA** (LoRA on the 4-bit-quantized base) — NOT a full-parameter retrain. |
| Adapter shipped separately? | **No.** The LoRA adapter is **merged back into the base weights**, then converted and quantized; there is no runtime "base + adapter." Physical packaging + the current shard identity are owned by [`eg1-operations.md`](eg1-operations.md) FACT: eg1-artifact-identity (EG-1 ships as 8 componentSet GGUF shards, #1417 — not one file). |
| Base model | **Qwen3-4B-Instruct-2507** (Alibaba, Apache-2.0, the non-thinking variant). |
| Built from scratch? | No. It is a fine-tuned **derivative** of Qwen3-4B — this is why the README says "fine-tuned derivative of Qwen3-4B-Instruct-2507 (Apache-2.0)" and the EG-1 license applies to the *fine-tuned weights*, not the base. |
| Plain-English framing for Saurabh | "We took Alibaba's Qwen 4B, taught it our dictation-cleanup behavior with a QLoRA fine-tune, and baked the result into one custom model. It's ours, but it stands on an open base." |

The one-line honest positioning: **"a QLoRA fine-tune of Qwen3-4B, merged and quantized."** Do NOT claim "full fine-tune" (false — it's LoRA) and do NOT claim "trained our own model from scratch" (false — Qwen3-4B is the base).

## FACT: eg1-training-config
Settled by council + Codex (#1265), trained on the RTX 4090:
| Knob | Value |
|---|---|
| Method | QLoRA via **Unsloth** (CUDA-only; does not run on Apple Silicon) |
| LoRA rank / alpha | **r16 / a32** |
| Learning rate | **5e-5** (dropped from the research doc's 2e-4 starting point) |
| Epochs | **2** |
| Loss | **response-only** (loss on the cleaned output, not the transcript/prompt) |
| Target modules | all attention + MLP projections |
| Precision | bf16, adamw_8bit, gradient checkpointing |
| Rig | **AlienSV RTX 4090** (24 GB, WSL2 Ubuntu), always-on via Tailscale. **$0 spend** — owned hardware, no cloud GPU. |
| Division of labor | TRAIN on the PC, EVAL on the Mac (llama.cpp/Ollama + judge harness), ship the merged GGUF back over Tailscale. |

Rig details: `~/.claude/knowledge/infra/aliensv-pc.md`.

## FACT: eg1-build-pipeline
The end-to-end pipeline (mirror of Fluid-1's exact approach — competitor-proven):
```
QLoRA train (4090)  →  merge adapter into base  →  GGUF convert  →  Q5_K_M quantize  →  judge the QUANTIZED artifact
```
- **Judge the quantized artifact, never the fp16 checkpoint.** The shipped quality number must be measured on exactly the GGUF users run. (Q5_K_M was chosen over Q4_K_M: Q4 scored 86.5% vs Q5 88.8% on the hard-340 at bake-off; the feared Qwen-Q4 collapse did not materialize, but Q5's ~2pp edge + fewer criticals won.)
- Shipped quant: **Q5_K_M, ~2.7–2.9 GB total**. Current sharded artifact identity + exact per-shard SHAs: [`eg1-operations.md`](eg1-operations.md) FACT: eg1-artifact-identity.

## FACT: eg1-training-data
Two data generations; **v2 is what shipped** (`train_sft_v2.jsonl`, **5,656 pairs**). Format is flat `{id, source, input(raw) → output(cleaned)}` JSONL.
- **v1 (3,036 pairs):** SFT built from 1,549 Type-B-approved rows after excluding the hard-340 IDs/texts, plus founder dictations. The exclusion protected the hard-340 exact cases, not the full 1,890 working set. The 900-case overflow set stayed exact-text sealed but was derived from the same provenance families.
- **v2 = v1 + 1,924 teacher-distilled real dictations** (teacher = gemini-2.5-flash + the v6 cloud prompt; hallucination-filtered, noop-capped) **+ 696 targeted convention drills.**
- **Leakage correction (2026-07-15):** shipping v2 has exact ID and normalized-input overlap with **1,549/1,890** full Type B rows; conservative normalization finds 1,551. Provenance-family components expose 1,866/1,890 approved rows and 899/900 overflow rows. The old zero-overlap statement conflated the protected hard-340/exact-overflow checks with the broader working set. The old 1,890 and overflow scores are historical development/robustness evidence, not held-out quality estimates. Owner receipt: `docs/experiments/eg1-multilingual/OVERNIGHT-LOG-2026-07-15.md` TYPE-B-001.
- **Prompt = training contract:** the model was trained AND ships with ONE fixed short system prompt + `<TRANSCRIPT>…</TRANSCRIPT>` wrapper (`scripts/eval/prompts/eg1-polish-prompt-v1.txt`, pinned by a golden-string test in `EGOnePromptBuilder`). Training prompt MUST equal inference prompt — prompt-shape drift cost ±18pp on the untuned base. This is why EG-1 gets its own `.egOneFixed` prompt family and ignores per-mode prompt rules (behavior is in the weights).

## FACT: eg1-quality-and-bias-gate
Judge: sonnet-5 `behavior_judge.py --system new`. (Numbers here are the #1265 acceptance run; note the separate marketing-vs-settings discrepancy tracked in `eg1-operations.md` FACT: eg1-quality-perf-baselines — 94.4/94.7 internal vs 93.7 public, same model, different run.)
- **Hard-340 subset:** 94.7%, **0 critical fails** (beat the gpt-4o + v6 cloud champion same-batch: 93.5%, 2 crit).
- **Full 1,890:** 94.4% (traps 97.3%, false-positive 2.4%).
- **Historical one-time bias gate:** exact-text-sealed 900-overflow scored 88.0% vs untuned-base anchor 61.2%; Type-C mixed slice 94.5%; 100 train-excluded real dictations ~95%. This does not prove held-out generalization because the 2026-07-15 provenance audit found 899/900 overflow rows in training-exposed Type B families.

## FACT: eg1-language-coverage-provenance
- **Trained overwhelmingly on English.** The v2 corpus is English-oriented `raw → cleaned` dictation data, but it is not literally ASCII-only. The historical quality numbers above are English.
- **Base is multilingual** (Qwen3-4B handles ~100+ languages) and the fixed prompt says "keep the same language … never translate," so EG-1 will *accept* and attempt to polish non-English — but that rides on base-model ability, un-benchmarked per-language. Lower-resourced languages will be rougher.
- **Multilingual training pairs are an explicit v3 lever** (epic #1190 follow-ups), not shipped in EG-1 v1/v2.
- Do not conflate with transcription: the ASR engines (Parakeet = English + 24 European; WhisperKit = 99) are a separate stage feeding EG-1 (`architecture.md`).

## RULE: eg1-retrain-recipe-for-eg2
Rule: To build EG-2 (or EG-1 v3), reuse this exact pipeline — QLoRA (Unsloth, 4090) → merge → GGUF → quantize → judge the quantized artifact against the SEALED holdout — and keep the training prompt byte-identical to the shipped prompt. A PROMPT change means a new `promptTemplateID` + new `PromptFamily` case (see `eg1-operations.md` RULE: eg1-hot-swap-contract); a weights-only update keeps the template id.
Why: prompt-shape drift alone swings quality ±18pp; judging fp16 instead of the quantized GGUF ships a number users never see.
How to apply: expand data on the v2 recipe (synthetic + teacher-distilled real dictations + targeted drills), preserve zero-overlap with the eval, re-run the one-time bias gate on any new data generation, and route any prompt-family change through a code-lane PR. Distribution (R2 upload, manifest bump) is `eg1-operations.md`.
Ref: #1265 method-of-record; #1190 epic.

## FACT: eg1-provenance-sources
| Want | Where |
|---|---|
| Method of record (final config, data recipe, results) | GitHub issue **#1265** comments (closed) |
| Base-model choice + QLoRA rationale + Fluid-1 teardown | `docs/competitive-analysis/2026-07-02-tune-base-model-vs-fluid1.md` |
| Bake-off scores (2 models × 3 prompts, quant rungs) | `scripts/eval/runs/bakeoff-1265/BASELINE_TABLE.md` |
| Training data (gitignored) | `scripts/eval/runs/bakeoff-1265/train_sft_v{1,2}.jsonl` |
| Shipped prompt (golden) | `scripts/eval/prompts/eg1-polish-prompt-v1.txt` → `EGOnePromptBuilder.systemPrompt` |
| Runtime / hosting / license / perf | [`eg1-operations.md`](eg1-operations.md) |
| The earlier, DEAD Apple-adapter LoRA PoC (different model) | [`afm-adapter-poc.md`](afm-adapter-poc.md) — do NOT confuse with EG-1 |
