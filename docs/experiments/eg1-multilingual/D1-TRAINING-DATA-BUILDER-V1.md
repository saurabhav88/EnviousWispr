# EG-1 D1 Universal Multilingual Data Builder V1

Status: tooling and allocation contract only. Native-original authorship can start after a real private roster is approved and bound. Shared-concept authorship remains blocked until the private briefs are sealed. No D1 examples have been authored, exported, or trained.

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
- 320 families are native-original and 80 are independently rewritten shared concepts. An opaque concept ID alone does not prove five authors used the same meaning. Before any shared-origin row can merge or validate, a private sealed registry must bind every one of the 80 IDs to one approved semantic brief ID and exact brief hash. The packet and merge receipts expose only IDs and hashes, never the private brief prose. Each language must use a different authoring template and native-language author. A synthetic native-language author is allowed only with full model/config provenance, a different synthetic critic, and later separate human native approval.

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
- for shared-origin rows, the sealed concept-registry ID, brief ID, and brief SHA-256.

Positive and restraint partners must not reuse a scenario, template, or near-identical wording. Medical, legal, and financial rows must carry nonempty timing and attribution checks. Positive list outputs must have exactly the allocated number of list lines. Restraint outputs must have none.

## Private shared-concept input

The private registry uses schema `eg1-d1-shared-concept-registry-v1`, a finalized `registry_id`, `status: sealed`, and an approval object with `approved_for_authoring: true`, approver identity, and approval reference. Its `concepts` list must cover exactly the 80 allocated IDs once each. Every entry carries the opaque concept ID, a unique brief ID, the private semantic brief, and the SHA-256 of those exact brief bytes. Any missing, extra, duplicate, empty, unapproved, or hash-mismatched entry fails before packet merge or draft validation. The private prose is never copied into public receipts or tracked artifacts.

## Private author and reviewer launch

No roster or person is checked in. A real private roster must be supplied before writing starts. It contains only opaque IDs and private reference IDs, never names, email addresses, or contact details. Each human record requires confirmed availability, native-language qualification, an identity reference, a consent reference, and one or both roles: `author` and `native_reviewer`. Each language needs at least one human-native author and a different human-native reviewer who can review that author's rows. Synthetic author records may use only the author role and must bind a model/configuration plus a different critic model/configuration.

The launch tool deterministically binds rows to the approved roster. At least 50% of ready author assignments in every language are human-native. Every row has a separate human-native reviewer. All authorship and review statuses remain pending, and the launch receipt always reports training and release eligibility as false.

Before the shared-concept registry exists, a blocked packet set can launch exactly 1,600 native-original rows, 320 per language. The 400 shared-concept rows remain unassigned and blocked. Once the private concept registry is sealed, regenerate the five packet files with that registry and run the launch tool again to assign all 2,000 rows. The command requires a committed clean tool revision:

```bash
python3 scripts/eval/build_eg1_d1_authoring_launch.py \
  --contract scripts/eval/eg1_multilingual_d1_contract_v1.json \
  --packet-receipt /approved/private/path/d1-authoring-packets/authoring-packet-receipt.json \
  --roster /approved/private/path/d1-author-review-roster.json \
  --out-bundle scripts/eval/runs/d1-private-authoring-launch \
  --expected-git-head "$(git rev-parse HEAD)"
```

Add `--shared-concept-registry /approved/private/path/d1-shared-concepts-sealed.json` only when the packet set was created with that exact registry. A blocked packet receipt cannot be silently upgraded after the fact. The private launch bundle contains assignment metadata and a receipt only. It contains no authored prose or review approval. Completed-packet merge and training/release validation consume both launch files and reject any substituted author or reviewer.

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

The checked-in contract pins the development-only list-aware prompt by SHA-256. Both training and release approvals are `false`. The blocked-family template is also `draft`, no real private roster is approved, and no private shared-concept brief registry is sealed. Therefore the current repository state cannot start real authorship, merge a complete authoring set, or export a trainable D1 dataset by accident. Packet creation without that registry is allowed only to distribute the 320 native-original slots per language; its receipt is marked `blocked`, and shared-origin authorship plus all merging remain disabled.

Create five immutable 400-row authoring packets. Before the private concept registry exists, run this command without `--shared-concept-registry`; the receipt is marked `blocked`, and every `shared_concept_independent_rewrite` slot must remain unauthored. Once the sealed registry exists, bind it while creating a fresh packet set:

```bash
python3 scripts/eval/build_eg1_multilingual_d1.py packets \
  --contract scripts/eval/eg1_multilingual_d1_contract_v1.json \
  --shared-concept-registry /approved/private/path/d1-shared-concepts-sealed.json \
  --output-dir /approved/private/path/d1-authoring-packets
```

Each packet must be completed independently without changing its allocated fields. Merge accepts exactly one completed file for each language and exactly one copy of every family. It rejects a missing/duplicate family, a row in the wrong language packet, slot drift, receipt drift, or a shared row that is not bound to its sealed brief:

```bash
python3 scripts/eval/build_eg1_multilingual_d1.py merge-packets \
  --contract scripts/eval/eg1_multilingual_d1_contract_v1.json \
  --packet-receipt /approved/private/path/d1-authoring-packets/authoring-packet-receipt.json \
  --shared-concept-registry /approved/private/path/d1-shared-concepts-sealed.json \
  --launch-assignments /approved/private/path/d1-private-authoring-launch/assignments.jsonl \
  --launch-receipt /approved/private/path/d1-private-authoring-launch/receipt.json \
  --completed-packet en=/approved/private/path/en.completed.jsonl \
  --completed-packet de=/approved/private/path/de.completed.jsonl \
  --completed-packet fr=/approved/private/path/fr.completed.jsonl \
  --completed-packet es=/approved/private/path/es.completed.jsonl \
  --completed-packet ru=/approved/private/path/ru.completed.jsonl \
  --output /approved/private/path/d1-authored-merged.jsonl \
  --receipt /approved/private/path/d1-authored-merge-receipt.json
```

Validate incomplete authoring without creating a trainable output:

```bash
python3 scripts/eval/build_eg1_multilingual_d1.py validate \
  --contract scripts/eval/eg1_multilingual_d1_contract_v1.json \
  --rows /approved/private/path/d1-authored.jsonl \
  --blocked-registry /approved/private/path/d1-blocked-sealed.json \
  --shared-concept-registry /approved/private/path/d1-shared-concepts-sealed.json \
  --purpose draft \
  --report /approved/private/path/d1-draft-report.json
```

After founder/CTO approval, all 2,000 rows must have approved native review, the registry must be sealed, and the leakage receipt must pass before a training export can be written:

```bash
python3 scripts/eval/build_eg1_multilingual_d1.py validate \
  --contract /approved/private/path/d1-contract-approved.json \
  --rows /approved/private/path/d1-authored.jsonl \
  --blocked-registry /approved/private/path/d1-blocked-sealed.json \
  --shared-concept-registry /approved/private/path/d1-shared-concepts-sealed.json \
  --launch-assignments /approved/private/path/d1-private-authoring-launch/assignments.jsonl \
  --launch-receipt /approved/private/path/d1-private-authoring-launch/receipt.json \
  --leakage-receipt /approved/private/path/d1-leakage-receipt.json \
  --purpose training \
  --report /approved/private/path/d1-training-report.json \
  --output /approved/private/path/d1-training-approved.jsonl
```

Release export repeats the same checks and additionally requires a non-development prompt plus separate `release_export_allowed: true` approval. Packet merge is structural only and never grants training eligibility. Missing or changed launch assignments, substituted authors or reviewers, missing human native review, one failed leakage check, one unresolved blocked-family group, a missing or changed shared brief binding, a prompt hash mismatch, or one family allocation mismatch exits nonzero before dataset export.

Only the gate-produced JSONL and its companion manifest may be passed to the generic QLoRA trainer. The exact quantized GGUF through the bundled Mac runtime remains the release authority.

## Validation receipt

Run from the repository root:

```bash
python3 -m py_compile \
  scripts/eval/build_eg1_multilingual_d1.py \
  scripts/eval/build_eg1_d1_authoring_launch.py \
  scripts/eval/tests/test_build_eg1_multilingual_d1.py \
  scripts/eval/tests/test_build_eg1_d1_authoring_packets.py \
  scripts/eval/tests/test_build_eg1_d1_authoring_launch.py

python3 -m unittest \
  scripts/eval/tests/test_build_eg1_multilingual_d1.py \
  scripts/eval/tests/test_build_eg1_d1_authoring_packets.py \
  scripts/eval/tests/test_build_eg1_d1_authoring_launch.py -v
```

The tests cover deterministic 2,000-slot balance, five immutable 400-row packet hashes, private roster intake, 1,600-row partial launch, 2,000-row sealed launch, at least 50% human-native authorship, independent human-native review assignment, synthetic author/critic separation, one successful exact merge, missing/duplicate/cross-language/tampered-row rejection, receipt-tamper rejection, opaque shared-ID rejection without a sealed brief, positive/restraint matching, numbered-versus-bullet marker enforcement, draft eligibility reporting, pending-native-review rejection, unsealed-registry rejection, successful approved training export in a temporary directory, separate release approval, and blocked-family/template reuse rejection.
