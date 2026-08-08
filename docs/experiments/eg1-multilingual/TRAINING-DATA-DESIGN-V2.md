# EG-1 Universal Multilingual Training Data Design V2

Status: proposed next training lane. Do not launch until the model-blind development corpus is audited and the founder/CTO approves the data budget.

## Product boundary

The preferred result is one universal offline model for English, German, French, Spanish, and Russian. One byte-identical shared base plus delta-only LoRA adapters is a fallback only if the universal learning curve plateaus below the per-language gates. An adapter cannot duplicate the base tensors or run independently as a complete model. Requiring one user to install more than one complete base-weight set to enable any two claimed languages is disqualified, regardless of whether a package is called compact, regional, optional, or language-specific.

## Why the current distribution is insufficient

The original 5,656-row training set has 259 outputs with at least two list lines. The item-count distribution is badly skewed:

| List lines | Rows |
|---:|---:|
| 2 | 3 |
| 3 | 179 |
| 4 | 25 |
| 5 | 30 |
| 6 | 2 |
| 7 | 19 |
| 8 | 1 |

It also contains 80 `LF-*` and 80 `LFT-*` rows copied directly from the old benchmark. The old 94-95% style headline therefore mixes real learning with train/test leakage and does not estimate family-level generalization.

The first multilingual smoke added only 160 non-English rows, 2.74% of the 5,836-row mixture: 40 synthetic rows each for German, French, Spanish, and Russian, plus 20 synthetic English list rows. Every added row was marked `native_reviewed: false`, and the schema had no domain or high-risk safety stratum. It was a direction screen, not a serious test of universal multilingual capacity. The prompt-aligned Gemma experiment improved Russian but regressed English lists and introduced medical timing damage. That result rejects the exact low-dose recipe, not universal multilingual tuning.

## Data contract

Every row must have:

- a stable semantic-family ID assigned before writing or localization;
- language, domain, behavior, difficulty, and safety-risk labels;
- source and author provenance;
- `native_reviewed` and validator identity/status fields;
- an ASR-style input and one minimally edited gold output;
- explicit required meaning, entity, number, timing, attribution, and formatting checks;
- no semantic/template-family overlap with development or frozen data.

Training and inference use the same exact prompt hash. If list-v2 is the intended contract, all examples—including replay—must be rendered against list-v2. Do not change prompt text, weights, decoding, and data mixture in the same comparison.

## Pilot mixture

Build a 14,656-row first serious pilot before any quarantines/replacements:

- a 5,656-row English replay pool derived from the original set after removing leaked/unsafe benchmark rows and replacing them with independently authored, family-disjoint rows;
- 1,000 new English rows;
- 2,000 new native-language rows each for German, French, Spanish, and Russian.

This yields about 45% English and 13.6% for each other language without repeating a tiny non-English set. Exact counts may move after quarantine, but every replacement must preserve the predeclared strata.

### New English 1,000

| Stratum | Rows |
|---|---:|
| Core polish and preservation | 200 |
| Positive lists | 400 |
| Matched prose restraint | 400 |

### Each non-English language 2,000

| Stratum | Rows |
|---|---:|
| Core polish and preservation | 800 |
| Positive lists | 600 |
| Matched prose restraint | 600 |

Core polish is balanced across filler removal, self-correction, native morphology, punctuation, entity/number/date preservation, names/code-switching, topic shifts, minimal edit, and mixed behaviors. High-risk medical, legal, and financial rows are present in every behavior family rather than isolated in one small bucket.

## List and restraint balance

Within every language's positive-list rows:

- item counts 2, 3, 5, and 7 are exactly balanced;
- explicit bullets, explicit numbering, scoped implicit tasks, bare-label lists, and correction/format-command cases are exactly balanced;
- work/admin, personal/home, technical/product, medical, and legal/financial domains are exactly balanced;
- short, medium, long, and surrounding-context length buckets are exactly balanced.

Every positive semantic family has a separately authored restraint family in the same domain and length range. Restraint types cover incidental enumerations, narrative action sequences, compound objects, quoted content, alternatives/contrasts, shared modifiers, and policy-boundary two-item prose. Positive and restraint pairs must share difficulty, not wording or templates.

Compound nouns and source-wide modifiers are marked explicitly so gold labels cannot split `laptop charger`, `billing copy`, or `evaluation benchmarks`, or attach a shared deadline only to the final bullet. Medical/legal timing, attribution, obligation, identifier, and destination checks are hard gates.

## Provenance and native review

- Native-original target: at least 80% per non-English language.
- Cross-language shared concepts: at most 20%, independently rewritten rather than translated templates.
- Native validation: 100% of medical/legal/financial and morphology rows; at least 20% stratified sample of all other rows before smoke training.
- Before release training, every retained row receives native validation or is excluded from release provenance.
- Synthetic author and critic models cannot be the same model/configuration.
- Reviewer disagreements are adjudicated without seeing model outputs.

## Family separation and leakage controls

1. Assign family IDs before localization or paraphrasing.
2. Allocate whole families to training, development, or frozen splits.
3. Reject exact normalized input/output duplicates.
4. Reject high token, character n-gram, and embedding similarity across splits.
5. Maintain a blocked-family registry containing the old `LF-*`, `LFT-*`, overflow origins, Russian development/frozen families, multilingual probes, and new benchmark families.
6. Re-run the full leakage audit from raw sources after every corpus merge.
7. Hash and seal frozen corpora before candidate training; never inspect frozen outputs during recipe selection.

No row can become safe for training merely by paraphrasing a development/frozen family.

## Staged data-dose experiment

Do not jump directly to 100,000 rows. Measure a learning curve with nested, family-disjoint additions:

| Stage | New multilingual rows | Purpose |
|---|---:|---|
| D1 | 2,000 | Detect whether corrected balance moves list and language gates safely |
| D2 | 9,000 | Run the full pilot mixture above |
| D3 | 25,000 | Test whether quality continues improving after the pilot |
| D4 | 50,000 | Scale only when D3 has a positive marginal gain |
| D5 | 100,000+ | Justified only by an unsaturated learning curve and data-quality capacity |

The row counts are additions before English replay. Each stage is nested by randomly selected semantic families using a recorded seed. Keep optimizer, rank, epochs/tokens, prompt, base, quantization lane, and evaluation constant within the dose comparison. Report both examples and total labeled tokens so longer languages do not silently receive more weight.

## Ablations

Run one bounded smoke and one full development benchmark for each predeclared arm:

1. Core multilingual control with no new list families.
2. Core plus balanced positive lists and matched restraint families.
3. Arm 2 plus the higher data dose only if Arm 2 improves target metrics without English or safety regression.

Do not run a positive-list-only release candidate; it is an intentionally unsafe distribution. The matched-restraint arm tests whether activation can improve without false lists.

The initial base comparison is Gemma 4 E4B as the safety-first finalist versus Qwen3.5 as the reserve challenger. Untouched Qwen3 is dropped from this lane after the broader 56-case semantic audit found the most meaning damage. Use the same training families across bases so data and base effects are separable.

## Reproducibility and statistics

- Training seed for screening: 1265.
- A development finalist must repeat with three seeds before frozen evaluation.
- Report each seed plus the mean/range; do not average away a damaging run.
- Primary comparisons use per-case paired strict outcomes, exact McNemar tests, and paired bootstrap confidence intervals.
- Use Holm correction across English, German, French, Spanish, and Russian primary tests.
- English non-inferiority lower bound must remain above -2 percentage points.
- Report core polish, positive-list activation, false-list restraint, and S0-S4 damage separately.
- The exact quantized GGUF through the bundled Mac runtime is the release authority.

## Promotion and stop rules

A data stage advances only when:

- no new S4 meaning/entity/number/timing damage appears on development;
- English meets the predeclared non-inferiority gate;
- positive lists improve without exceeding the false-list gate;
- at least two target non-English languages improve directionally;
- the improvement survives independent semantic review and is not driven by leaked families.

Stop the lane after one smoke and one full development run when the target metric does not improve or safety regresses. A failed D1 rejects that mixture. It does not prove that a better universal base or higher-quality multilingual corpus cannot work.

Only one predeclared finalist reaches the sealed frozen benchmark and exact Mac release path.
