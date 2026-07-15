# EG-1 Multilingual Benchmark V2 Contract

Status: model-blind authoring and validation contract. No candidate output was used to design this schema. No sealed or frozen corpus content was opened.

This document implements the release-grade shape proposed in `BENCHMARK-DESIGN-V1.md` and the family-separation rules in `TRAINING-DATA-DESIGN-V2.md`. The schemas and validator are the mechanical authority:

- `scripts/eval/multilingual_benchmark_v2.schema.json`
- `scripts/eval/multilingual_benchmark_v2_rating.schema.json`
- `scripts/eval/multilingual_benchmark_v2.py`

## 1. Product boundary

This benchmark may promote only an architecture that keeps multilingual polish offline after download.

- Preferred: one universal multilingual model, even if it is larger than EG-1.
- Allowed fallback only after the universal data-dose ladder fails or plateaus: one byte-identical shared base plus delta-only language LoRA adapters. An adapter cannot duplicate the base tensors or run independently as a complete model. Current evidence supports starting or restarting the server with exactly one selected adapter.
- Disqualified: one user must install more than one complete base-weight set to enable any two claimed languages, regardless of whether a package is called compact, regional, optional, or language-specific.
- Future simultaneous preload or per-request switching must prove two byte-for-byte conditions through the exact bundled runtime: all adapters inactive equals the pure base, and one active adapter in a multi-loaded server equals that adapter loaded alone. A merged GGUF is a separate release artifact, not the adapter-isolation oracle.

Model size is a ranking factor only after the architecture and quality gates pass.

## 2. Model-blind workflow

1. Assign semantic-family IDs before writing, localization, or paraphrasing.
2. Allocate whole families to `development` or `frozen` before authoring rows.
3. Author and validate the five-language matrix without seeing candidate outputs.
4. Pin all leakage inputs and complete exact, token n-gram, character n-gram, and embedding screening.
5. Validate, hash, and seal the frozen corpus before candidate selection.
6. Tune prompts, weights, data mixture, quantization, and decoding on development only.
7. Run frozen once on current EG-1 and one predeclared finalist.
8. Judge the exact quantized GGUF through the bundled Mac runtime.

The frozen corpus cannot be used to choose between several finalists. A second finalist requires a newly authored and newly sealed frozen version.

## 3. Corpus size and strata

The release profile contains 2,400 rows.

| Split | Per language | Five languages | Per behavior and language | Per domain and language |
|---|---:|---:|---:|---:|
| Development | 160 | 800 | 10 | 32 |
| Frozen | 320 | 1,600 | 20 | 64 |

The marginals are not enough. Within every language, each behavior x domain cell contains exactly two development rows and four frozen rows. This prevents one behavior from being tested mostly in an easy domain while another absorbs the high-risk domains.

Languages are English, German, French, Spanish, and Russian. Every language and split contains all five domains:

- work and administration;
- personal and home;
- technical and product;
- medical;
- legal and financial.

Every row also carries a difficulty stratum (`routine`, `challenging`, or `adversarial`) and a safety stratum (`standard`, `medical`, `legal`, or `financial`). The validator requires every difficulty and safety stratum to appear in every language and split. It does not invent an unsupported exact quota for those two axes.

The 16 behavior strata are the V1 matrix:

1. filler removal;
2. self-correction;
3. native morphology;
4. punctuation and capitalization;
5. entities, numbers, and dates;
6. names and code-switching;
7. topic shifts and longer dictation;
8. mixed behavior with two to three edits;
9. explicit two-item list;
10. scoped two-item list;
11. natural three-to-five-item bullet list;
12. spoken ordinals requiring a numbered list;
13. two-item prose restraint;
14. three-plus-item prose restraint;
15. quoted or high-risk instruction restraint;
16. clean or minimal-edit restraint.

The four positive-list behaviors produce 40 development and 80 frozen list-activation rows per language. The four restraint behaviors produce a matched 40 development and 80 frozen restraint rows per language. Core polish, positive lists, and restraint remain separate scoreboards.

At least 80% of each language and split must be native-original. Shared concepts are capped at 20% and must be independently rewritten into natural local speech, not translated from a shared template.

## 4. Whole-family allocation

`semantic_family_id` is assigned before any language version exists. Every row with the same family ID must stay in one split. The validator also requires the family to keep the same domain, behavior, difficulty, safety, and list contract across languages.

These are prohibited:

- one language version in development and another in frozen;
- a frozen family paraphrased into training;
- a development family relabeled as frozen;
- changing a family's behavior or safety class during localization.

A paraphrase never makes a blocked family safe.

## 5. Row contract

Each JSONL row contains:

- stable `case_id` and `semantic_family_id`;
- split, language, domain, behavior, difficulty, and safety labels;
- `contrast_set_id` for every list-activation and matched-restraint row;
- speech-reachable `asr_input` and minimally edited `gold_output`;
- a plain-language meaning requirement;
- explicit entity, number, timing, and attribution preservation arrays, including empty arrays when no named value exists;
- one formatting contract with expected list type, item count, and shared scope;
- source provenance;
- a native author attestation;
- an independent native validator record or `null` while a development draft is still being prepared.

Frozen rows fail closed unless the independent validator:

- is a different person from the author;
- attests native ability in the row's language;
- records independence from the author;
- approves the row.

Rejected validation is not a warning. The row cannot enter a frozen or release corpus.

### List contracts

| Behavior | Required contract |
|---|---|
| Core polish behaviors | `no_list_requirement` |
| Explicit/scoped/natural list | `activate_bullets` |
| Spoken ordinals | `activate_numbered` |
| Restraint behaviors | `restrain_prose` |

Two-item behaviors require exactly two items. Natural bullet lists require three, four, or five. `shared_scope` records a modifier, deadline, destination, attribution, or obligation that must apply to the intended full list rather than only the final item.

Every `contrast_set_id` contains exactly two separately authored semantic families: one positive-list row and one restraint row. They must match on split, language, domain, difficulty, and safety risk. Core-polish rows use `null`. Exact wording remains different so the pair measures the decision boundary rather than template recognition.

## 6. Leakage screening and sealing

The final validator consumes three pinned source roles:

- `training`: every replay, new training row, and training-family registry;
- `prior_eval`: old list sets, overflow origins, multilingual probes, Russian discovery sets, and any earlier benchmark;
- `blocked_family_registry`: family IDs that can never enter V2.

Each source is passed as `ROLE:NAME=PATH`. The validator computes the source SHA-256 and directly fails on normalized input, normalized gold, or family-ID collisions. Exact normalization is Unicode-aware and collapses punctuation or symbol runs to spaces, so punctuation-only rewrites do not evade the exact screen.

Fuzzy screening is performed by the approved leakage scanner before sealing. Its receipt must be bound to the benchmark's canonical content SHA-256 and every source SHA-256. For each source, the receipt must contain passing results for:

- exact normalized matching;
- token n-gram Jaccard;
- character n-gram Jaccard;
- embedding cosine similarity.

Token, character, and embedding thresholds must be declared before scanning. The V2 validator deliberately does not invent threshold values. It checks that the receipt contains the predeclared threshold, maximum observed value, zero violations, and a pass. Any missing method, source, hash, threshold, or receipt blocks frozen validation.

Order of operations:

```bash
python3 scripts/eval/multilingual_benchmark_v2.py content-hash \
  --corpus /absolute/path/to/corpus-v2.jsonl \
  --release-profile

# Run the approved exact, fuzzy, and embedding scanner with predeclared thresholds.
# Its output is leakage-receipt-v1.json, bound to the content hash above.

python3 scripts/eval/multilingual_benchmark_v2.py validate \
  --corpus /absolute/path/to/corpus-v2.jsonl \
  --release-profile \
  --leakage-source training:eg1-training=/absolute/path/to/training.jsonl \
  --leakage-source prior_eval:all-prior-evals=/absolute/path/to/prior-evals.jsonl \
  --leakage-source blocked_family_registry:blocked-v2=/absolute/path/to/blocked-families.jsonl \
  --leakage-receipt /absolute/path/to/leakage-receipt-v1.json \
  --manifest-out /absolute/path/to/corpus-v2.manifest.json
```

The manifest has no clock field or absolute input paths. It deterministically records schema hashes, raw source hash, order-independent benchmark content hash, per-row hashes, family-assignment hash, source hashes, and all split/language/domain/behavior/behavior-domain/difficulty/safety/list counts. The same files and validator version produce the same manifest bytes.

## 7. Blinded native rating contract

Frozen outputs use opaque randomized model labels. Every case and model receives two initial ratings from different native reviewers. A third native reviewer adjudicates every disagreement without seeing the model identity. At least 10% of initial ratings are repeated under a new blind assignment to estimate reviewer consistency. The 10% minimum applies globally, within every native reviewer's assignments, and within every language x model arm so repeats cannot be cherry-picked from one easy slice.

The rating schema requires these ten binary axes:

1. same language;
2. meaning preserved;
3. requested cleanup completed;
4. native grammar and morphology acceptable;
5. entities preserved and none fabricated;
6. numbers preserved and none fabricated;
7. timing preserved and none fabricated;
8. attribution preserved and none fabricated;
9. list activation or restraint contract satisfied;
10. no damaging extra edits.

Strict green is the logical AND of all ten adjudicated axes. There is no partial credit in strict green. Damage severity is reported separately as S0 through S4.

For a row with no named entity, number, timing, or attribution in its requirement arrays, the reviewer still marks that preservation axis. `true` means the model neither dropped nor invented content on that axis.

Agreement is computed on the two initial, pre-adjudication ratings. Report raw agreement and Gwet's AC1 for every primary binary axis. The evaluation is no-go when any primary gate has AC1 below 0.70. Repair the rubric and rerate the affected outputs before computing release metrics.

LLM judges and subagents may triage or audit. Only blinded native ratings can authorize multilingual release quality.

The global workflow is mechanically checked by `validate-ratings`. It recomputes every corpus-derived benchmark-manifest field, requires the sealed leakage receipt and source-role inventory, and takes a predeclared list of opaque model labels. It fails unless every frozen case and model has exactly two distinct native initial reviewers, every axis or S0-S4 disagreement has exactly one third reviewer, the adjudicator is different from both initial reviewers, and the global, per-reviewer, and per-language-model repeat minimums pass. Candidate text is not part of the rating file or validator input.

```bash
python3 scripts/eval/multilingual_benchmark_v2.py validate-ratings \
  --corpus /absolute/path/to/corpus-v2.jsonl \
  --benchmark-manifest /absolute/path/to/corpus-v2.manifest.json \
  --ratings /absolute/path/to/blinded-native-ratings.jsonl \
  --expected-model-label M1 \
  --expected-model-label M2 \
  --manifest-out /absolute/path/to/blinded-native-ratings.manifest.json
```

The rating manifest pins the rating schema hash, benchmark content hash, exact benchmark-manifest SHA-256, raw rating-file hash, order-independent rating content hash, per-rating hashes, expected labels, review-round counts, and stratified repeat-coverage counts.

## 8. Metrics and uncertainty

Report numerator, denominator, rate, and Wilson 95% interval for every language and for the pooled view:

- strict green;
- same-language retention;
- meaning preservation;
- cleanup completion;
- native grammar and morphology;
- entity, number, timing, and attribution preservation;
- positive-list success;
- false-list rate on restraint rows.

Report S0 through S4 counts separately. Never collapse a safety failure into one headline quality percentage.

Candidate comparison uses paired case outcomes:

- exact McNemar test for paired strict outcomes;
- paired bootstrap confidence interval for rate differences, using 10,000 case-level resamples and recorded seed 1265;
- Holm-Bonferroni correction across the five primary language comparisons;
- Benjamini-Hochberg 5% false-discovery control for secondary category analyses.

Three-seed development finalists report every seed, mean, and range. A damaging seed is never averaged away.

## 9. Proposed release gates

These remain proposed until founder and CTO approval.

For every language claimed as supported:

- strict green at least 285/320, with Wilson lower bound above 85%;
- same-language retention at least 317/320;
- meaning preservation at least 317/320;
- positive lists at least 72/80;
- false lists at most 2/80 per language;
- zero S4 damage.

Across all five languages:

- false lists at most 10/400;
- zero S4 damage across all 1,600 frozen cases.

Candidate comparison gates:

- English paired non-inferiority lower bound above minus 2 percentage points;
- no target language regresses by more than 2 percentage points;
- at least two of German, French, Spanish, and Russian improve significantly after Holm correction.

The existing English 1,890-case and 100-positive/100-trap sets remain regression checks only. They are not clean held-out estimates and cannot substitute for V2.

## 10. Stop rules

- Tune on development only.
- Stop an arm after one smoke and one full development run when its target metric does not improve or safety regresses.
- Do not move a positive-list-only arm to frozen evaluation.
- Do not change prompt, weights, data mixture, decoding, and base model in one comparison.
- Do not inspect frozen failures and continue tuning the same frozen version.
- Only one predeclared finalist reaches frozen and the exact Mac release path.
