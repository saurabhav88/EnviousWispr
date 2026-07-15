# EG-1 multilingual overnight lab log

Date: 2026-07-15 (America/New_York)

Operator: Codex

Tracker: GitHub issue #1364

Branch: `codex/eg1-multilingual-overnight`

## Objective

Find the real limits of EG-1 for lists and international languages, then test the smallest reliable improvement path in this order:

1. Stronger evaluation and held-out benchmarks.
2. Prompt-only changes.
3. Balanced multilingual QLoRA training if prompt-only work is insufficient.
4. A different or language-specific base only if the untouched Qwen base is itself weak.
5. Exact shipped-runtime validation on the Mac before making a product claim.

Target initial languages: English, German, French, Russian, plus a fifth language chosen from product relevance and measured base-model strength. Chinese remains a useful control because Qwen is expected to be strong there, but support will not be claimed without direct results.

## Non-negotiable experiment rules

- Keep development data, training data, and frozen release data separate.
- Group paraphrases and templates before splitting so near-duplicates cannot leak across sets.
- Report counts and uncertainty, not only a single percentage.
- Score each language and behavior separately; never hide a weak language inside a global average.
- Keep English regression checks beside every multilingual experiment.
- Compare the untouched base, current EG-1, prompt candidates, and trained candidates on the same cases.
- Record all failures and discarded candidates, not only winners.
- A prompt change is not shippable on current EG-1 weights until tested for training-prompt mismatch.
- PC training results are provisional until the merged, quantized model passes the exact Mac runtime.
- Do not tune on the frozen release set.

## Run record format

Every run below records:

- timestamp and run ID
- question or hypothesis
- machine and runtime
- model and artifact identity
- prompt identity and full prompt path
- dataset identity, split, count, and hash
- seed and generation/training settings
- command or script used
- raw artifact paths
- score with numerator/denominator and uncertainty where possible
- regressions, failures, or harness defects
- decision and next action

## Baseline evidence brought into this run

These facts were rechecked before experiments began. They are not new candidate results.

### Product and model

- EG-1 base: `Qwen/Qwen3-4B-Instruct-2507`, approximately 4.02B parameters.
- Training: Unsloth QLoRA, rank 16, alpha 32, learning rate 5e-5, two epochs, response-only loss, 5,656 pairs.
- Shipped prompt: `scripts/eval/prompts/eg1-polish-prompt-v1.txt`.
- The trained and shipped prompts are byte-identical.
- The training corpus is overwhelmingly English but is not literally ASCII-only; earlier documentation saying otherwise needs correction.
- Exact normalized input overlap between the live training file and the 1,890-case evaluation file is 1,549/1,890 (82.0%). Therefore the 93.7% score on that evaluation cannot be treated as a held-out estimate.

### Existing language evidence

- Existing tuned EG-1 probe: 56 cases across German, Spanish, French, Hindi, Japanese, Portuguese, and Chinese.
- Language retained: 56/56.
- Meaning retained: 49/56.
- Full polish: 33/56.
- Per-language full-polish results previously inspected: German 8/8, Spanish 2/8, French 6/8, Hindi 2/8, Japanese 5/8, Portuguese 3/8, Chinese 7/8.
- The vanilla base translated 38/56 cases into English in the earlier probe.
- There is no Russian result, no frozen multilingual release set, and no native-speaker validation yet.

### Existing list evidence

- Direct user-facing list cases: 73/100 correct; Wilson 95% interval approximately 63.6%-80.7%.
- Shortest-list bucket: 44% correct versus 84% for other lists; Fisher exact p=0.00034.
- Existing published 86.5% combines 100 positive list cases with 100 traps and should not be described as 86.5% list-building accuracy.
- Training coverage is weak: no direct list commands in the specialist set, no numbered targets there, and only four numbered outputs across the full training set.

### Real usage context

- PostHog, successful production dictation users over 30 days: 352 active installations across 38 countries.
- Germany: 182 users (51.7%); United States: 61 (17.3%). The German spike followed a German blog and does not replace the US as the intended primary market.
- France: 5 users; Russia: 3 users. Country is only a language proxy because current successful-dictation events do not populate a language property.
- Benchmarks will be weighted by user count and product risk, not raw dictation volume, because a few heavy users distort volume.

### Hardware and reproducibility

- AlienSV is online over Tailscale with an RTX 4090 24 GB.
- Existing PC base: `~/tuning/models/Qwen3-4B-Instruct-2507`.
- Existing PC merged EG-1: `~/tuning/out/qwen4b_v2/merged16`.
- Existing v2 training completed in approximately 15.6 minutes for 708 steps; reported training loss 0.1200.
- Mac shipped artifact is an eight-shard GGUF model and will be tested through the product's actual runtime, not inferred from PC weights.

## Chronological log

### PRE-001 - Evidence and environment setup

Timestamp: 2026-07-15 00:38 EDT

Status: complete

Question: Is there enough verified context to begin controlled experiments, and is the 4090 host available?

Actions and results:

- Re-read EG-1 provenance, operations, prompt architecture, and model-selection research.
- Rechecked current GitHub trackers #1190, #1364, and #1394 and confirmed no open PR already owns this work.
- Classified #1364 as the active research/experiment tracker and added `in-progress`.
- Created branch `codex/eg1-multilingual-overnight` from a clean, up-to-date `main`.
- Verified AlienSV access, CUDA/Unsloth environment, base model, current tuned model, and the original training file hash.
- Started an explicit overnight goal ending in a founder-ready evidence report by 10:00 EDT.

Decision: proceed to primary-source research and benchmark construction before changing weights.

### LOG-001 - Durable logging requirement

Timestamp: 2026-07-15 00:38 EDT

Status: active for the entire overnight run

User requirement: maintain a durable record across context compression with every attempt, test, number, failure, and decision.

Implementation: this file is the single chronological source of truth. Raw outputs remain in timestamped run folders and are linked from subsequent entries. The file will be updated after each meaningful run and before any pause, compression boundary, or machine handoff.

### RES-001 - What research says prompt tuning can and cannot do

Timestamp: 2026-07-15 00:42 EDT

Status: complete

Question: Can multilingual quality be recovered with a prompt, a small multilingual tune, or only a different base model?

Primary sources reviewed:

- Qwen3 Technical Report: <https://arxiv.org/abs/2505.09388>
- Qwen3-4B-Instruct-2507 model card: <https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507>
- Multilingual Instruction Tuning With Just a Pinch of Multilinguality: <https://arxiv.org/abs/2401.01854>
- Turning English-centric LLMs Into Polyglots: <https://arxiv.org/abs/2312.12683>
- Overcoming Catastrophic Forgetting in Zero-Shot Cross-Lingual Generation: <https://arxiv.org/abs/2205.12647>
- Investigating Multilingual Instruction-Tuning: <https://arxiv.org/abs/2402.13703>

Findings:

- Qwen3 was pre-trained on 36 trillion tokens across 119 languages and dialects. The 4B base reported aggregate multilingual scores of 67.74 MGSM, 71.42 MMMLU, and 56.29 INCLUDE. These are broad task scores, not dictation-polish scores.
- The exact 2507 instruct model reports aggregate MultiIF 69.0, MMLU-ProX 61.6, INCLUDE 60.1, and PolyMATH 31.1. It does not publish a per-language ranking that can support a truthful “top five languages” claim.
- One controlled study found that replacing only 40 English examples with examples distributed across 11 non-English languages substantially improved multilingual instruction following. It also found gains from using only 2-4 training languages.
- A second study found that as few as three fine-tuning languages improved input/output language agreement for smaller English-centric models, but it explicitly warned that this was insufficient to close intrinsic quality gaps between English and non-English.
- Another study found up to 9.9% improvement from parallel multilingual rather than monolingual instruction-tuning corpora, while warning that some 7B models still needed larger datasets.
- English-only fine-tuning has caused catastrophic forgetting of non-English generation in prior work. Mixing multilingual data is a tested mitigation.

Interpretation for EG-1:

- Prompt engineering can plausibly reduce translation, extra commentary, and inconsistent output language when the base already has the language.
- Prompt engineering cannot reliably teach missing Russian inflections, language-specific filler behavior, or cleanup patterns absent from the weights.
- A small, balanced multilingual SFT experiment is justified if prompt tests still damage grammar or meaning. It must include English replay and task-specific examples rather than translated generic chat alone.
- A separate language-specific model is not the first move. It becomes justified only if the untouched Qwen base fails the task in that language, or a balanced tune cannot reach the morphology/safety gates without hurting English.

Decision:

- Do not claim a Qwen “top five” from the model card. Measure English, German, French, Russian, Spanish, and a Chinese control on the exact copy-edit task.
- Use English, German, French, Russian, and Spanish as the initial product-priority set. Chinese is a base-strength sentinel, not an automatically supported product language.
- Run prompt ablations before training. If training is required, use supervised QLoRA with English replay; DPO is not justified until real preference pairs exist.

### DATA-001 - Existing multilingual artifact re-audit

Timestamp: 2026-07-15 00:42 EDT

Status: complete

Artifacts:

- `scripts/eval/runs/bakeoff-1265/probes/multilingual_cases.jsonl`
- `scripts/eval/runs/bakeoff-1265/probes/ml_vanilla_judged.jsonl`
- `scripts/eval/runs/bakeoff-1265/probes/ml_tuned_v2_judged.jsonl`
- `scripts/eval/runs/bakeoff-1265/probes/ml_tuned_v2_hi_rejudge.jsonl`

Findings:

- The original Hindi judge file contains eight false all-fail records caused by a judge/harness problem. The dedicated Hindi rejudge correctly shows language retained 8/8, meaning retained 8/8, and requested polish completed 2/8.
- Corrected current-EG-1 results are: German 8/8 full requested polish, Spanish 2/8, French 6/8, Hindi 2/8, Japanese 5/8, Portuguese 3/8, and Chinese 7/8 for the `polish_ok` field.
- `polish_ok` totals 33/56, but the stricter conjunction of language retained, meaning preserved, and polish completed totals 32/56. The existing baseline calls 33/56 “full” and therefore mixes two definitions.
- Vanilla-base language retention was German 0/8, Spanish 2/8, French 3/8, Hindi 2/8, Japanese 2/8, Portuguese 1/8, and Chinese 8/8. Current EG-1 therefore strongly improved language retention despite overwhelmingly English SFT, but useful cleanup still varied sharply.

Decision: the new scorer will keep language retention, meaning safety, cleanup completion, and strict all-gates success as separate fields. It will not call `polish_ok` alone a full success.

### TOOL-001 - Reproducible inference and scoring harness

Timestamp: 2026-07-15 00:55 EDT

Status: complete for the development lane

New artifacts:

- `scripts/eval/eg1_multilingual_runner.py`
- `scripts/eval/eg1_multilingual_score.py`
- `scripts/eval/prompts/eg1-multilingual-strict-v1.txt`
- `scripts/eval/prompts/eg1-multilingual-labeled-v1.txt`
- `scripts/eval/corpus/eg1_multilingual_ru_v1.jsonl`

The runner records model, corpus and prompt hashes, seed, host, CUDA device, timing, and raw output. The deterministic scorer reports required content, forbidden content, script retention, list structure, strict conjunctions, per-category counts, and Wilson intervals. It explicitly refuses to call those checks native fluency.

Benchmark slice:

- Russian development: 16 cases.
- Russian frozen: 8 separate cases, not opened during prompt iteration.
- Behaviors: filler removal, self-correction, case/gender/number morphology, bullet and ordinal lists, prose restraint, names/numbers, code-switching, and quoted injection.
- Provenance: model-assisted drafting, not native-speaker approval.

Harness corrections after independent audit:

- Forbidden phrase matching now uses word boundaries, so incorrect `сказал` does not falsely match correct `сказала`.
- Em/en-dash bullet markers are accepted.
- Quote and dash variants are normalized.
- List structure is scored separately from item text.
- Exact number-word equivalence remains outside the deterministic scorer and requires semantic review.

Known runtime warning: the PC Hugging Face load of the merged EG-1 tokenizer reports an incorrect-regex warning that the untouched base does not report. These PC results are provisional until reproduced with the GGUF/Mac runtime.

### RUN-001 - Russian prompt matrix on AlienSV

Timestamp: 2026-07-15 00:55 EDT

Status: complete

Machine: AlienSV, RTX 4090 24 GB, WSL2 Ubuntu, Torch 2.10.0+cu128.

Models:

- Untouched `Qwen3-4B-Instruct-2507`.
- Current merged FP16 EG-1 v1.

Prompts:

- Exact shipped EG-1 prompt.
- Strict multilingual prompt with explicit never-translate and morphology-preservation rules.
- Language-labeled prompt with explicit Russian metadata.

Runs: 6 model/prompt combinations x 16 development cases = 96 generations. Seed 1265, greedy decoding, batch size 8.

Raw artifacts: `docs/experiments/eg1-multilingual/alien-runs/`.

Corrected deterministic strict passes:

| Model | Shipped | Strict multilingual | Language labeled |
|---|---:|---:|---:|
| Untouched Qwen | 3/16 | 7/16 | 7/16 |
| Current EG-1 | 7/16 | 6/16 | 6/16 |

These are conservative structural/content checks, not language-quality scores.

### SCORE-001 - Independent model-assisted Russian review

Timestamp: 2026-07-15 00:55 EDT

Status: complete, native review still required

| Run | Same language | Meaning safe | Cleanup complete | Grammar correct | Damaging | Strict all gates |
|---|---:|---:|---:|---:|---:|---:|
| Base + shipped | 9/16 | 9/16 | 6/16 | 5/16 | 12/16 | 3/16 |
| Base + strict | 16/16 | 11/16 | 8/16 | 14/16 | 5/16 | 8/16 |
| Base + labeled | 16/16 | 10/16 | 7/16 | 12/16 | 6/16 | 7/16 |
| EG-1 + shipped | 16/16 | 11/16 | 9/16 | 13/16 | 5/16 | 9/16 |
| EG-1 + strict | 16/16 | 13/16 | 9/16 | 14/16 | 3/16 | 9/16 |
| EG-1 + labeled | 16/16 | 11/16 | 9/16 | 13/16 | 5/16 | 9/16 |

Concrete failures shared across current EG-1 prompts:

- Failed to resolve Tuesday 3:00 to the final Wednesday 3:30 intent.
- Broke “five new applications” into “Five. A new application.”
- Left plural verbs with singular feminine `Команда`.
- Changed pull request 184 to 84 in every run.

Prompt interpretation:

- The strict prompt fixes much of the untouched base model's English-translation behavior.
- The current EG-1 morphology outputs were byte-identical across prompts on all five dedicated morphology cases.
- Strict/labeled prompts caused EG-1 to falsely turn the prose list trap into bullets.
- The explicit language label did not improve EG-1.
- Current EG-1 remains much better than the untouched base at direct and ordinal list formation.

Decision: no-go for a prompt-only release. Go for a bounded multilingual QLoRA experiment with separate training data and English replay. Keep the exact shipped prompt as the training contract for the first weight experiment so prompt and weights are not changed simultaneously.

### SIZE-001 - Current adapter and model sizes

Timestamp: 2026-07-15 00:55 EDT

Status: complete

- Rank-16 LoRA adapter safetensors: 132,187,888 bytes = 126.1 MiB.
- Full checkpoint including optimizer/trainer state: 202 MiB.
- Merged FP16 model: 7.6 GiB.
- Shippable merged Q5_K_M model: 2,889,511,680 bytes = 2.69 GiB.

### ARCH-001 - Offline delivery and language architecture decision

Timestamp: 2026-07-15 01:01 EDT

Status: founder decision recorded

Hard product constraints:

- Dictation and polish must work completely offline after model download.
- Internet may be required only to download or update model artifacts.
- Preferred outcome: one approximately 2.9 GB multilingual EG-1, even if reliable coverage requires tens or hundreds of thousands of international training examples.
- Acceptable fallback only if one multilingual model cannot pass per-language gates: one shared approximately 2.7 GB Qwen base plus one small user-selected regional adapter.
- Rejected as a dealbreaker: separate approximately 2.9 GB full models for English, German, Russian, French, and other languages.

Runtime feasibility verified:

- The exact bundled `llama-server` accepts multiple `--lora` adapters.
- It supports `--lora-init-without-apply`, global `POST /lora-adapters`, and a per-request `lora` field.
- Per-request selection is the safer app design because global switching can race.
- Requests with different adapter configurations are not batched together; that is a small concern for a single-user local app.
- Prompt/KV caches must be isolated by adapter identity.

Official reference: <https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md#post-lora-adapters>

Decision ladder:

1. Test one multilingual model first.
2. Scale multilingual data only when dev and frozen evidence improves without English regression.
3. Test one shared-base plus regional-adapter fallback only if the single-model approach plateaus.
4. Never ship one full multi-gigabyte model per language.

### SCOPE-001 - Base-model bakeoff added

Timestamp: 2026-07-15 01:01 EDT

Status: active

Founder request: verify whether a better tunable base exists instead of assuming Qwen remains optimal.

Plan: run the same untouched multilingual/list development benchmark on current approximately 4B candidates, starting with Gemma 4 E4B already present on AlienSV. Only bases that are offline, commercially usable, llama.cpp-compatible, non-thinking/low-latency, and compatible with the one-model size target qualify.

### DATA-GEN-001 - Oversized teacher-data request timed out

Timestamp: 2026-07-15 01:03 EDT

Status: failed run; generation strategy corrected

The first attempt asked the Claude subscription teacher to generate 60 English list examples and 40 German examples in one response. It timed out after 300 seconds and produced no accepted rows. This is recorded as a harness/data-generation failure, not a model-quality result.

Correction: generate independent 8-12 row batches with explicit per-category quotas, validate every JSONL batch, and combine only after overlap and language checks. The first successful batches are:

- English lists batch A: 10 rows, 5 explicit lists and 5 ordinal lists.
- English lists batch B: 10 rows, 5 explicit lists and 5 ordinal lists.
- German lists batch A: 10 rows, 5 explicit lists and 5 ordinal lists.

### BASE-SMOKE-001 - Gemma 4 E4B untouched Russian smoke

Timestamp: 2026-07-15 01:03 EDT

Status: complete; did not win the two-case smoke

Machine: AlienSV, RTX 4090, WSL2. Prompt: strict multilingual prompt. Cases: Russian development cases 001-002 only.

- Case 001 kept Russian, meaning, dative `Анне`, and the deadline, but retained the forbidden filler `Ну`.
- Case 002 kept Russian and the inflected entity `с Олегом`, but retained the abandoned Tuesday 3:00 plan instead of resolving to Wednesday 3:30.
- Smoke cleanup pass: 0/2.

Interpretation: Gemma showed useful language retention and morphology, but no evidence yet that it is a better copy editor than Qwen/EG-1. Run one full 16-case development set to measure morphology and list behavior; stop Gemma exploration if it does not materially beat the Qwen baselines.

Raw artifact on AlienSV: `C:\\Users\\saura\\eg1-overnight\\runs\\gemma_base_strict_smoke.jsonl`.

### BASE-RUN-001 - Gemma 4 E4B Russian development set

Timestamp: 2026-07-15 01:10 EDT

Status: complete; stopped before frozen evaluation

Run: untouched Gemma 4 E4B, strict multilingual prompt, all 16 Russian development cases, greedy decoding, seed 1265, batch size 4 on AlienSV.

Deterministic strict pass: 7/16, 43.8%, Wilson 95% CI 23.1%-66.8%.

Independent model-assisted Russian review, not native-speaker proof:

- Same language: 16/16.
- Meaning safe: 14/16.
- Cleanup complete: 9/16.
- Grammar correct: 16/16.
- Damaging: 2/16.
- Strict all gates: 9/16.

Gemma repaired all five dedicated Russian morphology cases, including `пять новых заявок` and singular-team verb agreement. It still failed both self-corrections, did not turn spoken ordinals into a numbered list, and retained some fillers. It tied current EG-1 strict at 9/16 overall while showing better morphology and restraint but weaker list activation.

Size observation, not a disqualification: the E4B name means 4.5B effective compute, but the official card reports 8B total weights due to per-layer embeddings. The downloaded FP16 text model occupies 15 GB on AlienSV, versus 7.6 GB for Qwen 4B. Gemma therefore carries a meaningful download/storage penalty, but remains a serious one-model candidate because one larger multilingual download is acceptable when quality justifies it.

Raw artifact: `docs/experiments/eg1-multilingual/alien-runs/gemma_base_strict_dev16.jsonl`.

### BASE-RESEARCH-001 - Current tunable-base shortlist

Timestamp: 2026-07-15 01:10 EDT

Status: shortlist complete; empirical bakeoff active

Primary-source shortlist after applying offline, commercial, tunable, size, and runtime constraints:

1. Qwen3.5-4B: strongest direct candidate. Apache 2.0, 4B language model, 201 claimed languages/dialects, current Unsloth QLoRA support, and current llama.cpp support. Official aggregate multilingual scores are materially stronger than the shipped Qwen3 generation, but copy-edit quality must be tested directly.
2. Current Qwen3-4B-Instruct-2507: known runtime/training path and proven list-learning capacity; baseline to beat.
3. Ministral 3 3B Instruct 2512: Apache 2.0, 3.4B language model, explicitly supports fine-tuning and several priority languages. Published multilingual MMLU trails Qwen3 4B base, so it is a compact control rather than first choice.
4. Phi-4 Mini Instruct: MIT, 3.8B, multilingual and fine-tunable, but its published multilingual MMLU trails Qwen2.5-3B and its model card warns of language differences. Lower priority.
5. Gemma 4 E4B: strongest Russian morphology in the first bakeoff and a serious quality candidate. Its 8B total weights create a size penalty in the final matrix, not an automatic rejection.

The exact bundled `llama-server` binary contains Qwen3.5 and Gemma 4 model support. AlienSV has Unsloth 2026.6.9 and Transformers 5.5.0, sufficient for Qwen3.5 experimentation.

### HARNESS-002 - Qwen3.5 reasoning leakage caught

Timestamp: 2026-07-15 01:10 EDT

Status: invalid smoke; harness corrected and rerun started

The first two-case Qwen3.5 smoke emitted a long `Thinking Process:` instead of clean text and hit the 256-token cap. This is a chat-template configuration failure, not a Qwen3.5 quality score. The runner now records thinking mode and explicitly keeps it disabled by default for the copy-edit task. The corrected non-thinking smoke uses a new run ID and output file; the invalid artifact remains preserved for audit.

### ARCH-002 - Single-model size rule clarified

Timestamp: 2026-07-15 01:13 EDT

Status: founder decision recorded

- Acceptable: one larger full model when it reliably supports every chosen language offline.
- Acceptable fallback: one shared full model plus small optional regional LoRA adapters.
- Rejected and disqualified regardless of quality score: requiring a user to download multiple full-size models to obtain multilingual polishing. This is not a weighted tradeoff.
- Ranking rule: artifact size, Mac memory, latency, and power are weighted costs in the base-model scorecard, not hard exclusions by themselves.

This clarification restores Gemma 4 E4B to the serious-candidate lane. A single larger universal download can win. No architecture experiment may propose separate full English, German, French, Russian, or Spanish downloads.

### BASE-RUN-002 - Qwen3.5-4B non-thinking Russian development set

Timestamp: 2026-07-15 01:13 EDT

Status: complete; hard-stopped after one smoke and one full development run

Run: untouched Qwen3.5-4B, strict multilingual prompt, all 16 Russian development cases, thinking disabled, greedy decoding, seed 1265, batch size 8 on AlienSV.

Deterministic strict pass: 6/16, 37.5%, Wilson 95% CI 18.5%-61.4%.

Independent model-assisted Russian review, not native-speaker proof:

- Same language: 16/16.
- Meaning safe: 11/16.
- Cleanup complete: 6/16.
- Grammar correct: 15/16.
- Damaging: 5/16.
- Strict all gates: 6/16.

Qwen3.5 repaired all five core morphology cases, but failed both list activations, failed both self-corrections, changed invoice `АВ-204` to `АВ-24`, and repeatedly changed informal singular commands into formal/plural commands. It did not beat untouched Qwen3, Gemma, or current EG-1 on the task-specific development set.

Decision: no Qwen3.5 weight experiment in this first lane. Its official aggregate multilingual scores are not a substitute for our copy-edit benchmark. Revisit only if a later, broader multi-language benchmark contradicts this Russian discovery result.

Raw artifact: `docs/experiments/eg1-multilingual/alien-runs/qwen35_base_strict_nothink_dev16.jsonl`.

### HARNESS-003 - Merged-tokenizer metadata isolated

Timestamp: 2026-07-15 01:18 EDT

Status: corrected; invalid auto-fix preserved

Both historical merged EG-1 and merged Gemma checkpoints trigger a Transformers warning about legacy tokenizer regex metadata. An attempted `fix_mistral_regex=True` load failed inside Transformers 5.5.0 with `AttributeError: 'tokenizers.Tokenizer' object has no attribute 'backend_tokenizer'`; no generations were produced and the run is invalid.

Correction: the evaluation runner now accepts a separate tokenizer path and records its file hashes. Every tuned checkpoint uses the untouched base model's tokenizer, which is the tokenizer used during training. This removes merged-tokenizer metadata from the comparison.

Sanity result: all 16 current EG-1 outputs and all 16 historical tuned-Gemma outputs were byte-identical between the merged-tokenizer and pristine-base-tokenizer paths on this Russian development set. Earlier conclusions did not change, but all new runs use the reproducible base-tokenizer path.

### BASE-RUN-003 - Historical English-tuned Gemma checkpoint

Timestamp: 2026-07-15 01:18 EDT

Status: complete; strong evidence for balanced multilingual Gemma training

Existing AlienSV artifact discovered:

- Base: Gemma 4 E4B.
- Training set: 3,036 original English copy-edit rows.
- QLoRA: rank 16, alpha 32, two epochs.
- Training time: 809.3 seconds (13.5 minutes) on RTX 4090.
- Training loss: 0.0271.
- Adapter: 146,888,168 bytes (about 140 MiB).

Evaluation: shipped EG-1 prompt, pristine Gemma base tokenizer, 16 Russian development cases.

- Deterministic strict pass: 9/16, 56.3%, Wilson 95% CI 33.2%-76.9%.
- Primary model-assisted strict rubric: 12/16. Failures were retained filler in case 1, broken `пять новых заявок` agreement in case 6, invoice 204 changed to 24 in case 11, and retained fillers in case 15. This review is not independent or native-speaker certification.
- List behavior: built the direct list, converted spoken ordinals to numbered lines, and passed the prose restraint trap. It still leaked the spoken direct-formatting command.
- Meaning/formality: resolved the appointment correction, retained Russian throughout, preserved pull request 184 and English product terms, and kept informal command register.

Interpretation: English-only tuning caused one visible Russian morphology regression versus untouched Gemma, but it learned the missing list and self-correction behavior without broadly erasing Russian. A balanced multilingual Gemma QLoRA is now a high-value experiment, not merely a theoretical alternative.

Valid raw artifact: `docs/experiments/eg1-multilingual/alien-runs/gemma_english_tuned_ship_basetok_dev16.jsonl`.

### SIZE-002 - Comparable candidate artifacts

Timestamp: 2026-07-15 01:18 EDT

Status: current registry sizes captured; final custom artifacts still require conversion

- Current EG-1 Qwen Q5_K_M: 2,889,511,680 bytes (2.69 GiB), measured on AlienSV.
- Qwen3.5-4B Q5_K_M registry artifact: 3,143,656,608 bytes (2.93 GiB).
- Gemma 4 E4B Q4_K_M registry artifact: 5,335,289,824 bytes (4.97 GiB).
- Ministral 3 3B Q5_K_M registry artifact: 2,474,178,720 bytes (2.30 GiB).

Gemma's current comparable download penalty versus EG-1 is therefore about 2.28 GiB, not a need for multiple models. Runtime memory, latency, and power still need exact Mac measurement before the final matrix.

### DATA-001 - Multilingual smoke-training corpus structural gate

Timestamp: 2026-07-15 01:44 EDT

Status: structural pass; final semantic audit and native-speaker review caveat remain

- Added 180 multilingual rows to the original 5,656 rows: English 20, German 40, French 40, Russian 40, and Spanish 40.
- Combined training rows: 5,836.
- Combined SHA-256: `31a610847b412868580fc95b1fdb5b4b50900bfc61e07a94e2009ebcccd0a0d2`.
- Exact overlap against the 24-row Russian benchmark and existing 56-row multilingual probe set: none.
- JSON parsing, expected language counts, category counts, prompt hash, and source hashes: pass.

The first teacher draft was not safe enough to train. Model-assisted audit found list examples that formatted correctly while deleting important lead-ins such as obligation, time, purpose, destination, and clinical attribution. It also caught an invented Celsius unit and two examples that invented quotation status. Those rows were corrected or rewritten before this structural gate. This is evidence that list-shape accuracy alone is an unsafe tuning metric.

No training run is a release candidate without the remaining semantic audit and eventual native-speaker review. The immediate experiment is allowed to measure whether balanced multilingual data moves the model in the right direction; it is not release proof.

### DATA-002 - Independent live-tree semantic rescan

Timestamp: 2026-07-15 01:46 EDT

Status: go for one bounded smoke run and benchmark; not release evidence

Independent model-assisted audit of the corrected live tree reported:

- 180/180 structurally valid; all 18 batch manifests match live counts and quotas.
- 91/91 positive list targets activate; 20/20 traps remain prose.
- 32/32 dedicated morphology rows are plausible.
- Zero formatting-command leakage, exact duplicate IDs/inputs/outputs, or exact training/evaluation overlap.
- All previously identified unsafe semantic deletions and quotation-status examples were repaired.

Remaining coverage gaps: zero two-item positive lists, a 91:20 activation-to-restraint imbalance, English has no new restraint traps, several same-language near-template pairs remain, and all 180 rows have `native_reviewed: false`. Therefore this dataset can answer whether balanced data is directionally useful, but cannot establish release quality.

### TRAIN-001 - Qwen smoke launch API failure

Timestamp: 2026-07-15 01:46 EDT

Status: invalid before training; fixed and relaunched under a new run ID

The first `qwen4b_multilingual_smoke_v1` launch loaded the clean base but stopped before step 1 because installed TRL 0.24+ expects `processing_class` instead of the historical `tokenizer` argument. No weights were trained. The script now inspects the installed trainer signature, selects the supported argument, and imports Unsloth before TRL so patching occurs in the required order. The valid retry is `qwen4b_multilingual_smoke_v1r2`.

### BENCH-001 - Release-grade benchmark size and separation

Timestamp: 2026-07-15 01:52 EDT

Status: protocol proposed; corpus construction and native review pending

An independent evaluation-design review concluded that the Russian 16-development/8-frozen set and eight-case-per-language probes are discovery screens, not statistically adequate release evidence.

The proposed release benchmark contains 160 development and 320 frozen cases per language for English, German, French, Spanish, and Russian: 800 development and 1,600 frozen cases total. Each language receives 160 general polishing cases, 80 positive-list cases, and 80 restraint cases in the frozen set. The matrix explicitly adds the missing two-item positive lists and balances them against two-item prose traps.

Primary reporting uses numerator/denominator, Wilson 95% intervals, paired bootstrap intervals, exact McNemar comparisons, Holm correction across five primary language tests, and separate scoreboards for core polish, list activation, and false lists. Proposed release gates include at least 285/320 strict green, 317/320 same-language and meaning preservation, 72/80 positive lists, no more than 2/80 false lists per language, and zero S4 critical damage across all frozen cases.

Every frozen corpus requires native authoring/validation before sealing and two blinded native output reviewers plus adjudication. LLM judges and subagents remain triage tools, not release authorities.

Full protocol: `docs/experiments/eg1-multilingual/BENCHMARK-DESIGN-V1.md`.

### DATA-003 - Smoke-corpus balance terminology correction

Timestamp: 2026-07-15 01:55 EDT

Status: interpretation guardrail

The 5,836-row smoke corpus is multilingual-augmented, not truly language-balanced. It contains the original 5,656 mostly English rows, 20 new English list rows, and only 40 rows each for German, French, Spanish, and Russian. Non-English additions are 160/5,836 (2.74%), or 0.69% per added language.

This is deliberate for the cheapest direction test and is consistent with research showing that small multilingual instruction sets can sometimes improve language agreement. It cannot estimate the ceiling of a genuinely balanced corpus with thousands or hundreds of thousands of native-reviewed multilingual examples. A null result would reject this low-dose recipe, not the broader one-model multilingual architecture.

### TRAIN-002 - Qwen multilingual-augmented smoke candidate

Timestamp: 2026-07-15 02:08 EDT

Status: training complete; Russian development result is a tie, not a win

Valid run: `qwen4b_multilingual_smoke_v1r2` on AlienSV RTX 4090.

- Clean base: Qwen3-4B-Instruct-2507.
- Data: 5,836 rows, SHA-256 `31a610847b412868580fc95b1fdb5b4b50900bfc61e07a94e2009ebcccd0a0d2`.
- QLoRA: rank 16, alpha 32, 33,030,144 trainable parameters, two epochs, 730 steps, effective batch 16, seed 1265, response-only loss.
- Training time: 989.188 seconds (16.49 minutes); trainer runtime 1,005.494 seconds.
- Final aggregate training loss: 0.114771.
- Adapter directory: 143,625,108 bytes (about 137 MiB including tokenizer/config files).
- Merged FP16 directory: 8,056,450,299 bytes.

Untouched Russian development evaluation: shipped prompt, pristine base tokenizer, greedy decoding, 16 cases. Frozen rows were not run.

- Deterministic strict pass: 7/16, 43.8%, Wilson 95% CI 23.1%-66.8%.
- Current EG-1 shipped baseline on the same gate: 7/16. This smoke candidate tied; it did not establish improvement.
- Clear changes versus current EG-1: corrected the imperative in case 1, improved prose punctuation in case 10, used Russian quotes in case 11, and correctly resolved the filler/correction in case 15.
- Serious regression: case 12 changed 1.6 and 1.8 million to 0.6 and 0.8 million. This is damaging numerical drift.
- Other outputs were byte-identical in 11/16 cases.

Decision: this low-dose Qwen recipe is not a finalist on deterministic evidence. An independent semantic review is still running. Do not open frozen data. Continue with the predeclared same-data Gemma base comparison, then decide whether the next Qwen experiment needs materially more multilingual weight rather than prompt changes.

Independent model-assisted review completed after the deterministic score:

| Metric | Current EG-1 | Qwen multilingual smoke |
|---|---:|---:|
| Same language | 16/16 | 16/16 |
| Meaning safe | 12/16 | 12/16 |
| Cleanup complete | 9/16 | 9/16 |
| Grammar correct | 13/16 | 14/16 |
| Damaging cases | 4/16 | 4/16 |
| Strict all gates | 9/16 | 9/16 |

Paired strict wins/losses/ties were 0/0/16. The candidate fixed current EG-1's case-15 corruption but introduced the case-12 numerical corruption; both retained the appointment conflict, broken five-application agreement, and PR 184 to PR 84 error. Independent conclusion matches the deterministic decision: trade, not improvement. This review is model-assisted rather than native-speaker proof.

### MODEL-001 - Weighted selection matrix

Timestamp: 2026-07-15 02:12 EDT

Status: proposed matrix; final measurements pending

The candidate matrix now uses hard architecture/safety/runtime gates followed by a 100-point weighted rank. Quality and safety control 65 points; deployment cost controls 25 points, including 8 points for exact download size; engineering and licensing control 10 points.

This implements the founder decision precisely: file size matters, but a single larger universal model can win. Any design requiring multiple full-size language downloads is disqualified before scoring. Exact candidate GGUF size, Mac memory, latency, power, runtime parity, and sealed multilingual quality remain pending.

Full matrix: `docs/experiments/eg1-multilingual/MODEL-SCORECARD-V1.md`.

### ARCH-002 - No multiple full-model downloads

Timestamp: 2026-07-15 02:36 EDT

Status: hard product constraint

Founder clarification: any multilingual architecture that requires one user to download multiple full-size language models is unacceptable, not merely a lower-scoring option. It is now a hard disqualifier before model ranking. The only allowed deployment shapes are:

1. one universal full model that handles every supported language; or
2. one shared full base plus small, hot-swappable language adapters if a universal tune cannot reach the quality gates.

A larger single universal model is allowed. Exact download size remains an 8-point weighted factor among architectures that pass this gate. Polishing must remain fully offline after the initial model or adapter download.

### TRAIN-003 - Gemma multilingual-augmented smoke candidate

Timestamp: 2026-07-15 02:41 EDT

Status: training complete; discovery finalist pending broader regressions

Valid run: `gemma4e4b_multilingual_smoke_v1` on AlienSV RTX 4090, using the exact same 5,836-row corpus and prompt as the Qwen smoke comparison.

- Clean base: Gemma 4 E4B Instruct.
- QLoRA: rank 16, alpha 32, 36,700,160 trainable parameters, two epochs, effective batch 16, seed 1265, response-only loss.
- Training time: 1,490.964 seconds (24.85 minutes); trainer runtime 1,524.767 seconds.
- Final aggregate training loss: 0.0221933.
- Adapter directory: 179,089,899 bytes (about 171 MiB including tokenizer/config files).
- Merged FP16 directory: 16,024,814,477 bytes.

Untouched Russian development evaluation used the shipped prompt, pristine Gemma tokenizer, greedy decoding, and the same 16 cases. Frozen rows were not opened.

- Deterministic strict pass: 9/16 versus current EG-1 at 7/16.
- Independent model-assisted strict pass: 14/16 versus current EG-1 at 8/16 when spoken list-command leakage counts as incomplete cleanup.
- Paired independent strict result: 6 wins, 0 losses, 10 ties.
- Meaning-safe: 15/16 versus 12/16; damaging cases: 1/16 versus 4/16.
- Gemma resolved the appointment self-correction, singular-team agreement, direct-list command leakage, AV-204 formatting, 1.6-to-1.8 correction, and preserved PR 184 and A4 where current EG-1 corrupted content.
- Remaining shared failure: both models broke “five new applications” into a malformed singular result. Gemma also retained two fillers in the hardest mixed case, so it was not strict green there.

Decision: Gemma is the first discovery candidate to show a clear paired gain without an observed paired strict loss. It is not a release winner yet. The existing 56-case multilingual probe, English list activation/restraint, exact quantization size, and shipped-Mac runtime must pass before frozen evaluation.

### BENCH-002 - Two-item English list development corpus

Timestamp: 2026-07-15 02:41 EDT

Status: candidate corpus under independent review; not frozen or release evidence

The existing specialist corpus had no direct two-item positive list cases, matching the real-user weakness. A generator now creates exactly balanced development candidates across explicit/scoped prompts and work, personal, technical, medical, and legal/financial domains while screening exact duplicates against existing training and evaluation corpora.

- Sonnet generations at 40, 20, and 10 rows each exceeded the 180-second bounded generation limit and produced no usable artifact.
- Haiku produced two independent 10-row batches (`v1a` and `v1b`). Both remain `native_reviewed: false` and development-only.
- The first independent semantic audit found nine gold-answer scope/detail losses. Those gold answers were repaired.
- A second audit found that eight mechanical `required` arrays still checked nouns but not the task action. Those checks were repaired. Final live-tree rescan is pending.
- `v1b` was generated successfully and is undergoing a separate independent audit before any model sees it.

This is intentional benchmark hygiene: generated cases are quarantined until semantic and mechanical checks agree, and no failed candidate is allowed to become a frozen benchmark silently.

### EVAL-004 - Existing 56-case multilingual development comparison

Timestamp: 2026-07-15 02:53 EDT

Status: complete for discovery; not native or release proof

The current EG-1, Qwen multilingual smoke, and Gemma multilingual smoke candidates were run on the existing eight-cases-per-language probe for German, Spanish, French, Hindi, Japanese, Portuguese, and Chinese. All used the shipped prompt and deterministic decoding. An independent model-assisted scorer ignored the old labels and rescored every output. No frozen cases were inspected.

| Model | Same language | Meaning safe | Cleanup complete | Grammar correct | Damaging | Strict |
|---|---:|---:|---:|---:|---:|---:|
| Current EG-1 | 56/56 | 48/56 | 35/56 | 50/56 | 8/56 | 32/56 |
| Qwen multilingual smoke | 56/56 | 52/56 | 37/56 | 51/56 | 4/56 | 34/56 |
| Gemma multilingual smoke | 56/56 | 54/56 | 35/56 | 52/56 | 2/56 | 34/56 |

Paired strict comparison versus current was 7 wins/5 losses/44 ties for Qwen and 8 wins/6 losses/42 ties for Gemma. These are small, non-significant discovery changes, not proof of a strict-quality win. Gemma's safety result is more interesting: it reduced observed damaging cases from 8 to 2 and had only one new damaging regression, changing German `Also` to `Auch` and thereby adding “too.” Qwen introduced that same German error plus a French uncertainty-to-certainty error.

Per-language strict results for current/Qwen/Gemma were German 8/7/7, Spanish 3/5/4, French 6/6/6, Hindi 2/2/3, Japanese 5/5/6, Portuguese 3/4/3, and Chinese 5/5/5, each out of eight. All three failed the same Hindi time self-correction case. Gemma's strict rate remained limited by retained fillers in Spanish, French, Portuguese, and Chinese even when meaning was safe.

Decision: neither low-dose tune proves a universal-model win on this probe. Gemma remains the safer discovery finalist because it combined the strong Russian paired result with the lowest damage count here. Its next training recipe needs more cleanup examples and scorer calibration, not merely more languages.

### BENCH-003 - Audited English two-item development set ready

Timestamp: 2026-07-15 02:53 EDT

Status: go for development experiments; not frozen or release proof

Both 10-row batches completed repeated independent live-tree audits after correcting scope loss, attribution loss, weak required checks, and duplicate scenario shapes. Final result: 20/20 cases are structurally and semantically approved for development use, with five explicit and five scoped cases per batch, two cases per domain, and one deliberately short 18-word case. Both remain `native_reviewed: false`.

Under the unchanged shipped prompt, preliminary deterministic structure-only scoring found exactly two appropriate bullet lines in:

- current EG-1: 11/20;
- Qwen multilingual smoke: 10/20;
- Gemma multilingual smoke: 8/20.

The stricter mechanical gate, which also requires removal of spoken formatting commands and exact audited scope/action phrases, was only 1/20, 0/20, and 0/20 respectively. This exact-phrase gate is intentionally conservative and requires independent semantic reconciliation before it is treated as the main quality number. The structure result alone confirms that short/scoped two-item list activation is not fixed by either low-dose tune.

Decision: run one predeclared list-aware prompt smoke on current EG-1 and the safer Gemma candidate. Promote the prompt to the full 100-positive/100-restraint development suite only if two-item activation rises materially without meaning damage.

### EVAL-005 - Shipped-prompt English positive lists and restraint

Timestamp: 2026-07-15 02:59 EDT

Status: independent development score complete

An independent model-assisted reviewer scored all 100 existing positive-list cases. This review exposed that activation alone overstates correct list behavior because some activated outputs merge or split items incorrectly.

| Model | Behavior correct | Meaning preserved | Clean | Strict green |
|---|---:|---:|---:|---:|
| Current EG-1 | 72/100 | 94/100 | 96/100 | 71/100 |
| Qwen multilingual smoke | 73/100 | 94/100 | 99/100 | 72/100 |
| Gemma multilingual smoke | 61/100 | 97/100 | 100/100 | 61/100 |

Qwen versus current had 7 strict wins, 6 losses, and 87 ties; exploratory exact McNemar p=1.00. Gemma had 6 wins, 16 losses, and 78 ties. Neither low-dose tune improves positive-list behavior under the unchanged shipped prompt. Current EG-1 was especially weak in the shortest bucket: 11/25 behavior-correct, matching the earlier 44% short-list finding.

The scorer also found two unsafe gold references (`LF-009` and `LF-087`) that mis-group or overwrite dictated actions. The independent score used the actual dictated input rather than rewarding those defective golds. These rows must be corrected before this corpus is sealed or used for training.

On the 100 restraint traps, all three models produced zero false lists. Independent strict green was current 98/100, Qwen 97/100, Gemma 98/100. Meaning damage was limited to `LFT-046` for current and Qwen; Gemma retained the meaning but had a punctuation garden path. This establishes the key baseline tradeoff: current EG-1 is conservative enough on prose but misses many genuine lists.

### PROMPT-003 - List-aware v2 smoke and full raw run

Timestamp: 2026-07-15 02:59 EDT

Status: smoke promoted; full independent scoring in progress

One predeclared prompt variant added a general behavior rule: create bullets for explicit list/checklist/steps requests or clearly scoped sets of separate tasks/items; use numbers only when requested; remove spoken formatting commands; and preserve ordinary prose/incidental enumerations as prose.

On the audited 20-case two-item smoke, deterministic exact-two-bullet structure changed:

- current EG-1: 11/20 to 19/20;
- Gemma multilingual smoke: 8/20 to 15/20.

That material activation gain triggered the single allowed full development run. On the 100 positive-list cases, raw structural activation was 91/100 for both current and Gemma, with the intended item count on 88/100 each. Independent semantic scoring is pending.

The restraint side found a real tradeoff. Current+v2 created three false lists (`LFT-039`, `LFT-040`, `LFT-051`), including a damaging split of “picked up dinner.” Gemma+v2 created one false list (`LFT-040`), an ambiguous three-action sentence (“draft, review, send”). Therefore prompt-only is not automatically accepted: Gemma may meet the proposed rate threshold, but the current model's prompt variant does not. Independent full restraint scoring and multilingual checks are running before the lane is stopped or promoted.

Independent scoring of the 100 positive cases then confirmed the structural signal:

| Configuration | Behavior | Meaning | Clean | Strict |
|---|---:|---:|---:|---:|
| Current + shipped prompt | 72/100 | 94/100 | 96/100 | 71/100 |
| Current + list-v2 | 86/100 | 92/100 | 98/100 | 85/100 |
| Gemma + shipped prompt | 61/100 | 97/100 | 100/100 | 61/100 |
| Gemma + list-v2 | 90/100 | 96/100 | 100/100 | 90/100 |

Paired strict results were 15 wins/1 loss/84 ties for current+v2 and 30 wins/1 loss/69 ties for Gemma+v2. Exploratory exact McNemar p-values were 0.00052 and 0.000000030 respectively. These are strong development signals, not held-out proof. Gemma+v2 reached 25/25 strict in the former bucket-2 weakness, but created one damaging positive-list segmentation error at `LF-046`. Current+v2 created three damaging positive-list regressions and reproduced both known unsafe gold references. This makes Gemma+v2 the safer prompt candidate.
