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
