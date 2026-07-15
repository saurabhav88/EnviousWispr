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
- A separate full language model is never an allowed fallback. If universal training fails after the predeclared dose ladder, language-specific adaptation may proceed only as a delta adapter over one shared base.

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

Runtime capability inspection at this point in the run (superseded by exact-Mac `ARCH-003`):

- The exact bundled `llama-server` accepts multiple `--lora` adapters.
- Its documentation advertises `--lora-init-without-apply`, global `POST /lora-adapters`, and a per-request `lora` field.
- This was only an API-surface hypothesis. Later exact-Mac testing found that the bundled build ignored per-request selection and that inactive preloaded adapters changed deterministic output. The only approved prototype starts or restarts the server with exactly one selected adapter.
- Future switching support must prove all-inactive output equals the pure base and one-active multi-loaded output equals that same adapter loaded alone, both byte-for-byte. A merged GGUF is not the isolation oracle.

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
- Rejected and disqualified regardless of quality score: requiring one user to install more than one complete base-weight set to obtain multilingual polishing. This is not a weighted tradeoff.
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

This implements the founder decision precisely: file size matters, but a single larger universal model can win. Any design requiring one user to install more than one complete base-weight set is disqualified before scoring. Exact candidate GGUF size, Mac memory, latency, power, runtime parity, and sealed multilingual quality remain pending.

Full matrix: `docs/experiments/eg1-multilingual/MODEL-SCORECARD-V1.md`.

### ARCH-002 - No multiple full-model downloads

Timestamp: 2026-07-15 02:36 EDT

Status: hard product constraint

Founder clarification: any multilingual architecture that requires one user to install more than one complete base-weight set is unacceptable, not merely a lower-scoring option. It is now a hard disqualifier before model ranking. The only allowed deployment shapes are:

1. one universal full model that handles every supported language; or
2. one shared full base plus small delta-only language adapters if a universal tune cannot reach the quality gates. The current safe runtime shape loads exactly one selected adapter at server start; hot-swapping is not approved.

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

### EVAL-006 - Two-item semantic reconciliation

Timestamp: 2026-07-15 03:10 EDT

Status: independent development score complete

The 20-case two-item set explains why raw list markup cannot be the release metric. List-v2 greatly improved activation, especially scoped lists, but often left the spoken formatting command as an unwanted header.

| Configuration | List behavior | Meaning safe | Cleanup | Grammar | Damaging | Strict |
|---|---:|---:|---:|---:|---:|---:|
| Current + shipped prompt | 11/20 | 20/20 | 1/20 | 16/20 | 0 | 1/20 |
| Current + list-v2 | 19/20 | 15/20 | 9/20 | 18/20 | 5 | 4/20 |
| Gemma + shipped prompt | 8/20 | 18/20 | 5/20 | 19/20 | 2 | 3/20 |
| Gemma + list-v2 | 15/20 | 20/20 | 4/20 | 18/20 | 0 | 4/20 |

Current+v2 is unsafe here: five explicit-list cases lost important project, report, endpoint, patient/discharge, or vendor-review scope. Gemma+v2 introduced no meaning damage and fixed its two shipped-prompt meaning failures, but only 4/20 outputs removed all audited spoken formatting/filler phrases. Scoped behavior moved from 0/10 to 9/10 for Gemma; this is the most useful direction signal.

Decision: prompt engineering proves the model can activate lists, but prompt text alone does not reliably remove spoken list commands. A future universal training recipe should teach the list boundary and command-removal behavior directly while retaining the list-v2 policy at inference/training parity. No second ad hoc prompt was invented from these 20 development outputs.

### RUNTIME-001 - Gemma universal Q5 artifact and bundled-Mac smoke

Timestamp: 2026-07-15 03:10 EDT

Status: exact runtime loads; full quantized benchmark running

The Gemma multilingual smoke merged checkpoint was converted with the current AlienSV llama.cpp tools and quantized directly from F16 to Q5_K_M.

- F16 GGUF: 15,053,095,232 bytes.
- Q5_K_M GGUF: 5,762,912,576 bytes (5.37 GiB).
- Q5 SHA-256: `973a9b0ccf708e538f435c5c34b647a236692f0f2d774527a360e6798b20c440`.
- Current EG-1 Q5: 2,889,511,680 bytes (2.69 GiB).
- Size cost: +2,873,400,896 bytes, almost exactly 2x current EG-1, but still one universal offline model rather than multiple language models.

The file was copied to the M4 Pro and hash-matched. The exact app-bundled `llama-server` (`fdb1db8`) successfully loaded it with the shipped flags: context 16,384, flash attention on, Q8 K/V cache. Warm-cache server readiness was about 2.1 seconds. After three probes, RSS was 5,984,640 KiB (about 5.71 GiB), versus the documented current-EG-1 4.1 GB RSS. Probe latency was 1,189 ms first request, then 645 ms and 512 ms warm. The restraint probe remained prose.

This passes binary compatibility but not yet the Mac release gate. The exact quantized artifact is now running all 292 list, restraint, two-item, multilingual, and Russian development cases through the local OpenAI-compatible server. Cold-disk startup, sustained power/thermals, frozen quality, and supported-Mac memory ceiling remain pending.

### EVAL-007 - List-v2 multilingual and restraint reconciliation

Timestamp: 2026-07-15 03:16 EDT

Status: prompt-only lane rejected; prompt-aligned training started

Independent development scoring confirmed that the list-v2 prompt is not a safe drop-in replacement for weights trained against the shipped prompt.

On the 16 Russian development cases, strict green changed from 9/16 to 6/16 for current EG-1 and from 14/16 to 12/16 for Gemma. Both list-v2 arms changed a requested numbered list into bullets and falsely listed ordinary prose. Damaging cases rose from 4 to 6 for current and from 1 to 2 for Gemma.

On the 56-case multilingual probe, current moved from 30 to 31 strict with four paired wins and three losses; Gemma remained 32 strict with four wins and four losses. The latest independent scorer is intentionally stricter than the earlier baseline and corrected two old false passes: Portuguese deadline loss and retained Chinese filler. The list-v2 prompt therefore changes individual outcomes but does not establish a core multilingual-quality gain.

On the 100 restraint traps, using the corpus's predeclared prose target:

| Configuration | Restraint | Meaning | Clean | Strict |
|---|---:|---:|---:|---:|
| Current + shipped prompt | 100/100 | 99/100 | 99/100 | 98/100 |
| Current + list-v2 | 97/100 | 98/100 | 97/100 | 95/100 |
| Gemma + shipped prompt | 100/100 | 100/100 | 98/100 | 98/100 |
| Gemma + list-v2 | 99/100 | 100/100 | 98/100 | 97/100 |

Every changed paired strict outcome favored the shipped prompt: current had three losses and no wins; Gemma had one loss and no wins. `LFT-040` is an ambiguous three-action boundary case and should be replaced before freezing, but it was not relabeled after seeing results. Even if accepted as a valid list, current retains two strict losses and Gemma merely ties its shipped prompt. Current's `LFT-039` regression is meaning-damaging because it separates “picked up” from “dinner.”

Decision: list-v2 remains useful evidence that list activation is controllable, but prompt-only release is rejected. The next experiment must train and infer against the same prompt contract rather than treating the prompt as a free runtime patch.

### TRAIN-004 - Prompt-aligned universal Gemma experiment

Timestamp: 2026-07-15 03:16 EDT

Status: running on AlienSV RTX 4090

Started `gemma4e4b_multilingual_listv2_aligned_v1` from the clean Gemma base with the same 5,836-row low-dose multilingual corpus and the same predeclared QLoRA hyperparameters as `TRAIN-003`, changing only the training prompt from shipped to list-v2. The intended inference prompt is also list-v2. This is a controlled prompt-contract experiment, not another hand-edited prompt variant.

The run preserves the hard deployment gate: it tests one universal offline model. It does not create or propose a separate full-size model per language. A launch wrapper refuses to overwrite an existing output directory, and the live RTX 4090 job was confirmed after model loading and tokenization began.

### RUNTIME-002 - Exact-Mac Q5 development run completed

Timestamp: 2026-07-15 03:22 EDT

Status: Q5 candidate rejected; Q6 experiment running

The exact bundled Mac runtime completed all 292 predeclared development cases with zero valid-run API errors: 100 positive lists, 100 restraint traps, 20 audited two-item cases, 56 multilingual cases, and 16 Russian cases. An earlier launch used the runner's default local key instead of the server's explicit test key and produced only unauthorized responses; that invalid attempt was stopped and overwritten. The valid run set `OPENAI_API_KEY=eg1-test-token`, matching the local server, and every final file has the expected row count with no error field.

Paired output comparison against the AlienSV BF16/Hugging Face run found material runtime-artifact drift:

| Suite | Exact matches | Changed | List-structure changes |
|---|---:|---:|---:|
| Positive lists | 66/100 | 34 | 9 |
| Restraint traps | 98/100 | 2 | 0 |
| Two-item v1a | 5/10 | 5 | 1 |
| Two-item v1b | 8/10 | 2 | 0 |
| Multilingual 56 | 33/56 | 23 | 1 |
| Russian 16 | 14/16 | 2 | 0 |

Many changed rows are harmless capitalization or bullet-marker differences, but at least one is a hard meaning failure: Russian `ru-dev-011` changed invoice code `АВ-204` to `АВ-24`, where the BF16/HF candidate preserved it. Q5 also removed list structure from several positive cases that BF16 formatted correctly. The independent semantic rescore is still running, so these are not yet final aggregate quality numbers.

Decision: the 5.37 GiB Q5 artifact is not a release candidate. This does not yet reject the one-model Gemma architecture because the founder explicitly allows a larger single model. A Q6_K artifact is being produced from the same F16 GGUF to test whether the failure is quantization-sensitive. Model size remains weighted after the hard single-model gate; quality and zero damaging regressions come first.

### RUNTIME-003 - Independent Q5 semantic score

Timestamp: 2026-07-15 03:37 EDT

Status: complete; Q5 rejected

Independent scoring of all 292 exact-Mac Q5 development outputs confirmed that the raw drift included real quality regressions.

| Suite | HF/BF16 strict | Mac Q5 strict | Paired wins / losses / ties |
|---|---:|---:|---:|
| Positive lists | 90/100 | 85/100 | 1 / 6 / 93 |
| Restraint traps | 97/100 | 96/100 | 0 / 1 / 99 |
| Two-item lists | 4/20 | 4/20 | 1 / 1 / 18 |
| Multilingual 56 | 32/56 | 34/56 | 6 / 4 / 46 |
| Russian 16 | 12/16 | 11/16 | 0 / 1 / 15 |
| Total | 235/292 | 230/292 | 8 / 13 / 271 |

The aggregate paired difference is not statistically significant on this sample (exact McNemar p=0.383), but the candidate fails the hard zero-damage rule. It flattened several requested lists, converted `Hardware store:` into a fourth item, lost required scope in two-item cases, and corrupted `АВ-204` to `АВ-24`. Positive-list strict fell five points. Multilingual aggregate strict improved by two, mainly through filler cleanup, showing why aggregate-only ranking would be unsafe.

### RUNTIME-004 - Q6 full run and Q8 failure probe

Timestamp: 2026-07-15 03:37 EDT

Status: Q6 rejected on hard damage; Q8 diagnostic stopped after smoke

Q6_K was produced from the same F16 GGUF and hash-matched on the Mac.

- Size: 6,217,261,376 bytes (5.79 GiB).
- SHA-256: `341776799b24a8e7ade88882cf7cca0590e9b9fc3ca91a011bba46ba6d96dbb8`.
- Warm-cache bundled-server readiness: about 1.25 seconds.
- RSS during the run: 6,447,072 KiB (about 6.15 GiB).
- Full development run: 292/292 rows, zero API errors, median 704 ms, p90 1,241 ms, max 12,781 ms.

Q6 still corrupted `АВ-204` to `АВ-24`, so it fails the hard meaning-safety gate before aggregate ranking. Independent scoring completed with 233/292 strict versus 235/292 HF/BF16 and 230/292 Q5. Paired Q6-versus-HF was 8 wins, 10 losses, and 274 ties (exact McNemar p=0.815), so no aggregate difference is statistically proven. Per-suite strict was 88/100 positive lists, 95/100 restraint, 6/20 two-item, 33/56 multilingual, and 11/16 Russian. Ten rows were meaning-damaging under the suite rubrics.

The second hard loss was `en-two-item-dev-v1b-005`, which dropped both the `new user auth endpoint` scope and the phrase `critical requirements`. Q6 did repair Q5's `Q3 report` scope loss and improved two-item strict from 4/20 to 6/20, but zero-damage safety takes precedence.

Q8_0 was then produced as the one allowed higher-precision diagnostic smoke rather than promoted directly to a full benchmark.

- Size: 8,031,240,512 bytes (7.48 GiB).
- SHA-256: `7556098cfd03d349821d94f7bd261ed847e8d8a3d9e9c0e14a935c59a7c9a3f9`.
- Warm-cache bundled-server readiness: about 1.44 seconds.
- RSS after 15 probes: 8,170,800 KiB (about 7.79 GiB).
- Failure probe: 15/15 rows, zero API errors, median 919 ms.

The diagnostic probe was predeclared from Q5/Q6 failures and is not an independent benchmark. Q8 repaired the Russian invoice identifier and several multilingual failures, proving that precision is a real quality variable. It still dropped the endpoint/requirements scope in `en-two-item-dev-v1b-005` and flattened several requested English lists. Under the one-smoke/one-full hard-stop rule, Q8 was not promoted to another full run because the smoke still contained meaning damage.

Decision: Q5, Q6, and Q8 are all still one universal offline model and therefore pass the architecture/download gate. None of these old-prompt-trained artifacts passes the quality gate. The prompt-aligned universal training run remains the next controlled candidate; if its BF16 result is promising, its exact Mac artifact should start at Q8 for safety and then test whether a smaller quantization is non-inferior.

### TRAIN-005 - Prompt-aligned universal Gemma completed

Timestamp: 2026-07-15 03:57 EDT

Status: training complete; checkpoint rejected after development evaluation

Valid run: `gemma4e4b_multilingual_listv2_aligned_v1` on AlienSV RTX 4090. The run started from the clean Gemma 4 E4B base and reused the exact 5,836-row low-dose multilingual corpus and predeclared hyperparameters from `TRAIN-003`. The controlled change was training/inference prompt parity: both used list-v2.

- Data SHA-256: `31a610847b412868580fc95b1fdb5b4b50900bfc61e07a94e2009ebcccd0a0d2`.
- Prompt SHA-256: `aaedd651c23e8be935d077a2409380abd7803474c0cbce415ab416f038af7c75`.
- QLoRA: rank 16, alpha 32, two epochs, 730 steps, effective batch 16, seed 1265, response-only loss.
- Training elapsed: 1,504.982 seconds (25.08 minutes); trainer runtime 1,530.315 seconds.
- Final aggregate training loss: 0.0217933.
- Adapter directory: 179,089,899 bytes (about 171 MiB including tokenizer/config files).
- Merged FP16 directory: 16,024,814,477 bytes.

The full training manifest is preserved at `docs/experiments/eg1-multilingual/alien-runs/aligned-runs/training-manifest.json` with SHA-256 `cb4a76949f748d09a3d24772242692ae23a7e45e21fc0e4c3bc5b52eb286430a`.

This experiment passes the founder's deployment-shape gate because it remains one universal offline model. Its adapter size also confirms that the fallback architecture remains plausible: one shared base plus roughly 171 MiB for this rank-16 adapter, not another full multi-gigabyte model.

### EVAL-008 - Prompt-aligned Gemma development rejection

Timestamp: 2026-07-15 03:57 EDT

Status: checkpoint rejected; no quantization, exact-Mac, or frozen run

The prompt-aligned candidate completed error-free BF16 runs on the 20 audited English two-item cases, 16 Russian development cases, 56 multilingual probes, and the older 100-positive/100-restraint list corpora. The larger remainder run had already started and completed while independent adjudication of the smoke was still in flight. Once the independent result arrived, the hard-stop rule was applied and the checkpoint was not promoted to Mac or frozen evaluation.

English two-item independent score:

| Model | List behavior | Meaning safe | Cleanup | Grammar | Damaging | Strict |
|---|---:|---:|---:|---:|---:|---:|
| Previous Gemma + list-v2 | 15/20 | 20/20 | 4/20 | 18/20 | 0 | 4/20 |
| Current EG-1 + list-v2 | 19/20 | 15/20 | 9/20 | 18/20 | 5 | 4/20 |
| Prompt-aligned Gemma + list-v2 | 12/20 | 19/20 | 5/20 | 19/20 | 1 | 4/20 |

Aligned versus previous Gemma was 2 strict wins, 2 losses, and 16 ties; exact McNemar p=1.0. Aligned versus current EG-1 was 4 wins, 4 losses, and 12 ties; p=1.0. The new damaging failure was `en-two-item-dev-v1b-007`, where the model removed the required same-day word `today` from medical discharge instructions. It repaired `v1b-005` scope loss but over-applied numbering in other cases and did not improve strict quality.

Russian independent score:

| Model | Meaning safe | Cleanup | Grammar | Damaging | Strict |
|---|---:|---:|---:|---:|---:|
| Previous Gemma + list-v2 | 15/16 | 12/16 | 15/16 | 2 | 12/16 |
| Current EG-1 + list-v2 | 11/16 | 8/16 | 12/16 | 6 | 6/16 |
| Prompt-aligned Gemma + list-v2 | 15/16 | 14/16 | 15/16 | 1 | 14/16 |

Aligned versus current EG-1 was 8 strict wins, 0 losses, and 8 ties; exploratory exact McNemar p=0.0078. It correctly preserved `АВ-204`, respected the requested numbered list, and kept ordinary prose out of a false list. Remaining failures included malformed `пять новых заявок` meaning and retained filler. This is a strong Russian development signal but cannot override the new English medical damage or establish release quality.

Decision: keep the Russian training signal, reject this exact universal checkpoint, and change the multilingual/list data mix before another controlled run. A universal multilingual model remains the preferred architecture; the result rejects this recipe, not the one-model product requirement.

### BENCH-004 - Old list headline contaminated; fresh overflow check launched

Timestamp: 2026-07-15 03:57 EDT

Status: mechanical score complete; independent semantic audit running

An exact-overlap audit found that the older English list benchmark was not genuinely held out:

- positive list corpus: 80/100 inputs exactly present in training;
- restraint corpus: 80/100 inputs exactly present in training.

Those earlier 100-case results are now downgraded to contaminated development evidence and must not decide model or prompt selection.

Two fresh 100-row overflow corpora were created from different inputs, with zero exact input overlap against all 5,836 training rows: one positive-list set and one prose-restraint set. A deeper provenance audit then found only 72 unique origin families per set and 57/72 origin IDs present in training. The rows are therefore paraphrase-robustness checks, not clean held-out generalization. They are also generated/not native-reviewed, so they cannot be frozen or release evidence. A genuinely new model-blind scenario corpus is still required.

Mechanical list-line scoring across four valid single-universal-model configurations:

| Configuration | Positive activation | Intended line count | False lists |
|---|---:|---:|---:|
| Current EG-1 + shipped prompt | 63/100 | 59/100 | 0/100 |
| Current EG-1 + list-v2 | 83/100 | 77/100 | 3/100 |
| Previous Gemma + list-v2 | 87/100 | 82/100 | 1/100 |
| Prompt-aligned Gemma + list-v2 | 67/100 | 63/100 | 0/100 |

The prompt-aligned training recipe regressed paraphrased list activation, corroborating the two-item result. Previous Gemma + list-v2 has the strongest mechanical shape score, but no configuration is promoted until an independent reviewer checks meaning, cleanup, grammar, damage, paired outcomes, and corpus-gold quality. Even a clean semantic result here cannot prove held-out quality because of the origin-family exposure. Raw scores are preserved at `docs/experiments/eg1-multilingual/alien-runs/overflow-runs/STRUCTURE-SCORES.json` with SHA-256 `5ce3f0fc63e8882333054fbc37fe4b0caab6c9f715536963faaba1b93424cfda`.

### BASE-RUN-004 - Universal clean-base bakeoff

Timestamp: 2026-07-15 04:04 EDT

Status: GPU inference and mechanical scoring complete; semantic scoring pending

AlienSV ran untouched Qwen3-4B-Instruct-2507, Qwen3.5-4B with thinking disabled, and Gemma 4 E4B through the same model-blind development suites. The 56 multilingual cases used strict-v1; the 20 audited two-item cases and 200 overflow paraphrase cases used list-v2. All 828 generations completed without an inference error. Each candidate is a valid one-universal-model architecture.

Mechanical list results:

| Untouched base | Overflow activation | Intended line count | False lists | Two-item mechanical strict |
|---|---:|---:|---:|---:|
| Qwen3 4B | 1/100 | 1/100 | 0/100 | 2/20 |
| Qwen3.5 4B | 0/100 | 0/100 | 0/100 | 1/20 |
| Gemma 4 E4B | 0/100 | 0/100 | 0/100 | 1/20 |

The clean bases generally returned inline prose despite the explicit list-v2 instruction. This is strong task-specific evidence that prompt wording alone is insufficient for reliable list formatting and that supervised list examples materially teach the behavior. The conclusion is limited to these prompts and development corpora; the overflow scenario-family contamination still applies.

The clean-base choice must therefore be judged mainly on language/meaning safety and tunability, then paired with a stronger, genuinely held-out list-training experiment. Independent semantic scoring of the 56 multilingual and 20 two-item outputs is pending before the base ranking changes.

### EVAL-009 - Independent overflow semantic audit

Timestamp: 2026-07-15 04:09 EDT

Status: complete; aligned checkpoint rejected, corpus quarantined from held-out claims

Independent model-assisted review scored all eight 100-row paraphrase-robustness output files and audited the corpus itself. All output files were complete, unique, non-empty, error-free, and development-only. No frozen rows were inspected.

Corpus provenance and quality findings:

- Exact normalized training overlap is 0/100 for both positive and restraint rows.
- Each set has only 72 origin families; 28 origins are used twice.
- 57/72 origin IDs per set occur directly in training, covering 80/100 positive rows and 82/100 restraint rows.
- Unsafe or ambiguous gold was found at positive IDs `024`, `038`, `049`, `097`, `098`, and `100`, plus trap IDs `005`, `020`, `082`, `083`, and `093`.

These rows require correction or quarantine. The benchmark cannot become frozen evidence merely by changing the input wording.

Independent semantic score:

| Configuration | Positive strict | Restraint strict | Combined strict | Total damage | False lists |
|---|---:|---:|---:|---:|---:|
| Current EG-1 + shipped prompt | 58/100 | 99/100 | 157/200 | 8 | 0 |
| Current EG-1 + list-v2 | 75/100 | 96/100 | 171/200 | 12 | 3 |
| Previous Gemma + list-v2 | 82/100 | 98/100 | 180/200 | 9 | 1 |
| Prompt-aligned Gemma + list-v2 | 62/100 | 98/100 | 160/200 | 9 | 0 |

Paired positive-list results:

- Current list-v2 versus shipped: 19 wins, 2 losses, 79 ties; exploratory exact McNemar p=0.000221.
- Aligned Gemma versus previous Gemma: 2 wins, 22 losses, 76 ties; p=0.0000359.
- Aligned Gemma versus current list-v2: 7 wins, 20 losses, 73 ties; p=0.0192.
- Previous Gemma versus current list-v2: 12 wins, 5 losses, 83 ties; p=0.143, so the observed five-point strict advantage is not statistically established.

A one-vote-per-origin sensitivity check preserved the first three conclusions. An independent cross-review scored Gemma/aligned positive strict as 82/64 instead of 82/62 because of ambiguous shared-modifier gold; the aligned regression remained 19 paired losses to one win and highly significant. The exact aligned rate should therefore be reported as 62-64% scorer sensitivity, not false precision.

Important failures included splitting natural compounds such as `laptop charger` and `billing copy`, losing the shared `Collect` scope, fusing separate books into `Dune Foundation`, and producing the garden path `coffee heading to checkout`. Current list-v2 improved activation but created three false lists and the most observed total damage. Previous Gemma is the best observed BF16 arm here, but it still has nine damaging rows and cannot be promoted on contaminated development evidence.

Decision: reject the prompt-aligned checkpoint, keep the previous Gemma training direction as a hypothesis, and build a genuinely new model-blind list/restraint corpus before another weight experiment or release claim.

### DATA-004 - Original list-training distribution explains the weakness

Timestamp: 2026-07-15 04:12 EDT

Status: complete; next data recipe constrained

A direct structural scan of the original 5,656 training rows counted outputs with at least two Markdown list lines:

| List-line count | Training rows |
|---:|---:|
| 2 | 3 |
| 3 | 179 |
| 4 | 25 |
| 5 | 30 |
| 6 | 2 |
| 7 | 19 |
| 8 | 1 |
| **All list-formatted outputs** | **259/5,656** |

Only three original examples teach a two-item list. All three are distilled founder-style dictations; none provides systematic coverage across short/long, explicit/scoped, medical, technical, personal, work, and legal contexts. Three-item lists dominate 179/259 formatted rows.

The same training file contains 80 `LF-*` positive-list IDs and 80 `LFT-*` restraint IDs. Those are the exact 80/100 overlaps found in each old benchmark, explaining how the previous headline could look strong without measuring family-level generalization.

Decision for the next universal training dataset:

- balance two-, three-, five-, and seven-item positives rather than adding more of the already dominant three-item shape;
- pair every activation family with equally diverse prose-restraint families;
- include explicit bullets, explicit numbering, scoped implicit tasks, bare labels, corrections, compound items, shared modifiers, and source-wide scope;
- keep medical/legal timing and attribution preservation as hard safety strata;
- exclude every development/frozen benchmark family from training, not merely exact wording;
- preserve English replay and balanced German/French/Spanish/Russian language strata so list gains cannot erase core polish quality.

This is stronger evidence for targeted data rebalancing than for simply scaling the same distribution to hundreds of thousands of rows.

### BASE-RUN-005 - Independent universal-base semantic ranking

Timestamp: 2026-07-15 04:18 EDT

Status: development audit complete; Gemma is the safety-first discovery finalist

An independent reviewer scored the untouched Qwen3-4B-Instruct-2507, Qwen3.5-4B, and Gemma 4 E4B outputs from `BASE-RUN-004`. All candidates remain valid one-universal-model architectures. This is model-assisted development evidence, not native-reviewed or frozen release evidence.

Aggregate 56-case multilingual result:

| Untouched base | Same language | Meaning safe | Cleanup | Grammar | Damaging | Strict |
|---|---:|---:|---:|---:|---:|---:|
| Gemma 4 E4B | 56/56 | 55/56 | 29/56 | 49/56 | 1 | 29/56 |
| Qwen3.5 4B | 56/56 | 54/56 | 32/56 | 52/56 | 5 | 28/56 |
| Qwen3 4B | 54/56 | 52/56 | 28/56 | 45/56 | 7 | 26/56 |

Strict outcomes were statistically tied on this small development set: Gemma versus Qwen3.5 was 7 wins, 6 losses, 43 ties (exact McNemar p=1.0); Gemma versus Qwen3 was 10/7/39 (p=0.629); and Qwen3.5 versus Qwen3 was 7/5/44 (p=0.774). The safety difference is still operationally important because the release rule does not average away damaging rows.

Per-language strict counts out of eight were:

| Language | Gemma | Qwen3.5 | Qwen3 |
|---|---:|---:|---:|
| German | 5 | 8 | 6 |
| Spanish | 4 | 4 | 3 |
| French | 4 | 4 | 6 |
| Portuguese | 1 | 0 | 0 |
| Hindi | 4 | 2 | 3 |
| Japanese | 5 | 5 | 3 |
| Chinese | 6 | 5 | 5 |

Portuguese was the shared weakest language, while Qwen3.5 led the German slice and Qwen3 led French. These eight-case slices are diagnostic only and require native review before language-priority claims.

On the 20 audited English two-item cases, Gemma had 19/20 meaning safety, one damaging row, and 4/20 strict. Qwen3.5 had 18/20 meaning safety, two damaging rows, and 1/20 strict. Qwen3 had 13/20 meaning safety, seven damaging rows, and 3/20 strict. None is usable without targeted list training.

Decision: promote untouched Gemma as the safety-first universal-base discovery finalist; retain Qwen3.5 as a reserve challenger because of its German and grammar strength; drop untouched Qwen3 from the next universal training lane. This is a training-experiment ranking, not a release-model selection.

### ARCH-003 - Shared-base LoRA storage and runtime switching proof

Timestamp: 2026-07-15 04:33 EDT

Status: fallback storage and single-adapter loading proven; simultaneous multi-adapter isolation is not release-safe in the bundled server

AlienSV converted the untouched Qwen3-4B-Instruct-2507 base and the current EG-1 rank-16 checkpoint into separate GGUF artifacts. Both were copied to the Mac and hash-verified.

| Artifact | Bytes | Approximate size | SHA-256 |
|---|---:|---:|---|
| Shared Q5_K_M base | 2,889,512,096 | 2.69 GiB | `325015990807c0459552e3d611db47ae9cfe1119c56b7a000d4f30122119bc6b` |
| Current EG-1 F16 LoRA GGUF | 66,095,424 | 63.0 MiB | `74debfe032f6734c11c8e6220bf5cd38b63fa2581c8e0d554be260b7af4ca2df` |
| Qwen multilingual-smoke F16 LoRA GGUF | 66,095,360 | 63.0 MiB | `b96473a89f488d134b69e2ed0233c8f05a0bdfd8d5e9854c2847231d1dc149f5` |

The LoRA GGUF is about half the 126.1 MiB PEFT safetensors file and 2.29% of the shared base download. This directly proves the founder-approved fallback storage shape: one full model plus small adapters, not one full model per language.

The exact app-bundled `llama-server` (build `fdb1db8`) loaded the base plus one adapter with the shipped Mac flags and exposed the offline `/lora-adapters` switch. With only the current adapter loaded, scale 0 matched a truly adapter-free base byte-for-byte on all 20 candidate texts. Scale 1 changed all 20 candidate texts, proving that the adapter was actually switched rather than merely listed.

| Runtime configuration | Exact-two-bullet structure | Required phrases | Forbidden phrases absent | Strict |
|---|---:|---:|---:|---:|
| Shared base, adapter scale 0 | 10/20 | 2/20 | 16/20 | 2/20 |
| Shared base, adapter scale 1 | 19/20 | 4/20 | 11/20 | 2/20 |
| Existing merged EG-1 Q5 | 18/20 | 4/20 | 8/20 | 2/20 |

The existing adapter clearly teaches list activation, but it also loses required meaning or introduces forbidden wording, so it remains rejected as a quality candidate. The merged Q5 and base-plus-LoRA outputs are not equivalent, which shows that merge/quantization order is part of the release artifact and must be benchmarked separately.

Two distinct 63 MiB adapters were then loaded together. The global endpoint switched between them and changed 9/20 candidate texts; switching back to the first adapter reproduced its dual-loaded output byte-for-byte. However, isolation failed: with both adapters at scale 0, 12/20 outputs differed from the truly adapter-free base, and the current adapter's dual-loaded output differed on 8/20 rows from the same current adapter loaded alone. An inactive scale-0 adapter therefore still affects deterministic generation in this exact bundled build.

Additional runtime caveats: the bundled build did not honor per-request adapter selection in this probe; the global offline endpoint did work. A deliberately excessive scale-100 stress probe caused runaway generation and was terminated, so production switching must restrict adapter IDs and scales to approved values such as 0 or 1.

Decision: one shared base plus small adapters is a valid download/storage fallback. Simultaneously preloading multiple adapters and treating scale 0 as clean isolation is rejected for the current bundled server. The safe fallback prototype is to start or restart the local server with exactly one selected adapter; observed model load was about 0.55-1.18 seconds, still fully offline. A newer runtime may later restore true hot-swapping, but it must prove inactive-adapter parity first. This does not beat the preferred one-universal-model path, and no language adapter is approved until it passes the same held-out, native-review, safety, and exact-Mac gates.

### ARCH-004 - Adapter memory cost and upstream check

Timestamp: 2026-07-15 04:53 EDT

Status: exact-Mac idle memory measured; no upstream fix assumed

The exact bundled server was restarted three times with identical base, context, flash-attention, and Q8 KV-cache flags. Measurements were taken after readiness and before inference, with warm filesystem cache.

| Loaded configuration | RSS | Delta from base | `vmmap` physical footprint | Readiness |
|---|---:|---:|---:|---:|
| Q5 base only | 4,178,240 KiB | - | 1.3 GiB | 766 ms |
| Base + one 63 MiB adapter | 4,259,104 KiB | 80,864 KiB (79.0 MiB) | 1.3 GiB, 1.4 GiB peak | 697 ms |
| Base + two 63 MiB adapters | 4,324,256 KiB | 146,016 KiB (142.6 MiB) | 1.4 GiB, 1.5 GiB peak | 733 ms |

Each additional rank-16 F16 LoRA therefore adds roughly its file size to idle resident memory, with low sub-second warm-load overhead. The RSS absolute value includes mapped model pages and differs from Apple's physical-footprint accounting, so the within-run deltas are the relevant comparison.

Storage projection using the measured Qwen artifacts: base plus one adapter is about 2.75 GiB; base plus four non-English adapters is about 2.94 GiB; base plus five adapters is about 3.00 GiB. Five separate copies of the 2.69 GiB full model would be about 13.45 GiB and remains categorically disqualified.

The bundled llama.cpp commit is `fdb1db877c526ec90f668eca1b858da5dba85560` from 2026-07-02. Upstream `master` was 161 commits ahead at the time of this check, but none of those commit subjects mentioned LoRA and no matching public issue was found for inactive scale-0 adapter interference. That is not evidence of a fix. Do not upgrade the runtime or promise seamless hot-swapping until the same pure-base/single/dual parity probe passes on a candidate build.

### DATA-005 - Low-dose multilingual smoke coverage audit

Timestamp: 2026-07-15 04:57 EDT

Status: complete; smoke-data claims narrowed

The 5,836-row smoke corpus contains the original 5,656 rows plus exactly 180 additions:

| Language | Added rows |
|---|---:|
| German | 40 |
| Spanish | 40 |
| French | 40 |
| Russian | 40 |
| English | 20 |

The 20 English additions are ten explicit-list and ten ordinal-list rows. Each non-English language has only three to six rows in each of nine broad categories: filler/correction, explicit list, implicit list, list trap, morphology preserve, morphology repair, ordinal list, preservation, and punctuation.

All 180 additions list `source: claude-sonnet-4-6` and `native_reviewed: false`. They have category and family labels but no domain or high-risk safety stratum. The non-English share is 160/5,836 (2.74%), or only 40 rows (0.69%) per target language.

Decision: the completed low-dose experiments are valid directional screens for base and recipe behavior, but they cannot answer whether a carefully balanced, native-validated universal model will work. The next data-dose experiment must not reuse this tiny synthetic-only mixture as evidence against the universal architecture.

### STAT-002 - Sample-size interpretation tightened

Timestamp: 2026-07-15 04:59 EDT

Status: benchmark protocol updated before frozen data exists

Wilson interval calculations make the current evidence limits concrete:

- 144/160 (90%) development strict has a 95% interval of 84.4-93.8%; it cannot establish a 94-95% release claim.
- 288/320 (90%) frozen strict has a 95% interval of 86.2-92.8%.
- 304/320 (95%) frozen strict has a 95% interval of 92.0-96.9%.
- Zero critical failures in 320 rows leaves a one-sided 95% upper bound of about 0.93% per case; zero in all 1,600 leaves about 0.19%.

Paired McNemar power depends on the observed current-versus-candidate disagreement rate. The protocol now requires a blinded development pilot power calculation and expansion before frozen sealing when a five-point net change would have less than 80% power after five-language correction. Frozen sample size cannot change after model results are seen.

### HARNESS-005 - Multilingual V2 corpus and native-rating gates implemented

Timestamp: 2026-07-15 05:16 EDT

Status: model-blind tooling complete; no real or frozen corpus authored

The V2 validator, corpus schema, rating schema, tests, and specification now mechanically enforce the release protocol before any candidate output is seen:

- exactly 160 development and 320 frozen rows per language across English, German, French, Spanish, and Russian;
- all 16 behaviors and five domains, with every behavior-by-domain cell fixed at two development and four frozen rows per language;
- whole-family split isolation, matched list-activation/restraint contrasts, at least 80% native-original authoring, independent native validation for every frozen row, and normalized Unicode leakage screening;
- pinned training, prior-evaluation, and blocked-family sources plus exact, token, character, and embedding leakage receipts;
- two distinct blinded native initial ratings for every frozen case/model, third-reviewer adjudication for every axis or severity disagreement, and at least 10% repeated ratings globally, per reviewer, and per language/model arm;
- recomputation of every corpus-derived benchmark-manifest field and exact binding of the rating manifest to that benchmark manifest.

Independent main-thread validation passed Python compilation, both JSON schemas, CLI help, and the complete evaluation test discovery: 36/36 tests passed. The tests use synthetic fixtures only. No real candidate output or frozen benchmark content was opened.

### DATA-006 - D1 universal multilingual training-data builder implemented

Timestamp: 2026-07-15 05:17 EDT

Status: allocation and fail-closed export gate complete; no D1 examples authored or trained

The D1 contract deterministically allocates 2,000 training families: 400 each for English, German, French, Spanish, and Russian. Each language receives 120 core-polish, 140 positive-list, and 140 matched-restraint rows. Positive lists balance two, three, five, and seven items; list type, domain, length, difficulty, safety, and restraint axes are explicitly checked.

Training export remains impossible in the checked-in state. It requires all 2,000 rows to receive independent human-native approval, a sealed blocked-family registry covering old training/evaluation and the new benchmarks, passing exact/token/character/embedding leakage receipts bound to current artifact hashes, prompt-hash parity, and explicit training approval. Release export has a separate approval and forbids the development-only prompt.

Main review fixed two fail-closed issues before acceptance: draft reports can never claim training eligibility, and actual numbered-versus-bullet marker shapes must match the allocated list type. Python compilation, contract/registry JSON parsing, and 8/8 focused tests passed. No examples were generated and no training started.

### ARCH-005 - Download gate made loophole-proof

Timestamp: 2026-07-15 05:18 EDT

Status: hard gate clarified after independent architecture audit

The earlier phrase `multiple full-size models` was directionally correct but undefined. It could be evaded by renaming a complete per-language model as compact, regional, optional, or an adapter. The gate now rejects any design where one user must install more than one complete base-weight set to enable any two claimed languages. Shards of one base count together as one base; a permitted adapter must be delta-only, cannot duplicate the base tensors, and cannot run independently as a complete model.

Universal Tier A remains preferred. Shared-base-plus-adapter Tier B enters finalist ranking only after the predeclared universal data-dose ladder fails or plateaus. Download ranking now uses the complete five-language footprint, not base-only or the smallest selected-language package. At measured Qwen sizes, base plus one adapter is about 2.75 GiB and base plus five same-sized adapters is about 3.00 GiB; five separate full models would be about 13.45 GiB and is never scored.

The audit also corrected the runtime oracle. A future multi-adapter implementation must prove that all-inactive output equals the pure base and one-active multi-loaded output equals that adapter loaded alone, byte-for-byte. The merged GGUF is a separate release artifact because merge and quantization order can change output.

### BASE-RUN-005 - Untouched Ministral 3 3B Instruct control

Timestamp: 2026-07-15 05:35 EDT

Status: complete; reject Ministral from this tuning lane

AlienSV downloaded the official BF16 `Ministral-3-3B-Instruct-2512` checkpoint and ran it without tuning as an untouched Instruct-checkpoint control. It is a valid one-universal-model architecture and its registry Q5 artifact is approximately 2.30 GiB. It is not described as a base-pretrained model.

The generic Hugging Face runner initially failed because `AutoModelForCausalLM` does not load `Mistral3Config`. The runner now detects `model_type=mistral3` and uses `Mistral3ForConditionalGeneration` plus `MistralCommonBackend`; the existing Qwen and Gemma path is unchanged. A controlled prompt confirmed that the official and bundled tokenizer paths produced identical token IDs. The isolated `mistral-common` environment did not mutate the shared training environment.

All 92 requested development generations completed without an inference error: 56 multilingual cases, 20 English two-item list cases, and 16 Russian cases. Raw output SHA-256 receipts are `4d904e48c8307991656eb42a4b46ea8dfca1d8e04072210a34982e2ad84d0415` for the multilingual 56, `b675dd3762049a71ccc3ee8e9b294c7780d49142df1ea24e46a5e6601032534c` and `5bdb9c6a67d8efa312d3b7dcb2700621410f7a9da134b84b3aa9e160a3f6ddc8` for the two English halves, and `e500987ddca138c3335732cf3fff38dd1cc7f8cd65ffbd9887cc79363e67673e` for Russian. The exact inference-runner SHA-256 was `e023cb200470768aaee384d8c9f61fa5359d62bdc7fc4561cae7dd985d31fa8a`.

The English deterministic result is weak: 11/20 had the requested visible structure, only 1/20 preserved every required phrase, 19/20 avoided the forbidden phrases, and just 1/20 was strict. The Russian deterministic result was 10/16 required-span pass, 14/16 forbidden-span pass, 15/16 structure pass, and 7/16 strict. The generic multilingual scorer displayed 56/56 because those older rows do not contain its `required` and `categories` fields; that number is invalid as a quality metric and is excluded from every comparison.

The independent model-assisted reviewer then scored all 92 outputs without consulting any other model's scores. Strict results were 30/92 overall, 24/56 on the multilingual set, 5/16 Russian, and 1/20 English two-item lists. Meaning was safe on 61/92, requested cleanup completed on 48/92, and only 47/92 avoided a damaging extra edit. Thirteen multilingual rows carry uncertainty flags because this is not native review; none are needed to explain the decisive English failure. All 92 IDs, strict-AND calculations, failure reasons, and four raw input hashes validated.

Decision: reject untouched Ministral 3 3B Instruct from the next tuning lane. Its smaller 2.30 GiB registry Q5 is attractive, but size cannot rescue 1/20 strict English list behavior or the observed meaning/edit damage. Do not spend a training run on it unless later native evidence invalidates this development audit.

### STAT-003 - Frozen size changed from fixed to power-driven

Timestamp: 2026-07-15 05:48 EDT

Status: harness corrected before any real or frozen V2 corpus exists

The original V2 validator fixed frozen size at 320 rows per language. That supports per-language rate estimation, but it does not automatically provide 80% paired power for a five-point improvement after five-language correction. Unconditional power calculations for the two-sided exact conditional McNemar/binomial test at worst-case `alpha=0.05/5=0.01` found, when the nuisance discordance rate is treated as known:

| Frozen rows per language | Power at 10% disagreement | Power at 20% disagreement | Power at 30% disagreement |
|---:|---:|---:|---:|
| 320 | 55.8% | 24.4% | 14.8% |
| 480 | 80.5% | 41.4% | 25.5% |
| 640 | 92.4% | 57.2% | 36.9% |
| 960 | 99.2% | 79.99% | 57.9% |

At a known 20% nuisance rate, the first balanced size that truly clears rather than rounds to 80% is 1,040 rows per language (`k=13`, 83.8% power). The release planner is more conservative because development estimates that nuisance rate. It takes the largest simultaneous 95% Bonferroni-Wilson upper endpoint across all five languages. A raw 16/160 discordance rate in each language becomes 16.89% for sizing and selects 880 rows per language (`k=11`).

The exact finalist is selected and hashed on development before sizing. A separate custodian emits only aggregate pair and discordance counts per language, with case-level outcomes and arm direction withheld. The planner validates the actual balanced 800-row development corpus and recomputes its manifest, binds the aggregate receipt to the exact current/finalist artifact and evaluation-config hashes, and saves deterministic JSON. Release validation recomputes the plan and pins every source hash. Frozen native ratings additionally require two generation receipts whose unordered artifact/config pairs match the locked comparison. The chosen `k` cannot change after either model sees frozen data.

### STAT-004 - Independent harness audit closed fail-open paths

Timestamp: 2026-07-15 06:18 EDT

Status: complete; 54/54 evaluation tests pass

An independent code audit challenged the statistical harness before any V2 frozen data existed. It found and closed fail-open paths around caller-declared hashes, a fabricated development manifest, visible case-level development outcomes, point-estimate sizing, generation receipts, and a final comparison-binding tamper.

The sealed workflow now recomputes the actual balanced 800-row development manifest, uses only aggregate arm-blinded disagreement counts, takes the largest simultaneous Bonferroni-Wilson upper endpoint, locks the exact baseline/finalist artifact and evaluation-config pairs, and requires both frozen generation receipts to match those pairs. The final regression proves that editing the benchmark manifest to swap a model hash and supplying matching generation receipts still fails because the manifest binding must equal the independently recomputed power plan.

Validation receipts prove internal hash consistency. They do not independently hash model, evaluation-config, or generation-output files supplied outside the validator. Production frozen receipts must therefore come from the trusted generation harness or an independent custodian, not be hand-written.

### RES-008 - Multilingual tuning literature supports mixed universal data, not blind scale

Timestamp: 2026-07-15 06:19 EDT

Status: research complete; adjacent-task evidence, not EG-1 proof

Primary-source findings:

- [Liu and Niehues, MRL 2025](https://aclanthology.org/2025.mrl-main.23/) found that multilingual forgetting depends strongly on model-to-data scale and instruction-following ability; parameter-efficient tuning did not automatically prevent forgetting.
- [CLiKA, NAACL 2024](https://aclanthology.org/2024.naacl-long.339/) found multilingual instruction tuning can help cross-language alignment, while single-target continued pretraining can improve one language at the expense of others and mixed pretraining reduces that damage.
- [Kunz and Holmstrom, 2024](https://arxiv.org/abs/2402.00149) found target-language adapter effects were inconsistent across tasks, languages, and models. An adapter is therefore a deployment option to test, not an assumed quality win.
- [M-DaQ, 2025](https://arxiv.org/abs/2509.15549) reported gains from selecting multilingual instruction data for both quality and semantic diversity, supporting the current family-diverse/native-review gates rather than raw row-count scaling.

Decision for EG-1: retain the one-universal-model lane with a balanced five-language mixture, English replay, positive-list/restraint pairs, and nested D1-D5 data doses. LoRA remains a practical tuning and storage mechanism, not protection against English or cross-language regressions. Do not jump to 100,000 rows merely because storage and CUDA allow it; advance only when the per-language learning curve improves without English or safety damage. The one-shared-base adapter fallback remains eligible only after that universal learning curve actually plateaus or fails.

### MAC-HARNESS-003 - Exact shipped-request evaluation mode

Timestamp: 2026-07-15 06:47 EDT

Status: independently audited and ready for the short English development run; novel corpus generation still in progress

The active Mac app and its child `llama-server` are healthy. The bundled server, prompt builder, connector, runtime/delivery manifests, and all eight open Q5 shards match the current branch and delivery hashes. The two prompt arms will therefore use one process and one identical base-weight set.

The prior Python runner was a fair raw prompt comparison but omitted four shipped connector rules: per-case `max_tokens`, rejection of `finish_reason=length`, the 20-second transport timeout with one narrow connection retry, and EG-1 preamble/transcript-tag cleanup. A new pure-Python contract mirror and `--eg1-shipped-request` mode now reproduce those request/response rules for controlled evaluation. The renderer also neutralizes embedded transcript tags and records the shipped output-token budget. Exact-mode failures do not enter the generic six-retry loop.

Eleven focused wire/cleanup tests and the full 65-test evaluation suite pass. The test server proves the exact JSON field set, 256-token floor, cleanup behavior, fail-closed handling of truncated HTTP-200 output, rejection of spoofed localhost URLs before any request, and one retry after a physically incomplete response. A parity regression also rejects a malformed later `choices` element because Swift rejects the whole array rather than accepting only a valid first choice. Generic provider artifacts keep their previous schema.

Independent audit found no remaining parity blocker for the intended short US-English benchmark. The exact-mode latency includes the full call and possible 750 ms retry wait inside the logical 15-second pipeline budget. Long non-ASCII inputs deliberately fail closed above the 256-character floor because Python `len` is not Swift `String.count`; any such multilingual release run must obtain the budget from the Swift renderer. The app connector remains release authority; this Python mirror is the exact-request experiment path for the new short English corpus.

### BASE-RUN-006 - Qwen3.5-9B capacity control

Timestamp: 2026-07-15 06:55 EDT

Status: BF16 discovery and blind semantic review complete; stop, do not tune this control

Qwen3.5-9B is the one additional base control, not a new release choice. It isolates capacity within the same family as the 4B reserve. The official Apache-2.0 model claims 201 languages, uses 9B language parameters, and reports higher 9B-versus-4B instruction and multilingual aggregates. The pinned publisher revision is `c202236235762e1c871ad0ccb60c8ee5ba337b9a`; official BF16 weight shards total 19,306,310,880 bytes (17.980 GiB), which fits the RTX 4090 for short-context serial discovery.

AlienSV used a separate native-Windows CUDA environment at `C:\Users\saura\eg1-ml-winvenv` with Torch 2.12.1+cu130, Transformers 5.5.0, and CUDA verification on the RTX 4090. This avoided changing the existing spoken-command environment and followed the native-Windows reliability rule. The five-case smoke passed before the larger runs.

All 392 requested BF16 generations then completed without an inference error: 56 multilingual, 16 Russian, 20 English two-item, and the 200 contaminated overflow development rows. No output was empty and no `<think>` marker leaked. Mechanical list results were:

| Suite | Result |
|---|---:|
| English two-item exact two list lines | 10/20 |
| English two-item all required spans | 1/20 |
| English two-item deterministic strict | 1/20 |
| Russian deterministic strict | 7/16 |
| Overflow positive list activation | 0/100 |
| Overflow positive intended line count | 0/100 |
| Overflow false lists | 0/100 |

The 9B control is more responsive to explicit two-item instructions than the untouched 4B bases, but that visible shape did not survive the deterministic preservation gate: only 1/20 kept every required audited span, and only that same row was mechanically strict. Russian deterministic strict was 7/16, and the model ignored every positive overflow list request. That makes it a useful capacity signal, not a prompt-only solution.

The independent reviewer then scored the 92 clean discovery rows without opening another candidate's artifacts. Aggregate strict was 40/92, meaning was preserved on 78/92, cleanup passed on 60/92, grammar/punctuation passed on 87/92, and 15/92 had a damaging extra edit. Suite strict was 31/56 multilingual, 7/16 Russian, and 2/20 English two-item. Of 23 list-applicable rows, only 11 had correct list behavior. All ten explicit English requests became bullets, but none of ten scoped implicit cases did; eight explicit outputs dropped important scope or identity, including patient, medical timing, estate, and contract context.

Priority-language strict slices were German 7/8, French 4/8, Spanish 3/8, Russian 7/16, and English 2/20. Portuguese, retained as an extra diagnostic language, was 0/8 because every row kept filler or correction traces. On the shared ML56 set, 9B's 31 strict passes slightly exceeded Gemma's 29 and Qwen3.5-4B's 28, but its four damaging rows were worse than Gemma's one, and its English result was worse than Gemma's 4/20. Capacity therefore did not yield a safe, broad improvement.

Decision: stop the Qwen3.5-9B lane after its smoke and full development benchmark. Do not spend a tuning run on it with the current data. It remains a valid one-universal-model architecture, so this rejects the capacity-only hypothesis, not the founder's one-model requirement. Reconsider only if the balanced native-reviewed data program later provides evidence that justifies the larger Mac/runtime cost.

Repository artifact SHA-256 receipts, after normalizing Windows CRLF transport endings to LF without changing any JSON content, are `c018a97e87d895fdecf425a6e09f8212b9a0f1774ff3170327853b98612484ea` for multilingual 56, `e539a73c2f024207148d9537bfbbe7a88ef6fdeec17f7e82df43a7cddfdf0ac5` for Russian 16, `d6bf474f34ef404117eebf8520950144c422ec767f3d418a55b2528e886c6b0f` and `3714854057ad3bbda0d28e036594c1301c4c03935a2e697d74eb505e809e4262` for the two English halves, and `ce08e264b251dc2ecd6a1420fe3a6ab107d6bdb8d45c2333312ce148a39f77fc` / `d65e60b0cf49aa86424237fc421a5a3ee6a5b13e65011076e80ebb3d4480ca10` for the positive/restraint overflow sets. The independently reviewed row content did not change; its hash bindings were updated to the normalized repository artifacts. The review SHA-256 is `8c48793f3b8474adc08e791d33997bb7207e527848a6745aa1706aff0ea5565a`, and its strict formula and aggregate recount independently validated. The normalized official download-manifest SHA-256 is `a0ae287f2bcf13525137aeb617335697aab5ce96205b1629b34350529545f298`.

### BASE-RUN-007 - Untouched Phi-4-mini universal control

Timestamp: 2026-07-15 07:13 EDT

Status: full development audit complete; reject from tuning lane

The official [Microsoft Phi-4-mini-instruct model](https://huggingface.co/microsoft/Phi-4-mini-instruct) is MIT-licensed, 3.8B parameters, and explicitly eligible for English, German, French, Spanish, and Russian. The pinned publisher revision is `cfbefacb99257ffa30c83adab238a50856ac3083`; official snapshot weights total 7,672,066,216 bytes (7.145 GiB) before quantization. This is a valid one-universal-base architecture and therefore passes the founder's download-shape gate.

The first five-case smoke was invalid evaluation evidence. The shared generic runner replaced Phi's official EOS list `[200020, 199999]` with the tokenizer's single EOS `199999`, so all five generations ran to the 256-token cap and repeated or leaked prompt text after emitting `<|end|>`. The invalid smoke is preserved but not scored. A Phi-only compatibility wrapper restored the publisher EOS list; the corrected smoke then completed 5/5 clean.

The untouched corrected model completed all 92 development rows without an empty output. Deterministic evidence was already weak: Russian retained Cyrillic on only 12/16 rows and passed 5/16 strictly; English two-item had visible structure on 12/20 but exact required-span strict on only 1/20. Four Russian rows translated or transliterated out of Cyrillic, one leaked `Language: Russian`, and the invoice code `АВ-204` became `АВ 224`.

An independent reviewer then scored all 92 rows without opening another candidate's artifacts. Semantic strict was 37/92 overall, 18/56 multilingual, 8/16 Russian, and 11/20 English two-item. Meaning was preserved on 76/92, but 26/92 had a damaging extra edit; list behavior was correct on 14/23 applicable rows. Priority-language strict was English 11/20, German 5/8, French 6/8, Spanish 2/8, and Russian 8/16. Additional diagnostic slices were Portuguese 0/8, Hindi 1/8, Japanese 2/8, and Chinese 2/8. Severe failures included translation away from the source language and corruptions such as `AB204` to `AB224`, `1.6/1.8` to `0.6/0.8`, `PR184` to `8404`, and `1540` to `15`.

The semantic/exact-span difference on English is itself useful: Phi often preserved the broad intent with paraphrases, so semantic review credited 11/20 where the literal audited-span scorer credited 1/20. That is why no single automated metric decides the lane. The 26 damaging rows, cross-language translation, and entity/number corruption independently reject the model even under the more forgiving semantic rubric.

The generic runner now preserves the publisher's configured EOS value or list and falls back to tokenizer EOS only when the model declares none. Three focused contract tests and the full 68-test evaluation suite pass. An isolated AlienSV smoke with the fixed shared runner recorded `[200020, 199999]`, completed 5/5 clean, and matched the compatibility-wrapper output strings 5/5, so the 92-case outputs did not need rerunning.

Decision: stop after one corrected smoke and one full development benchmark. Do not tune, quantize, or move Phi-4-mini to the exact-Mac lane. This rejects Phi on current task evidence, not the one-universal-model architecture. No frozen outputs were opened. After CRLF-to-LF repository normalization, the control receipt SHA-256 is `2b6ea573c22527d821e1b9ff254723e9d68d9a69d8f9eb7e83354a205528aa47` and the independent review SHA-256 is `d077485634a4b71374281f5a610dbe600bb0aefbc7550c3dc6f8b5380f65d720`.

### BASE-RUN-008 - Untouched EuroLLM-9B universal control

Timestamp: 2026-07-15 07:26 EDT

Status: rejected at smoke; fail-closed stop applied

The official [EuroLLM-9B-Instruct-2512 model](https://huggingface.co/utter-project/EuroLLM-9B-Instruct-2512) is Apache-2.0 licensed and covers 35 languages, including English, German, French, Spanish, and Russian. It was tested only as one universal offline model. It never represented or justified a separate full model per language.

The pinned publisher revision is `1acaaeb8d9e8d9b5e3bf0240aacd32fc11ee4213`. AlienSV independently rehashed all 29 snapshot files: 18,322,965,727 bytes total and 18,304,683,360 bytes of BF16 weights, with no missing or undeclared files. The shared runner and generation-contract hashes matched the committed copies, and the publisher EOS token `4` was preserved.

The untouched five-case Spanish smoke produced five unique, nonempty outputs and retained Spanish on all five. However, 2/5 outputs leaked `<CLEANED_TEXT>` and/or `<TRANSCRIPT>` wrappers. One of those repeated the complete transcript framing instead of returning only polished text. The predeclared fail-closed smoke rule therefore prohibited the multilingual 56, Russian 16, English two-item 20, scoring, tuning, quantization, and exact-Mac lanes. This rejects EuroLLM-9B on raw-output safety, not the founder's one-universal-model architecture.

All artifacts are LF-normalized. SHA-256 receipts:

- control receipt: `651d8bcdd9245ad6659cfef6212998674f731348c41a16313e3b51074dcaa333`
- official snapshot manifest: `dde616e0bf218d5ec2b57808748527446283d7c208b5bf2b2912043ca38241de`
- raw smoke outputs: `04ba18bb0aa00ecb28c2de8d72b28648b31c361df0102a93d0d2efb8a9ff4dbc`
- smoke run manifest: `1802c555586640ad1b7ced391d8f094701c924769b892ef2d0ef0264a7035a0c`

### LIST-PILOT-001 - Model-blind 75+75 development pilot predeclaration

Timestamp: manifest created 2026-07-15 07:19 EDT; committed before any EG-1 prompt-arm output was generated

Status: immutable selection anchor; corpus generation and leakage validation still in progress

The directional English list pilot is predeclared as the first 75 accepted checkpoint-order cases in each of two lanes: positive lists and matched prose restraints. Selection used no current-EG-1 or prompt-variant output. The 150 selected slots balance five real-use domains, two-to-five-item shapes, short-to-extended inputs, and compound versus non-compound cases. The remaining 25 slots per lane are reserved for the later 100+100 corpus and cannot be substituted into this pilot based on model behavior.

This is development evidence only. The manifest explicitly records `frozen: false`, `native_reviewed: false`, and `training_eligible: false`. Model generation remains prohibited until both 75-case source lanes exist and a separate portable validation receipt passes exact/fuzzy family leakage checks. The sealed manifest contains Mac-absolute audit paths and must not be edited; the later receipt will add portable repo-relative bindings while preserving these exact hashes:

- sealed manifest SHA-256: `7d7831eb14406f15c1e9c12cbdf98e3d198b370ee5623cfa9a565307d08dd174`
- canonical pilot-definition SHA-256: `5a7cb24ef6fe61f7f67cee66338fc0a4adcf1da16697ff31e2c10f6faf50ca04`

### RUNTIME-SEC-001 - Local server credential rotation

Timestamp: 2026-07-15 07:35 EDT

Status: contained and rotated

A process-list diagnostic printed the active local llama-server command line into tool output, which included its ephemeral API credential. The credential value is deliberately omitted from this log. The owning EnviousWispr local app was terminated and relaunched immediately. The prior local endpoint was verified closed; the replacement server was verified ready, bound only to `127.0.0.1`, with a fresh credential present. Future process checks must select PID, readiness, host, port, and credential presence without printing the full command line.

### RUNTIME-SEC-002 - Proxy-safe exact-Mac launcher

Timestamp: 2026-07-15 07:48 EDT

Status: implemented; independent re-review clean

The first redacted launcher draft found the app-owned llama-server without printing its credential, but independent review found that copying the shell environment could preserve `HTTP_PROXY` or `ALL_PROXY`. Python may not bypass those proxies for `127.0.0.1`, so an exact-Mac request could have sent the bearer credential to a configured proxy. No benchmark was run through that draft.

The corrected launcher uses a minimal child environment containing only the ephemeral credential and explicit loopback `NO_PROXY` values. Exact request mode also constructs a proxy-disabled HTTP opener, so the transport remains local even if the wrapper is bypassed. A poisoned-proxy integration test proves the exact request still reaches the loopback fixture. The launcher now additionally requires an explicit app-bundle path, proves the child and parent belong to that exact bundle, requires model ID `eg-1`, validates `-c 16384 -fa on --cache-type-k q8_0 --cache-type-v q8_0`, checks authenticated `/health` HTTP 200, and refuses to overwrite an existing or symlinked output path.

The explicit live preflight passed against the already-verified `EnviousWispr-5b` local app without printing the credential. Focused security and exact-wire tests passed 19/19; the full evaluation suite passed 76/76. The sealed list corpus has not yet been sent to either prompt arm.

Independent re-review found no remaining issue: the credential does not enter argv, logs, proxy settings, or inherited Python configuration; app identity, parentage, flags, authenticated health, model ID, and exact-mode proxy bypass all fail closed.

### SCORE-AUDIT-001 - Novel English list scorer adversarial audit

Timestamp: 2026-07-15 07:57 EDT

Status: three false-pass paths fixed; independent re-review clean

The independent scorer audit opened no corpus rows or model outputs. It found that an inference error or empty restraint output could receive no-list and forbidden-cleanup credit; a fused two-item bullet plus one fabricated unmatched bullet could pass atomicity; and an empty slice reported a fake 0% Wilson interval instead of no observation.

The scorer now requires a nonempty, error-free inference before any success metric can pass. It records inference failures, explicit candidate errors, and empty outputs separately and excludes inference failures from damage proxies. Atomicity requires both each audited item to appear on exactly one line and each list line to contain exactly one audited item. Zero-row slices report `rate: null` and `wilson_95: null`. Positive-list strict success, restraint false-list rate, and restraint strict success are explicitly co-primary; the combined paired comparison is labeled diagnostic-only and cannot become a headline percentage. Existing scorer outputs cannot be overwritten.

Focused scorer tests pass 14/14 and the full evaluation suite passes 79/79. Independent re-review reproduced the three fixed edge cases, rechecked Wilson math and exact two-sided McNemar, and found no remaining code issue.

### STAT-LOCK-001 - English list pilot decision rule

Timestamp: 2026-07-15 08:07 EDT

Status: predeclared before prompt-arm output

The 75+75 development pilot is intentionally underpowered for a five-point lift and cannot prove the 2.5% release false-list ceiling. The decision contract now requires at least eight net positive-list strict wins plus exact paired `p < 0.05`, zero new restraint false-list regressions, no increase in audited item/scope loss, zero new arm-blind semantic meaning damage, and zero inference failures. Positive and restraint remain co-primary; no combined headline is allowed. Passing only advances a prompt to a larger native-reviewed/frozen evaluation.

The contract binds the sealed selection, corrected scorer, and canonical power implementation by SHA-256. It records representative Wilson intervals and exact paired power before outputs exist. The full contract is `docs/experiments/eg1-multilingual/ENGLISH-LIST-PILOT75-DECISION-CONTRACT-V1.md`.

### LEAKAGE-AUDIT-001 - Portable assembler stopped before publication

Timestamp: 2026-07-15 08:58 EDT

Status: 75+75 checkpoints complete; first leakage pass clean; publication blocked pending code fixes

The model-blind generator accepted all 75 selected positive cases and all 75 selected restraint cases. Restraint generation used 15 five-case checkpoints. Three first attempts were rejected before checkpointing: one duplicate semantic-family label in batch 6, one invalid forbidden span in batch 7, and another duplicate family in batch 8. Each unchanged automatic retry passed. No candidate model output was generated.

The first full portable input/output cross-field leakage pass completed without a collision. During its independent written-byte revalidation, a separate code-only audit found proof-layer defects: the assembler did not recompute the claimed first-N selection; source and checkpoint paths had validate-then-reopen timing windows; multi-file overwrite-capable publication could leave a partial bundle; relocated checkouts could not replay absolute sealed paths; and the receipt hardcoded one claim while omitting important assembly parameters and coverage evidence.

The active validation process was terminated before publication. No final corpus, receipt, or model output exists. Accepted checkpoints and transaction bytes remain preserved. The required next sequence is fixed: patch all findings with integration tests, independent re-audit, rerun the complete two-pass leakage validation, publish the receipt last as the exclusive commit marker, independently audit the final receipt, and only then allow exact-Mac prompt generation.

### LEAKAGE-AUDIT-002 - Hardened assembler re-audit

Timestamp: 2026-07-15 09:11 EDT

Status: independent code re-audit clean; full validation rerun authorized after commit

The rewritten assembler proves the sealed first-N selection by regenerating the full deterministic specification sequence, recomputing the canonical definition hash, validating the excluded suffix/distributions/flags, and binding the expected manifest and generator hashes. Audit sources and checkpoints are read once, hashed and parsed from the same bytes, snapshotted byte-for-byte, reparsed, and rehashed. The portable receipt contains computed comparison counters, field-pair coverage, cross-batch/cross-role evidence, per-axis maxima with provenance, batch ID, assembly parameters, and only repository-relative paths.

Publication is now one exclusive bundle. Existing output fails closed; pre-receipt failures clean only files created by that invocation; the receipt is written last as the commit marker. Sixteen targeted tests cover first-N/definition/flags, all three fuzzy axes, cross-field/cross-batch/cross-role screening, family aliases, mutation, exclusive publication and cleanup, portable replay, and required receipt fields. Independent re-audit found no remaining issue.

Sequencing exception: the sealed generator remains byte-exact at `ead3e1b9cbd6b9dad65092296de33e2c5baec716598b008d69d2bae2e8890a3b` for this one assembly because its validator functions are active but its overwrite-capable generation writer is not invoked. Changing it now would invalidate the sealed prompt/checkpoint contract. Its general output writers must be patched to exclusive mode immediately after the audited bundle is published, under a new recorded hash.

### TYPE-B-001 - Broad 1,890-case litmus-test leakage audit

Timestamp: 2026-07-15 09:41 EDT

Status: old Type B and overflow sets rejected as held-out evidence; scale and balance retained as the replacement target

Founder requirement: every viable EG-1 version must continue to face a broad approximately 1,800-case Type B litmus test. Cases used in training must be replaced with overflow or genuinely fresh families. The 75+75 English list pilot is only a fast directional diagnostic and cannot replace this broad gate.

The shipping training authority is `scripts/eval/runs/bakeoff-1265/train_sft_v2.jsonl`: 5,656 rows, SHA-256 `5afc6b9435c7bef08df17ba3c4edcb889b8329cd7c1520c49d681999a666f568`. It contains all 3,036 v1 rows plus 2,620 later rows. Source counts are 1,549 Type B, 1,487 founder, 1,924 distilled, and 696 targeted.

The audit reproduced exact ID and casefold/space-normalized input overlap of 1,549/1,890 in `type_b_approved_1890.jsonl`. Conservative NFKC, casefold, and punctuation-insensitive comparison finds 1,551/1,890. Provenance-family components expose 1,866/1,890 approved rows. The separate 900 overflow rows have zero exact input/output overlap but 899/900 belong to an exposed Type B family. The nine category overflow files are partitions of those same 900 rows, not additional supply.

Only 23 rows are provisionally mechanically reusable: 22 approved rows plus `SCT-OF-003`. They are not yet fully held out because the other 4,107 founder/distilled/targeted training rows lack complete family metadata and still require blind semantic-family comparison. Preserving the original Type B composition therefore requires 1,867 new model-blind families: 298 trap and 1,569 non-trap, distributed across the original 17 categories and four length buckets.

Decision: retain the 1,890-case scale and original category/length/trap balance, but rebuild the content. Create semantic-family IDs before text, use one benchmark case per family, split authorship from review, block every training family, and apply exact normalized text, token/character n-gram, explicit family-graph, embedding-neighbor, and blind human-family gates. No paraphrase, localization, or origin-family variant of an old Type B/training row is eligible. Seal the replacement before candidate output and never substitute rows after seeing scores.

This audit resolves a stale provenance claim. The old knowledge statement that training had zero input overlap with the full 1,890 incorrectly generalized the protected hard-340/overflow check to the working Type B set. The current 1,549/1,890 finding is correct under its stated normalization; conservative normalization finds 1,551.

### AB-PREFLIGHT-001 - Prompt-pilot execution blocked and hardened

Timestamp: 2026-07-15 09:42 EDT

Status: no pilot model output generated; V2 sealing work in progress

Independent preflight rejected the first proposed A/B path before model output. It found that any metadata-valid 75+75 files and two prompts could create a green-looking render receipt; two single-arm invocations did not prove the same server stayed alive; general runner/scorer writes were overwrite-capable; the baseline inference-health gate was missing; filename order could define arm direction; no opaque semantic packet existed; and connector-wire output was being described too broadly as final app output.

The replacement V2 path binds the portable assembly receipt, exact corpora, raw and model-visible prompts, code hashes, decision contract, and clean Git commit. A single dual-arm orchestrator snapshots the sealed prompts, authenticates once, proves the same PID/parent/app/endpoint/credential privately before and after both arms, and publishes explicit baseline/candidate outputs with a receipt last. Both arms must have zero errors and empty outputs. Output creation is exclusive. A receipt-bound scorer computes every mechanical advancement condition with explicit direction. A separate per-case randomized packet and sealed mapping support arm-blind semantic review. This remains connector-wire exact only; paste-equivalent claims require the later app-level `validatePolishOutput` fallback path.

### LEAKAGE-AUDIT-003 - Portable 75+75 corpus published

Timestamp: 2026-07-15 10:00 EDT

Status: complete; both internal passes and independent full recomputation clean

The hardened assembler completed both written-byte passes and published one exclusive bundle with its receipt last. No candidate model output was generated or opened. The bundle contains 75 positive-list and 75 prose-restraint rows, 30 checkpoint snapshots, and nine source snapshots covering 8,307 source rows / 16,614 source texts. Each internal pass performed 5,028,900 comparisons. Maximum observed similarity stayed below every gate: sequence `0.741117 < 0.82`, token `0.545455 < 0.78`, and character four-gram `0.462069 < 0.75`.

The immutable hashes are:

- positive corpus: `107915d52ba6b60a15b52b620db82278d1d3aff14471483c479b4e98675739e2`
- restraint corpus: `e067e46c079e317fd49b4e9364c15f6e7a60ed35532587893b3830c4d987d57b`
- publication receipt: `13f2bc1026526a4f37b6a376437aa5e6e21d76cd300a764d897632be3712937b`

Independent audit found all 41 pre-receipt members present, no extras or symlinks, exact receipt-bound hashes, receipt mtime last, exact checkpoint/spec lineage, 150 unique IDs and families, zero source-family collisions, and zero cross-case normalized duplicate text. The 60 same-case restraint input/gold duplicates are intentional. Its separate full recomputation completed all 5,028,900 comparisons with zero exact or high-similarity violations and reproduced every maximum and relation count byte-for-value: 4,984,200 sealed-source, 22,500 cross-role, 21,000 cross-batch, and 1,200 within-batch comparisons. The shipping 5,656-pair training file is fully contained in the audited 5,836-row superset. The corpus is cleared for unreviewed development rendering; the V2 contract remains the sole execution block.

After the immutable bundle published, the general generator writers were changed from overwrite-capable output to atomic exclusive publication. The receipt correctly retains the historical generator hash `ead3e1b9cbd6b9dad65092296de33e2c5baec716598b008d69d2bae2e8890a3b` used for this corpus; commit `fa5b9cf8` preserves those bytes. The hardened live generator is `cf6031efc4e572e3cb4393e8f3798d5a577a80232fe348c164e52d54f205a8dc`. This is recorded code evolution, not corpus mutation.

### EVAL-SEAL-001 - Executable V2 evidence chain

Timestamp: 2026-07-15 10:10 EDT

Status: code complete and synthetic tests green; contract intentionally still pending; no prompt-arm output generated

The V2 contract is now executable rather than descriptive. Rendering, the same-server Mac orchestrator, deterministic A/B scoring, blind packet construction, and semantic unblinding all parse the same exact binding map, reject pending/missing/extra/duplicate/altered bindings, and prove a two-commit chain: one code/data anchor plus one contract-only binding commit. The same canonical hashes are rechecked before evidence appears.

Blind review uses a private random 256-bit seed by default and independently balances each 75-case lane 38/37 across opaque labels. Judgment schema, uniqueness, and complete 300-judgment coverage must pass before the private mapping is read. Private mapping publishes first; the public packet receipt publishes last with cross-binding. Candidate semantic regression now means a meaning-damaging edit at higher severity than baseline; harmless S1-versus-S0 cleanup differences do not fail the gate. Direct reports use atomic exclusive publication, so a short write cannot leave a truncated final evidence file.

Focused evaluator validation and the complete evaluation suite pass 158/158 unittest-discovery tests, plus 181 pytest tests and 14 pytest subtests, including pending/altered/duplicate contract rejection, wrong-live-model rejection, same-server before/after checks, inference health, paired threshold boundaries, blind-label balance, no-early-unblind read spies, transaction cleanup, preservation-metadata type rejection, evidence-overwrite rejection, generation-output hashing, live leakage revalidation, duplicate-prompt rejection, exact header positioning, and the exact 1,890-slot Type B manifest. The contract remains deliberately `PENDING` until this code/data anchor is committed; model execution is prohibited before the contract-only child commit.

### TYPE-B-002 - Replacement manifest contract

Timestamp: 2026-07-15 10:10 EDT

Status: deterministic 1,890-slot manifest builder and tests complete; fresh case authorship not started

The replacement gate preserves exactly 1,890 cases rather than shrinking to a convenient diagnostic. It reserves 23 provisional legacy/overflow slots for manual family review and 1,867 fresh-family slots. The original 17-category counts, length buckets `480/482/468/460`, tiers `900/292/698`, and trap balance `1,590/300` are exact. Every slot has a preassigned unique family ID, separate author/reviewer lanes, candidate output disabled, and training eligibility disabled. Source hashes and final manifest bytes are receipt-bound; injected receipt failure removes the partial bundle. This is the construction contract only. The eventual questions still require model-blind authorship, semantic-family screening, and review before the Type B V2 set can be frozen.

### EVAL-SEAL-002 - Final proof-layer and live-model hardening

Timestamp: 2026-07-15 10:34 EDT

Status: four independent audit findings fixed and re-audited; exact-Mac artifact gate passed; no prompt-arm output generated

A final code-only audit found four proof-layer defects before any model output: a partial one-byte receipt could survive a failed publish; generator parsing and hashing could observe different reads; the historical sealed generator was proven only by a synthetic test rather than immutable bytes; and the live server identity named `eg-1` without proving the exact weight shards. All four were fixed and the frozen re-audit passed eight focused tests.

Both renderer and A/B publisher now remove their entire new bundle after any receipt-write failure, including an injected one-byte short write. Corpus and audit-source hashes are computed from the exact captured bytes that are parsed. The sealed generator is preserved as the real immutable snapshot `scripts/eval/historical/generate_eg1_english_list_benchmark.ead3e1b9.py`, whose SHA-256 is exactly `ead3e1b9cbd6b9dad65092296de33e2c5baec716598b008d69d2bae2e8890a3b`; the hardened live generator is `7eee13f4bf14609f4e748ed4cab71ff6ade211688d85fddbcbfde51b0e1282bf`.

The Mac wrapper now reads the app delivery manifest, proves its entrypoint, size, and SHA-256 for all eight open Q5 shards under stable file metadata, and carries the complete artifact identity through every same-server check and receipt. The canonical and live app manifest both hash to `3d7a09f3dc91a6f891dd74ec64c3992e99e75793d3875d085ea87754033a6624`. That hash is now also an executable decision-contract binding, so a different live EG-1 artifact fails before either arm runs. Direct negative tests prove the renderer rejects a changed manifest binding, the orchestrator never calls either arm or publishes output when the live manifest differs, and same-length shard tampering reaches and fails the content-hash branch rather than only the size check.

The required committed-diff review then found one broader P2: the multilingual power planner could accept the same artifact/config pair as both baseline and finalist under two opaque labels. The comparison validator now rejects identical pairs before sizing or sealing, with a regression test that rebinds the comparison receipt to an intentionally identical pair. The fix remained covered as the suite later grew; current validation passes 158/158 unittest-discovery tests, plus 181 pytest tests and 14 pytest subtests.

### TYPE-B-003 - Fresh-family authorship and custody protocol

Timestamp: 2026-07-15 10:38 EDT

Status: read-only design audit complete; no fresh Type B text or candidate output generated

The 1,890-case Type B V2 set is reserved for one finalist confirmation pass, not prompt or adapter iteration. The 75+75 pilot and separate development panels remain the tuning surface. If any Type B V2 rows are opened repeatedly, they must be predeclared as development rows and cannot be described as held out.

Before wording, every fresh slot receives a language-neutral scenario card covering domain, register, difficulty, ASR/disfluency shape, risk, required entities/numbers/timing/scope, prohibited edits, behavior/trap, and secondary behaviors. Family, scenario, and template IDs are assigned before prose. Authorship must use at least eight distinct human/source identities; target at least 50% human/native-original scenarios, at least three genuinely different synthetic generator families for the remainder, no synthetic provider above 20% overall or 25% within a category, and mixed 12-16 case batches rather than category blocks.

Every row requires separate semantic/minimal-edit and family/leakage reviewers. A stratified 15-20% sample is double-coded, while medical, legal, financial, and other high-risk rows are double-reviewed in full. A wave stops for rubric repair and re-review when raw agreement is below 95% or reliability is below 0.80 in any stratum. Leakage gates cover exact normalized text, explicit origin/family graph, token and character similarity, embeddings, and blind human neighbor adjudication against training, all old benchmarks, the 75+75 pilot, multilingual sets, and D1. Provider, author, template, n-gram, and embedding-tail diversity are reported before sealing.

Co-primary confirmation outcomes are non-trap strict success, trap false-positive rate, and semantic meaning damage as a hard gate. Paired candidate comparisons use exact McNemar and paired intervals; rate estimates use Wilson intervals; 17 category cuts are secondary and use Holm correction for confirmatory claims. AlienSV handles heavy clustering, leakage scans, BF16 training, and LoRA bakeoffs in isolated workspaces; the Mac remains custodian and exact shipping-runtime authority. AlienSV was confirmed reachable over Tailscale as `saura@aliensv`, with the RTX 4090 online and 22,982 MiB free at this checkpoint.

### PRIVACY-001 - Private corpus publication incident and containment

Timestamp: 2026-07-15 11:18 EDT

Status: public feature branch scrubbed; local corpus restored and verified ignored; no main-branch exposure from this work

The confirming diff review found that an earlier overnight commit had force-added the private founder-derived training mixture under `docs/experiments/eg1-multilingual/`. This violated the repository rule that private founder and tuning corpora stay ignored and that only aggregate counts, hashes, and safe synthetic evidence may be published. The review also identified personally identifying content inside that file. Its contents are intentionally omitted from this log.

All pushes and model runs stopped immediately. The remote feature branch was rewritten from the repository root with that path removed from every reachable commit, verified commit-by-commit, and force-updated from old tip `fa5b9cf8` to sanitized tip `67d5cc9d`. The active local branch was then rewritten by the same filter. The exact local corpus was backed up, restored byte-for-byte, verified ignored, and verified absent from the Git index. The branch remains blocked from any further push until the rest of the review findings pass a confirming review.

No pull request or other named GitHub ref points at the old branch history. A read-only API check nevertheless confirms that the now-unreachable original commit object is still temporarily addressable by its exact SHA, which is normal for GitHub object retention after a force-push. Permanent cache/object purge requires a private GitHub Support request and is not safe to initiate without founder authorization. Do not put the corpus details or identifying values in a public issue.

### EVAL-SEAL-003 - Partial benchmark runs now fail automation

Timestamp: 2026-07-15 11:20 EDT

Status: confirming-review P2 adopted; full suite passes; confirming review pending

The confirming review found that `subset_polish_runner.py` preserved error rows but still returned exit code zero after exhausted retries, truncation, or empty output. That allowed a direct shell workflow to treat incomplete evidence as successful. The runner now writes the inspectable output and summary first, then exits with code 2 whenever any row carries an error. The exact-wire test helper now asserts the expected process return code, and the truncated-output regression proves both the preserved error row and nonzero exit. Focused validation passes 12 tests plus seven subtests. The earlier `172 plus 14 subtests` report was a valid pytest count before later regressions were added; the apparent discrepancy came from comparing pytest with unittest discovery. Current validation passes 158/158 unittest-discovery tests, plus 181 pytest tests and 14 pytest subtests.

### GIT-HISTORY-001 - Privacy scrub graph repair

Timestamp: 2026-07-15 11:34 EDT

Status: repaired and verified; public branch is private-corpus-free and based on current main

The emergency `git filter-branch --prune-empty` scrub removed the private corpus but also collapsed unrelated historical commits, leaving the feature branch with an invalid merge base and a misleading 1,151-commit diff. The named review was stopped because that graph made its scope invalid.

The repair replayed exactly the 23 overnight commits from the original `08803450` base onto current `origin/main` `12ce8700` in an isolated worktree. At the one commit that introduced the private corpus, the file was removed before recreating that commit; every rebuilt commit was then checked to prove that path was absent. The corrected public branch was force-updated from the collapsed tip `67d5cc9d` to clean tip `01d596b9`. The reviewed anchor patch was applied byte-for-patch onto that clean history as temporary local commit `846f0d75` before these final audit notes were folded into the same code anchor. The branch remains exactly 24 overnight commits ahead of current main and one commit ahead of its public remote. The discarded local graph was deleted only after stable patch IDs proved the anchor change was identical.

### LEAKAGE-AUDIT-004 - Historical-generator proof bundle

Timestamp: 2026-07-15 11:35 EDT

Status: complete; both internal passes and independent full recomputation clean; no model output generated

The second 75+75 assembly completed both internal 5,028,900-comparison passes and published local ignored bundle `scripts/eval/corpus/eg1_english_list_pilot75_v2_bundle`. Receipt SHA-256 is `131cc84898db829859aa6d73940df8685882adeedb76057a050231bcf3efc000`; positive corpus SHA-256 is `1fffba6215670a9a1cfd3cb723d39a6ee479b9dfbae47224aa8ed04a7520baee`; restraint corpus SHA-256 is `e44cdceb4a1eca8ea2b90528af170897021218b506122f9d9952546495055e21`. Both passes reproduce sequence `0.741117 < 0.82`, token `0.545455 < 0.78`, character four-gram `0.462069 < 0.75`, and relation counts 4,984,200 sealed-source, 22,500 cross-role, 21,000 cross-batch, and 1,200 within-batch comparisons. The real historical generator snapshot proof is present and matched.

Comparison against the first bundle found identical row counts, ID order, and every semantic field across all 150 cases. Every similarity score is also identical. The byte hashes differ only because 94 `similarity_audit.nearest_source` strings name the new bundle directory. The bundle contains nine audit-source snapshots, including the private 5,836-row training superset with 1,487 founder-derived rows. Therefore the entire bundle and receipt remain gitignored and will not be force-added; only safe aggregate hashes and counts appear in tracked documentation and the later executable contract.

The independent replay verified all 41 pre-receipt members with zero missing, extra, or hash-mismatched files; nine of nine source snapshots; 30 of 30 checkpoints; all 150 first-N lineage mappings; and the historical generator fallback proof. Its actual matcher completed exactly 5,028,900 comparisons with zero exact-overlap or high-similarity violations and reproduced both receipt passes byte-for-value: 4,984,200 sealed-source, 21,000 cross-batch, 22,500 cross-role, and 1,200 within-batch comparisons, with maxima `0.741117`, `0.545455`, and `0.462069`. The focused independent audit suite passed 20/20. This closes the final corpus-side execution block.

### MAC-PREFLIGHT-004 - Exact shipping-path readiness rechecked

Timestamp: 2026-07-15 11:45 EDT

Status: ready but still sealed; no prompt rendering or model output generated

The live machine has exactly one `EnviousWispr` app process and one child `llama-server`. Their executable paths resolve to `/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-5b/build/EnviousWispr Local.app`; the server parent is the verified app process. The app-embedded `eg1-delivery-manifest.json` is byte-identical to `Sources/EnviousWispr/Resources/eg1-delivery-manifest.json`, both SHA-256 `3d7a09f3dc91a6f891dd74ec64c3992e99e75793d3875d085ea87754033a6624`. The fail-closed preflight also authenticated locally and verified the complete sharded model artifact against that manifest without generating a completion. No bearer value was printed or retained. The sealed orchestrator will repeat the same artifact proof before and after both arms when execution is finally authorized by the contract-only child commit.

### EVAL-SEAL-004 - D1 preservation metadata now fails closed

Timestamp: 2026-07-15 11:54 EDT

Status: named-review P2 fixed; focused and full suites pass; confirming review pending

The required named committed-diff review found that the future D1 multilingual training exporter checked only for preservation-check keys. Malformed values such as `null`, booleans, empty strings, or any truthy high-risk timing value could therefore pass into an approved training export. The gate now requires meaning, entity, number, timing, attribution, and compound-scope checks to be lists containing only nonempty strings; meaning must contain at least one requirement; unknown check fields fail; formatting must be one of `bullets`, `numbered`, or `prose` and must match the allocated stratum/list type; and high-risk timing/attribution must be valid nonempty lists. The new malformed-metadata regression passes with the full focused D1 suite, 9/9 tests; current complete validation passes 158/158 unittest-discovery tests, plus 181 pytest tests and 14 pytest subtests.

### EVAL-SEAL-005 - Final evidence inputs now fail closed

The next required named committed-diff review found three evidence-chain gaps: the final rating gate trusted shaped leakage hashes without reopening the sealed inputs; the CUDA experiment runner could truncate a prior result at a reused output path; and its manifest did not hash the generated JSONL. The rating command now requires the live leakage sources and receipt, reruns exact-leak checks and full receipt validation, and compares the current inventory and receipt hash with the sealed benchmark manifest. The runner rejects either result or manifest collisions before loading the model, uses exclusive creation for both files, and writes the closed output's SHA-256 into its manifest. New regressions prove leakage drift is rejected, prior evidence is never overwritten, and output mutation is detectable from the manifest hash.

### EVAL-SEAL-006 - Structure and dispatch identities fail closed

The next confirming review found two older fail-open paths in the broader evaluation toolkit. The legacy two-item scorer discarded line positions, so two bullets followed by `Note:` could pass as if the note were a leading header. It now accepts only a bare two-bullet list or one header followed by exactly two bullets. A full-class audit then found and repaired the same position-loss shape in the primary 75+75 scorer. The shared subset runner also keyed results by case ID without first rejecting duplicate input IDs, which could overwrite a failed result and emit the surviving row twice. It now rejects invalid or duplicate prompt IDs before any network dispatch. Five regressions cover both scorers, bare lists, valid leading headers, trailing prose/header rejection, and pre-network duplicate rejection.

### TYPE-B-004 - Slot allocator versus frozen-benchmark gap audit

Timestamp: 2026-07-15 11:54 EDT

Status: read-only audit complete; authorship remains correctly blocked

The current 1,890-row builder is a deterministic fail-closed slot allocator, not yet an authoring, leakage, review, freeze, or scoring pipeline. Its pinned four source hashes and counts match live bytes; its focused tests pass 3/3; and no durable Type B V2 output bundle exists. Before official slot publication it still needs schema/code/commit binding, receipt-pinned joint cells and fresh trap counts, deterministic and source-drift negative tests, and 23 same-cell replacement reserves for any provisional rejection. Before prose authoring it also needs the sealed blocked-family registry, scenario-card/authorship schema, provider and reviewer custody, Type B-specific validation and leakage receipts, exclusive private freeze publication, and a receipt-bound exact-Mac runner/scorer/blind-review path. The safe next action is to harden those contracts before generating the 1,867 fresh families; candidate outputs remain prohibited from Type B V2 until the one locked finalist confirmation.

### MAC-AB-001 - Fresh 75+75 shipped-runtime prompt comparison

Timestamp: 2026-07-15 12:56 EDT

Status: complete; list-aware prompt rejected

The exact shipped EG-1 Q5 artifact completed 150 baseline and 150 candidate requests sequentially through one authenticated Mac app server. Both arms had zero request failures and zero empty outputs, and the orchestrator proved the same server and delivery-manifest identity before and after each arm. The A/B receipt SHA-256 is `5cc171aacb79682bba8237dbdcf3a3e78681df8ebe2f065e7c1f0b1d51bdaba0`.

The list-aware prompt increased positive-list activation from 52/75 to 68/75, but strict positive success rose only from 11/75 to 15/75. The paired positive gain was four cases, below the predeclared minimum of eight, with exact McNemar `p=0.125`. It also increased restraint false lists from 25/75 to 32/75, including seven candidate-only false lists. Positive item loss worsened from 22 to 23 cases and positive scope loss from 15 to 23. Every mechanical advancement condition except inference health failed.

Three independent arm-blind reviewers then produced 900 judgments. Meaning-damage agreement was 283/300, or 94.3%, with Fleiss kappa `0.747`; exact five-level severity agreement was 245/300, or 81.7%, with Fleiss kappa `0.571`. A predeclared conservative consensus resolved 282 outputs. Eighteen severe or wide disagreements received a fourth arm-blind adjudication before the mapping was opened. The final 300-row judgment SHA-256 is `efdbcb2f32e89edc9d8bcfd036b7526ea5b80772f7de07024791639cb0494564`.

After unblinding, baseline had 8/150 meaning-damaging outputs and the candidate had 12/150. Six cases were candidate-only damage, two were baseline-only damage, and all six candidate-only cases also had higher candidate severity. The semantic report SHA-256 is `365fc67776c0c5f2028a2d17ad77da5a1aff394ea994ee62693c196d2d61605b`. This independently confirms the earlier small-set conclusion: prompt-only list activation is not a safe EG-1 improvement.

### TYPE-B-005 - Allocation and same-cell reserves sealed

Timestamp: 2026-07-15 12:56 EDT

Status: first hardening stage complete; authorship still blocked on family/leakage and freeze contracts

The Type B V2 allocator now reads a tracked allocation contract that pins the exact 17-category by four-length-bucket joint cells, source hashes, 23 provisional IDs, final trap count, and all slot totals. It emits the 1,890 final slots plus 23 separately authored same-cell replacement reserves, for 1,890 fresh-authorship assignments and 1,913 total slot records. Primary and reserve family IDs are globally unique; all rows remain benchmark-ineligible, training-ineligible, and candidate-output-free.

An independent committed-diff review found that file hashes alone did not prove an immutable allocation checkout. The publisher now requires an exact clean Git HEAD, proves both the builder and contract bytes belong to that commit, rechecks the state before receipt publication, and records the commit. The confirming review passed. The live feature-branch receipt is bound to commit `de5b8fbf1a821005fe5014eb61b5d92372f8b2c3` and hashes to `aa125a30fef59b93ee646217aa2002fe819cb00823021386f01064bbc4ba4ad8`.

Sequential validation passes 165/165 unittest-discovery tests and 188 pytest tests plus 14 subtests. Running those two suites concurrently is prohibited: both contain negative tests that temporarily mutate the same canonical decision-contract fixture. A deliberate parallel attempt reproduced the race, the contract hash gate caught the leftover synthetic value, the committed binding was restored exactly, and both suites then passed sequentially with the contract hash unchanged.

### REPLAY-INVENTORY-001 - Cleaned English replay inventory contract

Timestamp: 2026-07-15 14:05 EDT

Status: metadata-first inventory implemented for issue #1557; no row is approved for training and no replacement or export has started

The original 5,656-row EG-1 replay source is now governed by a fail-closed inventory contract. The contract pins the original replay bytes, the exact historical Type B approved, overflow, and combined views, the builder, and the standalone normalizer. The historical combined view must remain the exact disjoint union of the 1,890 approved and 900 overflow rows.

The deterministic decision order blocks any replay row whose normalized input or output collides with either normalized historical Type B field, then quarantines every complete remaining duplicate normalized-input or normalized-output group. All other rows are `candidate_only`; every published row explicitly remains training-ineligible. The independently recomputed aggregate is 1,564 historical-overlap blocks, 4,092 post-overlap rows, 41 additional whole-group duplicate quarantines, and 4,051 candidates, with zero unresolved or training-eligible rows.

Word comparison uses NFKC, Unicode case-folding, and punctuation-insensitive word tokens. If that form is empty, a domain-separated NFKC/case-folded symbol-preserving form is required instead. The live source has exactly one such replay row affecting two fields, zero historical fallback fields, and zero invalid rows; the aggregate above remains unchanged. Empty or whitespace-only values are quarantined, while focused tests cover unique emoji, duplicate emoji, punctuation-only historical collision, and invalid empty content.

The first committed-diff review used a private ignored source row to probe whether underscore was being treated as punctuation and printed that row into local review output. No raw value entered a tracked file, the inventory bundle, Git history, or a remote; the published-bundle privacy intersection remained zero. The value is intentionally omitted here. The probe exposed that Python's original `\w+` expression retained underscore despite the punctuation-insensitive contract. The normalizer now uses Unicode word tokens excluding underscore, the exact rule is contract-pinned, and synthetic-only overlap and duplicate tests cover it. Subsequent review is restricted to synthetic probes and metadata receipts and must not open or print private rows.

Publication is allowed only from the exact declared clean Git commit into an ignored in-repository directory. The tool reopens every source and all tracked bindings before writing `receipt.json` last, refuses overwrite or count/schema/hash drift, removes a partial bundle after failure, and emits only opaque row fingerprints, decisions, reason codes, aggregate metadata, and hashes. It never publishes raw text or raw row IDs. Semantic review, embedding review, replacement authorship, and training export remain separate later gates.
