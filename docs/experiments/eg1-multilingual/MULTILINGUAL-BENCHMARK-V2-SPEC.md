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
3. Author and validate the development matrix without seeing candidate outputs.
4. Tune prompts, weights, data mixture, quantization, and decoding on development only. Select and lock one exact finalist artifact and evaluation configuration.
5. A separate custodian compares current EG-1 with that exact finalist on development. The power lane receives only `pair_count` and `discordant_count` per language, never case IDs, arm direction, pass rates, or case-level outcomes.
6. Bind the aggregate receipt to the validated 800-row development corpus, its recomputed manifest, and an exact comparison manifest containing the current/finalist artifact and evaluation-configuration hashes.
7. Run the paired-power plan, declare the frozen rows per behavior-domain cell, and never reduce or resize it after frozen outputs are seen.
8. Author the frozen allocation without case-level development results, pin all leakage inputs, and complete exact, token n-gram, character n-gram, and embedding screening.
9. Validate, hash, and seal the frozen corpus before the finalist is run on it.
10. Run frozen once on current EG-1 and the one locked finalist. Generation receipts must match the locked artifact/configuration pairs before ratings can validate.
11. Judge the exact quantized GGUF through the bundled Mac runtime.

The frozen corpus cannot be used to choose between several finalists. A second finalist requires a newly authored and newly sealed frozen version.

### Development authoring gate

The 800-row development matrix is created through
`scripts/eval/build_eg1_multilingual_development_authoring.py`. Its tracked
contract is
`scripts/eval/contracts/eg1_multilingual_development_authoring_v1.json`.

The workflow has four fail-closed stages:

1. `allocate` seals exactly 800 text-free slots: 160 for each of EN/DE/FR/ES/RU and exactly two rows in every language x behavior x domain cell. It also creates ten 16-row author packets and ten 16-row reviewer packets per language; every packet contains every behavior exactly once. Difficulty varies by cell and every behavior/language has all three levels. The 200 list/restraint contrasts predeclare only an opaque brief ID and archetype; their source types are matched exactly (160 native/native and 40 shared/shared). No prose, identity, review approval, or candidate output is allowed.
2. `seal-briefs` consumes a private completion for exactly 32 shared concepts and the same private roster used downstream. Each concept binds one allocation-created brief ID to one meaning-safe, language-neutral brief and exact hash, one row in each of the five languages, and registered `concept_author` / `concept_reviewer` identity references from that roster. The lanes require at least five people each and cap each person at eight briefs. The roster ID and exact bytes are bound into the registry and receipt. The seal must be created in a strict descendant of the allocation commit. Native-original rows never carry a shared brief. This 32-brief development contract is separate from D1's 80 shared concepts.
3. `launch` binds those immutable packets and the exact sealed brief registry to that same private operator-approved roster. The concept roles are human, consented custodians without artificial five-language native claims. Every language separately requires at least five native people in each disjoint local author/reviewer lane, per-language native attestations, and no more than two of ten packets per person. All four roles use singular assignments and globally unique, cross-namespace opaque participant and identity references. Concept custody identities must be distinct from every local author/reviewer identity. Concept and local identity cluster counts remain in gitignored receipt-last bundles and all four are named as human-variance clusters for analysis. These are unsigned operator attestations, not cryptographic identity or custody proof.
4. `merge` is the first stage allowed to read authored rows. It refuses output unless all 800 rows exactly match the deterministic allocation, sealed shared briefs, and launch assignments, every shared local rewrite and native fidelity review binds the exact brief ID/hash, the native-review seal covers every row, an additional reviewer independently approves all 200 contrast sets as comparable, the authenticated Type B blocked-registry receipt passes, and live training/prior-eval/family/text-hash sources match an exhaustive operator-attested inventory, producing receipts, and a four-method scanner receipt bound to the contract's exact approved scanner ID, script path, scanner-contract path, bytes, and producing commit. The merge and `verify-eval` commands require the local pinned embedding model directory so the canonical scanner can recompute the full receipt. Each language uses at least five comparability reviewers and caps each reviewer at eight of its 40 contrast sets; the receipt records those reviewer clusters.

Successful merge status is `development_evaluation_authorized_operator_attested_nonrelease`. It is valid only for development experiments. Release or frozen-benchmark eligibility stays false until a separately predeclared independent custodian pins or signs the complete leakage inventory. `verify-eval` reopens every private upstream bundle, seal, inventory, receipt, and live source; the three-file evaluation bundle cannot authorize itself.

Every stage requires a clean predeclared Git commit and authenticates the
committed contract, builder, benchmark validator, and benchmark schema bytes.
Receipt controls are read from each receipt's producing commit, which must be an ancestor of the current commit; later descendant commits remain valid and non-ancestor receipts fail. The blocked-registry dependency closure includes its four sibling artifacts and all four raw source corpora from the authenticated producing contract. Every dependency is snapshotted before validation and rehashed immediately before the receipt is written or verification returns;
duplicates, missing cells, stale receipts, identity substitution, candidate
output fields, input mutation, and partial publication all block the stage.

```bash
mkdir -p "$PWD/artifacts/eg1-development"

python3 scripts/eval/build_eg1_multilingual_development_authoring.py allocate \
  --expected-git-head "$(git rev-parse HEAD)" \
  --out-bundle "$PWD/artifacts/eg1-development/allocation"

# After committing the allocation, complete the exact 32-concept private template,
# commit the sealing controls in a strict descendant, then seal it:
python3 scripts/eval/build_eg1_multilingual_development_authoring.py seal-briefs \
  --allocation-receipt "$PWD/artifacts/eg1-development/allocation/receipt.json" \
  --private-completion /absolute/private/path/shared-concept-briefs-complete.json \
  --roster /absolute/private/path/development-roster.json \
  --expected-git-head "$(git rev-parse HEAD)" \
  --out-bundle "$PWD/artifacts/eg1-development/shared-briefs"

python3 scripts/eval/build_eg1_multilingual_development_authoring.py launch \
  --allocation-receipt "$PWD/artifacts/eg1-development/allocation/receipt.json" \
  --shared-brief-receipt "$PWD/artifacts/eg1-development/shared-briefs/receipt.json" \
  --roster /absolute/private/path/development-roster.json \
  --expected-git-head "$(git rev-parse HEAD)" \
  --out-bundle "$PWD/artifacts/eg1-development/launch"

# Merge additionally requires --completed-corpus, --native-review-seal,
# --contrast-comparability-seal, --leakage-receipt,
# --blocked-registry-receipt, --leakage-inventory, --scanner-model-dir, and matching
# ROLE:NAME=PATH values through both --leakage-source and --source-receipt.
# Before model inference, authenticate the merged bundle again with the same
# allocation/shared-brief/launch/roster/seals/leakage/inventory/source arguments:
python3 scripts/eval/build_eg1_multilingual_development_authoring.py verify-eval \
  --bundle "$PWD/artifacts/eg1-development/evaluation" \
  --allocation-receipt "$PWD/artifacts/eg1-development/allocation/receipt.json" \
  --shared-brief-receipt "$PWD/artifacts/eg1-development/shared-briefs/receipt.json" \
  --launch-receipt "$PWD/artifacts/eg1-development/launch/receipt.json" \
  --roster /absolute/private/path/development-roster.json \
  --native-review-seal /absolute/private/path/native-review-seal.json \
  --contrast-comparability-seal /absolute/private/path/contrast-comparability-seal.json \
  --leakage-receipt /absolute/private/path/leakage-receipt.json \
  --blocked-registry-receipt /absolute/private/path/blocked-registry/receipt.json \
  --leakage-inventory /absolute/private/path/leakage-inventory.json \
  --leakage-source ROLE:NAME=/absolute/private/path/source.jsonl \
  --source-receipt ROLE:NAME=/absolute/private/path/source-receipt.json \
  --scanner-model-dir /absolute/path/to/Qwen3-Embedding-0.6B/revision-snapshot \
  --expected-git-head "$(git rev-parse HEAD)"
```

Pooled uncertainty and effective sample size cluster by `semantic_family_id`, `author_id`, and `native_reviewer_id`; the 800 rows contain 672 independent semantic-family clusters. Per-language rows remain family-independent at 160 each. Contrast inference pairs and clusters by `contrast_set_id` and also carries author, native-reviewer, and comparability-reviewer clusters. Treating 800 authored rows or 200 contrasts as independent observations is forbidden.

## 3. Corpus size, power, and strata

The minimum release profile contains 2,400 rows. Development remains fixed at 160 rows per language. Frozen begins at 320 per language but expands in balanced 80-row increments when the predeclared paired-power plan requires it.

| Split | Per language | Five languages | Per behavior and language | Per domain and language |
|---|---:|---:|---:|---:|
| Development | 160 | 800 | 10 | 32 |
| Frozen | minimum 320 | minimum 1,600 | minimum 20 | minimum 64 |

The marginals are not enough. Within every language, each behavior x domain cell contains exactly two development rows and a predeclared common frozen count `k`, where `k >= 4`. Frozen size per language is therefore `16 behaviors x 5 domains x k`, always a multiple of 80. This prevents one behavior from being tested mostly in an easy domain while another absorbs the high-risk domains.

The default 320 is an estimation minimum, not an automatic paired-power claim. The planner computes unconditional power for the two-sided exact conditional McNemar/binomial test, using a five-point minimum detectable net improvement, 80% power, and worst-case `0.05 / 5 = 0.01` per-language alpha before Holm correction. It sizes from the largest simultaneous 95% Bonferroni-Wilson upper endpoint across the five language-specific development discordance rates, not the raw point estimate. With 16/160 discordant pairs in every language, the raw 10% becomes a 16.89% sizing rate and selects 880 frozen rows per language. These values are computed before frozen sealing, not selected after a favorable result.

```bash
python3 scripts/eval/multilingual_benchmark_v2.py power-plan \
  --development-discordance-receipt /absolute/path/to/development-discordance-v1.json \
  --development-corpus /absolute/path/to/development-corpus-v2.jsonl \
  --development-benchmark-manifest /absolute/path/to/development-corpus-v2.manifest.json \
  --development-comparison-manifest /absolute/path/to/development-comparison-v1.json \
  --out /absolute/path/to/frozen-power-plan-v2.json
```

The selected `frozen_cases_per_cell` is then passed to both `content-hash` and `validate`. The deterministic benchmark manifest records it. Frozen case count may never change after either candidate has generated frozen output.

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

The four positive-list behaviors produce 40 development and `20 x k` frozen list-activation rows per language. The four restraint behaviors produce a matched 40 development and `20 x k` frozen restraint rows per language. At the minimum `k=4`, those frozen slices contain 80 rows each. Core polish, positive lists, and restraint remain separate scoreboards.

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
- an independent blocked-family clearance for every pinned family registry, bound to the registry SHA-256 and the candidate `semantic_family_id`;
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

The final validator consumes four pinned source roles:

- `training`: every replay, new training row, and training-family registry;
- `prior_eval`: old list sets, overflow origins, multilingual probes, Russian discovery sets, and any earlier benchmark;
- `blocked_family_registry`: blocked source-family IDs that can never enter V2;
- `blocked_text_hash_registry`: normalized source-text hashes that can never enter V2.

Each source is passed as `ROLE:NAME=PATH`. The validator computes the source SHA-256 and directly fails on normalized input, normalized gold, or family-ID collisions. Exact normalization is Unicode-aware and collapses punctuation or symbol runs to spaces, so punctuation-only rewrites do not evade the exact screen.

Old sources without shared semantic IDs use opaque family proxies. A new preassigned family ID cannot prove that it is unrelated merely by using a different namespace. Every candidate therefore needs an independent `provenance.blocked_family_clearances` record bound to its own semantic family ID and the exact blocked-family registry SHA-256. Missing, stale, self-reviewed, duplicated, or non-cleared evidence fails closed. Family records and normalized text hashes have distinct mandatory roles so a hash-only file cannot masquerade as family coverage.

Frozen sealing also requires the receipt-last Type B registry bundle. The validator reads the registry contract, registry builder, allocation contract, and allocator directly from the receipt's producing Git commit. It authenticates their exact bytes, parses the two committed contracts, and checks the receipt, nested allocator binding, source inventory, and all four contract-pinned artifacts against that producing state. It requires exactly one live family artifact and exactly one live text-hash artifact from the bundle. The live private sources and all four live bundle artifacts must still match the hashes pinned by the producing contract. Missing, swapped, duplicated, edited, stale, empty, or coherently replaced artifacts fail closed. A receipt remains valid after later commits or checkouts even when any of the four current control files changes; a missing, incomplete, or mismatched producing commit fails. The benchmark manifest records the exact blocked-registry receipt SHA-256, and the rating gate reopens the same bundle and rechecks that binding.

The committed test suite has two explicit tiers. Default CI/discovery tests generate safe invented sources and temporary contracts, controls, and Git history; they exercise publication, tampering, producing-commit ancestry, roles, receipts, cleanup, and failure handling without any ignored corpus. One `skipUnless`-gated real-private integration test runs only when all four ignored sources are present and owns the exact 11,236-source-row, 7,198-family, 13,733-text-hash, 23-decision, receipt-hash, and zero-verbatim-intersection proof. A clean Git archive must pass evaluator discovery with that integration test as its only skip. Synthetic test data does not change the production allocator bytes or receipt lineage.

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
  --release-profile \
  --frozen-cases-per-cell 11

# Run the approved exact, fuzzy, and embedding scanner with predeclared thresholds.
# Its output is leakage-receipt-v1.json, bound to the content hash above.

python3 scripts/eval/multilingual_benchmark_v2.py validate \
  --corpus /absolute/path/to/corpus-v2.jsonl \
  --release-profile \
  --frozen-cases-per-cell 11 \
  --power-plan /absolute/path/to/frozen-power-plan-v2.json \
  --development-discordance-receipt /absolute/path/to/development-discordance-v1.json \
  --development-corpus /absolute/path/to/development-corpus-v2.jsonl \
  --development-benchmark-manifest /absolute/path/to/development-corpus-v2.manifest.json \
  --development-comparison-manifest /absolute/path/to/development-comparison-v1.json \
  --leakage-source training:eg1-training=/absolute/path/to/training.jsonl \
  --leakage-source prior_eval:all-prior-evals=/absolute/path/to/prior-evals.jsonl \
  --leakage-source blocked_family_registry:blocked-v2=/absolute/path/to/type-b-v2-registry/blocked_family_registry.jsonl \
  --leakage-source blocked_text_hash_registry:blocked-v2-text=/absolute/path/to/type-b-v2-registry/blocked_text_hashes.jsonl \
  --leakage-receipt /absolute/path/to/leakage-receipt-v1.json \
  --blocked-registry-receipt /absolute/path/to/type-b-v2-registry/receipt.json \
  --manifest-out /absolute/path/to/corpus-v2.manifest.json
```

The manifest has no clock field or absolute input paths. It deterministically records schema hashes, raw source hash, order-independent benchmark content hash, per-row hashes, family-assignment hash, the sealed power-plan/development-receipt hashes, the locked current/finalist comparison hashes, leakage-source hashes, both leakage-receipt hashes, and all split/language/domain/behavior/behavior-domain/difficulty/safety/list counts. Sealing fails unless the actual 800-row development corpus is balanced and matches its recomputed manifest, the aggregate discordance receipt binds to that manifest and the exact comparison manifest, and the power plan exactly recomputes to the same frozen cell count. The same files and validator version produce the same manifest bytes.

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

The global workflow is mechanically checked by `validate-ratings`. Before reading ratings, it proves the predeclared Git HEAD and clean tracked worktree, rejects untracked Python shadows under `scripts/eval`, byte-matches the complete local authoring/scanner import and contract closure to that commit, and only then executes the captured committed verifier bytes. It reopens the complete authenticated development-authoring bundle, allocation, sealed shared briefs, launch, private roster, native-review seal, comparability seal, leakage inventory, producing receipts, sources, scanner receipt, and pinned local scanner model. Authentication captures and rechecks that exact evidence/model fingerprint. All later rating inputs are read from private immutable temporary copies; the originals and full model/control closure are rechecked immediately before atomic manifest publication. The development corpus and manifest supplied to the power and rating gates must have the same bytes as the authenticated authoring bundle artifacts; a plain development manifest cannot authorize ratings. It then recomputes every release-corpus-derived benchmark-manifest field, requires the sealed release leakage receipt, authenticated blocked-registry receipt, and exact four-role source inventory, and takes a predeclared list of opaque model labels. It fails unless every frozen case and model has exactly two distinct native initial reviewers, every axis or S0-S4 disagreement has exactly one third reviewer, the adjudicator is different from both initial reviewers, and the global, per-reviewer, and per-language-model repeat minimums pass. Candidate text is not part of the rating file or validator input.

```bash
python3 scripts/eval/multilingual_benchmark_v2.py validate-ratings \
  --corpus /absolute/path/to/corpus-v2.jsonl \
  --benchmark-manifest /absolute/path/to/corpus-v2.manifest.json \
  --ratings /absolute/path/to/blinded-native-ratings.jsonl \
  --power-plan /absolute/path/to/frozen-power-plan-v2.json \
  --development-discordance-receipt /absolute/path/to/development-discordance-v1.json \
  --development-corpus /absolute/path/to/development-corpus-v2.jsonl \
  --development-benchmark-manifest /absolute/path/to/development-corpus-v2.manifest.json \
  --development-comparison-manifest /absolute/path/to/development-comparison-v1.json \
  --development-authoring-bundle /absolute/private/path/development-evaluation \
  --development-allocation-receipt /absolute/private/path/allocation/receipt.json \
  --development-shared-brief-receipt /absolute/private/path/shared-briefs/receipt.json \
  --development-launch-receipt /absolute/private/path/launch/receipt.json \
  --development-roster /absolute/private/path/native-roster.json \
  --development-native-review-seal /absolute/private/path/native-review-seal.json \
  --development-contrast-comparability-seal /absolute/private/path/contrast-comparability-seal.json \
  --development-leakage-receipt /absolute/private/path/development-leakage/receipt.json \
  --development-blocked-registry-receipt /absolute/private/path/type-b-v2-registry/receipt.json \
  --development-leakage-inventory /absolute/private/path/development-leakage-inventory.json \
  --development-leakage-source ROLE:NAME=/absolute/private/path/source.jsonl \
  --development-source-receipt ROLE:NAME=/absolute/private/path/source-receipt.json \
  --development-scanner-model-dir /absolute/path/to/Qwen3-Embedding-0.6B/revision-snapshot \
  --expected-git-head "$(git rev-parse HEAD)" \
  --generation-receipt /absolute/path/to/frozen-generation-M1.json \
  --generation-receipt /absolute/path/to/frozen-generation-M2.json \
  --expected-model-label M1 \
  --expected-model-label M2 \
  --leakage-source training:eg1-training=/absolute/path/to/training.jsonl \
  --leakage-source prior_eval:all-prior-evals=/absolute/path/to/prior-evals.jsonl \
  --leakage-source blocked_family_registry:blocked-v2=/absolute/path/to/type-b-v2-registry/blocked_family_registry.jsonl \
  --leakage-source blocked_text_hash_registry:blocked-v2-text=/absolute/path/to/type-b-v2-registry/blocked_text_hashes.jsonl \
  --leakage-receipt /absolute/path/to/leakage-receipt-v1.json \
  --blocked-registry-receipt /absolute/path/to/type-b-v2-registry/receipt.json \
  --manifest-out /absolute/path/to/blinded-native-ratings.manifest.json
```

The rating manifest pins the rating schema hash, benchmark content hash, exact benchmark-manifest SHA-256, raw rating-file hash, order-independent rating content hash, per-rating hashes, expected labels, review-round counts, stratified repeat-coverage counts, and the two generation receipts. The validator checks receipt consistency: each receipt must declare one locked artifact/configuration pair, the sealed benchmark-manifest hash, the frozen case count, zero generation errors, and the output hash. It does not receive and hash the model, evaluation-configuration, or generation-output files themselves. Those receipts must therefore be emitted by a trusted generation harness or independent custodian; a hand-written receipt is not provenance proof.

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

Frozen sample size is chosen from aggregate arm-blinded development discordance for the exact locked finalist before frozen sealing. The default 320 per language is expanded when unconditional power for the two-sided exact conditional McNemar test is below 80% for a five-point net improvement at the worst-case corrected alpha. Sample size can never be changed after frozen model outputs exist.

Three-seed development finalists report every seed, mean, and range. A damaging seed is never averaged away.

## 9. Proposed release gates

These remain proposed until founder and CTO approval.

Let `N` be the predeclared frozen rows per language and `L` be the positive-list or restraint rows per language. At `k=4`, `N=320` and `L=80`. For every language claimed as supported:

- strict green at least 89.0625% of `N`, rounded up, with Wilson lower bound above 85%;
- same-language retention at least 99.0625% of `N`, rounded up;
- meaning preservation at least 99.0625% of `N`, rounded up;
- positive lists at least 90% of `L`, rounded up;
- false lists at most 2.5% of `L`, rounded down;
- zero S4 damage.

Across all five languages:

- false lists at most 2.5% of the pooled restraint slice, rounded down;
- zero S4 damage across every frozen case.

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
