# EG-1 D1 Universal Multilingual Data Builder V1

Status: tooling and allocation contract only. No D1 examples have been authored, exported, or trained.

## Purpose

D1 tests one universal offline model. It does not create separate full-size language models. The planned addition is 2,000 family-disjoint rows across English, German, French, Spanish, and Russian. The builder creates no text and starts no training. It only allocates families, validates authored rows, and produces a trainable file after every gate passes.

Source design: `TRAINING-DATA-DESIGN-V2.md`.

## Fixed allocation

Seed: `1265`.

| Language | Core | Positive lists | Matched restraint | Total |
|---|---:|---:|---:|---:|
| English | 120 | 140 | 140 | 400 |
| German | 120 | 140 | 140 | 400 |
| French | 120 | 140 | 140 | 400 |
| Spanish | 120 | 140 | 140 | 400 |
| Russian | 120 | 140 | 140 | 400 |
| Total | 600 | 700 | 700 | 2,000 |

Within each language:

- Positive list item counts 2, 3, 5, and 7 each receive 35 families.
- Five list types and five domains each receive 28 positive families.
- Four length buckets each receive 35 positive families.
- Seven restraint types each receive 20 families.
- Every positive family is paired with one separately authored restraint family that has the same domain, length, difficulty, risk, and item-count pressure.
- Every core behavior includes medical and legal/financial examples. Core totals remain balanced across domains, lengths, and difficulty.
- 320 families are native-original and 80 are independently rewritten shared concepts. The same 80 opaque concept IDs span all five languages, but each language must use a different authoring template and native-language author. A synthetic native-language author is allowed only with full model/config provenance, a different synthetic critic, and later human native approval.

The allocation is deterministic SHA-256 ordering. It does not rely on Python's random implementation, so the same contract and seed produce the same family slots.

## Row contract

Each authored JSONL row must match its allocated slot and include:

- stable `family_id`, `semantic_origin_id`, and optional pair/cross-language IDs;
- language, split, stratum, behavior, domain, length, difficulty, safety risk, and list/restraint axes;
- `semantic_scenario_id` and `authoring_template_id`;
- source ID, author ID/type/language, and origin mode;
- realistic ASR-style `input` and minimally edited `output`;
- explicit meaning, entity, number, timing, attribution, formatting, and compound-scope checks;
- `native_reviewed` plus reviewer identity, reviewer language, timestamp, and status.

Positive and restraint partners must not reuse a scenario, template, or near-identical wording. Medical, legal, and financial rows must carry nonempty timing and attribution checks. Positive list outputs must have exactly the allocated number of list lines. Restraint outputs must have none.

## Blocked-family input

Start from `D1-BLOCKED-FAMILY-REGISTRY-TEMPLATE-V1.json`. A benchmark owner must seal one merged registry without exposing frozen content to the training author. It must cover all five groups:

1. old `LF-*` and `LFT-*` list benchmarks;
2. overflow semantic origins;
3. Russian development and frozen families;
4. multilingual probes;
5. the new model-blind benchmark families.

The sealed registry can block exact family IDs, prefixes, opaque semantic-origin IDs, and SHA-256 hashes of normalized inputs/outputs. A `draft` registry is useful while authoring, but it cannot export training or release data.

## Leakage receipt

Training and release export require a separate sealed receipt with this shape:

```json
{
  "schema_version": "eg1-d1-leakage-receipt-v1",
  "status": "pass",
  "candidate_rows_sha256": "<sha256 of authored JSONL>",
  "blocked_registry_sha256": "<sha256 of sealed registry>",
  "prompt_sha256": "<pinned prompt sha256>",
  "checks": {
    "exact_normalized": {"status": "pass", "matches": 0},
    "token_similarity": {"status": "pass", "matches": 0},
    "char_ngram_similarity": {"status": "pass", "matches": 0},
    "embedding_similarity": {"status": "pass", "matches": 0}
  }
}
```

The builder validates artifact hashes and every check. It does not pretend its exact-match checks replace token, character n-gram, or embedding leakage analysis.

## Fail-closed workflow

The checked-in contract pins the development-only list-aware prompt by SHA-256. Both training and release approvals are `false`. The blocked-family template is also `draft`. Therefore the current repository state cannot export a trainable D1 dataset by accident.

When authoring is approved, write allocation slots only:

```bash
python3 scripts/eval/build_eg1_multilingual_d1.py slots \
  --contract scripts/eval/eg1_multilingual_d1_contract_v1.json \
  --output /approved/private/path/d1-slots.jsonl
```

Validate incomplete authoring without creating a trainable output:

```bash
python3 scripts/eval/build_eg1_multilingual_d1.py validate \
  --contract scripts/eval/eg1_multilingual_d1_contract_v1.json \
  --rows /approved/private/path/d1-authored.jsonl \
  --blocked-registry /approved/private/path/d1-blocked-sealed.json \
  --purpose draft \
  --report /approved/private/path/d1-draft-report.json
```

After founder/CTO approval, all 2,000 rows must have approved native review, the registry must be sealed, and the leakage receipt must pass before a training export can be written:

```bash
python3 scripts/eval/build_eg1_multilingual_d1.py validate \
  --contract /approved/private/path/d1-contract-approved.json \
  --rows /approved/private/path/d1-authored.jsonl \
  --blocked-registry /approved/private/path/d1-blocked-sealed.json \
  --leakage-receipt /approved/private/path/d1-leakage-receipt.json \
  --purpose training \
  --report /approved/private/path/d1-training-report.json \
  --output /approved/private/path/d1-training-approved.jsonl
```

Release export repeats the same checks and additionally requires a non-development prompt plus separate `release_export_allowed: true` approval. Missing native review, one failed leakage check, one unresolved blocked-family group, a prompt hash mismatch, or one family allocation mismatch exits nonzero before dataset export.

Only the gate-produced JSONL and its companion manifest may be passed to the generic QLoRA trainer. The exact quantized GGUF through the bundled Mac runtime remains the release authority.

## Validation receipt

Run from the repository root:

```bash
python3 -m py_compile \
  scripts/eval/build_eg1_multilingual_d1.py \
  scripts/eval/tests/test_build_eg1_multilingual_d1.py

python3 -m unittest scripts/eval/tests/test_build_eg1_multilingual_d1.py -v
```

The tests cover deterministic 2,000-slot balance, positive/restraint matching, numbered-versus-bullet marker enforcement, draft eligibility reporting, pending-native-review rejection, unsealed-registry rejection, successful approved training export in a temporary directory, separate release approval, and blocked-family/template reuse rejection.
