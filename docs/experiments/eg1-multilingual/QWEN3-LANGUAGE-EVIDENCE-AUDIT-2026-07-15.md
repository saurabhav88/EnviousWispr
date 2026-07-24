# Qwen3 / EG-1 language evidence audit - 2026-07-15

## TL;DR

We do **not** have enough comparable evidence to rank English, German, French,
Spanish, and Russian as five model-language strengths.

The defensible diagnostic signal is narrower:

- On the same eight legacy cases per language, current EG-1 is strongest in
  German, next in French, and weakest in Spanish.
- Russian changes materially with the prompt, so it cannot be treated as a
  fixed model capability from the current 16 development cases.
- English broad Type B is excluded from language ranking. The 93.7% exact-Mac
  result uses an old development set with 1,549/1,890 exact training overlap
  and 1,868/1,890 normalized-seeded family exposure.
- English list evidence remains its own task-specific lane. It must not be
  pooled with multilingual polish scores.

No evidence here is native-reviewed frozen release evidence.

## What was recomputed

The audit script pins every source by SHA-256 and row count, checks paired case
identity, recomputes English list mechanics from the pinned candidates, and
emits only aggregate counts and confidence intervals. The BASE-RUN-005 counts
come from an immutable tracked receipt that records the producing commit, Git
blob, full-log hash, and section hash. Later additions to the living overnight
log do not change or break this audit, including in shallow clones. It never
emits transcript, reference, candidate, or judge-note text.

Run it from this checkout while pointing at the ignored historical artifacts:

```bash
python3 scripts/eval/audit_qwen3_language_evidence.py \
  --private-root /Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr \
  --output /tmp/qwen3-language-evidence.json
```

The pinned contract is
`scripts/eval/contracts/qwen3_language_evidence_v1.json`.

## Shared legacy multilingual slice

These are 8 cases per language. The legacy artifacts do not embed complete
model, prompt, or runtime identity, so identity is supported only by their path
and the historical log. The known-bad Hindi judge slice is replaced by its
pinned 8-row rejudge before aggregation.

### Untouched Qwen3 base - legacy judge

| Language | Language kept | Meaning OK | Polish OK | Strict conjunction |
|---|---:|---:|---:|---:|
| German | 0/8 | 8/8 | 0/8 | 0/8 |
| French | 3/8 | 7/8 | 8/8 | 3/8 |
| Spanish | 2/8 | 8/8 | 7/8 | 1/8 |

### Current merged EG-1 - legacy judge

| Language | Language kept | Meaning OK | Polish OK | Strict conjunction |
|---|---:|---:|---:|---:|
| German | 8/8 | 8/8 | 8/8 | 8/8 |
| French | 8/8 | 6/8 | 6/8 | 6/8 |
| Spanish | 8/8 | 6/8 | 2/8 | 2/8 |

`polish_ok` for current EG-1 is a diagnostic metric. It is not pooled with the
untouched-base strict or meaning metrics, and neither table is a release claim.

The samples are too small for a stable ordering beyond this diagnostic. For
example, the 95% Wilson interval is 67.6%-100% for 8/8, 40.9%-92.9% for 6/8,
and 7.1%-59.1% for 2/8.

## Newer untouched-Qwen3 universal bakeoff

The later independent model-assisted review reported these aggregate results
for the untouched Qwen3 base under strict-v1:

| Slice | Same language | Meaning safe | Cleanup | Grammar | Damaging | Strict |
|---|---:|---:|---:|---:|---:|---:|
| ML56 | 54/56 | 52/56 | 28/56 | 45/56 | 7/56 | 26/56 |

Priority-language strict counts were German 6/8, French 6/8, and Spanish 3/8.
The English two-item slice separately reported 13/20 meaning-safe, 7/20
damaging, and 3/20 strict.

The script reads these counts from the hash-pinned BASE-RUN-005 aggregate
receipt, which records source commit
`9a4e7a025b76b252c534f6ea0332f8acafa6fbe5`, and recomputes rates and confidence
intervals. The per-case semantic judgments were not retained, so the
classifications themselves cannot be independently recomputed.

This stratum conflicts sharply with the legacy judge on the same ML56 case
families:

| Language | Legacy strict | Newer bakeoff strict |
|---|---:|---:|
| German | 0/8 | 6/8 |
| French | 3/8 | 6/8 |
| Spanish | 1/8 | 3/8 |

The prompt and review path changed, while the case families did not. This is a
data-quality finding: the current artifacts cannot separate base-model language
strength from prompt and judge sensitivity.

## Russian prompt matrix

The eight tracked Russian arms reuse the same 16 development cases. Their
model ID and prompt SHA are embedded and checked, so prompt sensitivity is
real within this deterministic scorer. The arms are paired; they are not 112
independent cases.

| Model variant | Prompt | Deterministic strict | List structure |
|---|---|---:|---:|
| Untouched Qwen3 base | Shipping | 3/16 | 0/2 |
| Untouched Qwen3 base | Strict | 7/16 | 1/2 |
| Untouched Qwen3 base | Labeled | 7/16 | 1/2 |
| Current merged EG-1 | Shipping | 7/16 | 2/2 |
| Current merged EG-1 | Strict | 6/16 | 2/2 |
| Current merged EG-1 | Labeled | 6/16 | 2/2 |
| EG-1 tokenizer control | Shipping | 7/16 | 2/2 |
| Current merged EG-1 | List v2 | 6/16 | 2/2 |

The semantic Russian judgments survive only as prose-level aggregate claims,
not retained case-level score artifacts. They cannot be independently
recomputed and are excluded from the ranking.

## English evidence kept separate

### Untouched Qwen3 base - list mechanics

- Two-item suite: 2/20 mechanical strict, 10/20 structure activation.
- Overflow positives: 1/100 activated with the intended item count.
- Overflow restraint traps: 0/100 false lists.

These are list mechanics, not broad English polish quality. The overflow cases
also reuse exposed origin families, so they are development evidence only.

### Current EG-1 - exact Mac list slice

On the exact-Mac full old Type B run, the 200 list rows recompute to:

- 174/200 strict three-green (`behavior_correct AND meaning_preserved AND clean_output`)
- 174/200 behavior correct
- 200/200 meaning preserved
- 24/200 S3/S4 judge-severity results

All 24 S3/S4 list rows still had `meaning_preserved=true`, and all 24 had
`behavior_correct=false`; two also had `clean_output=false`. In this rubric,
`meaning_preserved` means the content intent survived. It does not mean the
required list behavior succeeded. The S3/S4 label therefore must not be called
"meaning damage" without this cross-tab.

The hard-340 exact-Mac slice separately reports 33/40 strict three-green and
6/40 S3/S4 judge-severity results. These are list-specific and cannot be combined
with the non-English legacy metrics.

### Why 93.7% is disqualified

The exact-Mac old Type B run has 1,771/1,890 `pass` or `minor` judgments, which
is the historical 93.7% headline. The audit also reproduces:

- 1,549/1,890 exact ID overlap with EG-1 training
- 1,549/1,890 casefold-and-space-normalized input overlap
- 1,551/1,890 conservative Unicode/punctuation-insensitive input overlap
- 1,866/1,890 exposure through transitive ID/origin family components
- 1,868/1,890 exposure when normalized text matches also seed family traversal

Therefore 93.7% remains a regression litmus result only. It is not admitted as
evidence that English is a strong language, and it is not used in a five-language
ranking.

## Why a five-language ranking is not statistically valid

There is no common evidence stratum with all of the following:

1. the same balanced case design for all five priority languages;
2. the same model artifact, prompt, runtime, and tokenizer path;
3. retained case-level semantic scores under one rubric;
4. native review and a frozen set;
5. no training or semantic-family exposure;
6. enough cases for useful confidence and paired significance tests.

Current evidence mixes 8-case language probes, 16-case Russian prompt probes,
English list stress tests, and a leaked 1,890-case English development gate.
Pooling them would create false precision.

## Decision

- **No five-language ranking.** Evidence is insufficient.
- **Diagnostic current-EG-1 ordering:** German > French > Spanish on the one
  shared 8-case slice.
- **Russian:** promising but prompt-sensitive; requires the common multilingual
  benchmark.
- **English:** broad old Type B excluded; keep exact-Mac list data in the list
  lane only.
- **Next valid comparison:** one balanced, model-blind, family-disjoint,
  native-reviewed development benchmark across English, German, French,
  Spanish, and Russian, followed by a separately frozen release set.

## Source trail

- `docs/experiments/eg1-multilingual/receipts/qwen3-base-run-005.aggregate.json`,
  sourced from the overnight log at producing commit
  `9a4e7a025b76b252c534f6ea0332f8acafa6fbe5`, blob
  `22bd3ebf3be9f8ddcfe8fa5d0524b7b70002357c`
- `docs/experiments/eg1-multilingual/scored/*.scored.jsonl`
- `docs/experiments/eg1-multilingual/alien-runs/universal-base-bakeoff/`
- ignored historical sources under `scripts/eval/runs/bakeoff-1265/` and
  `scripts/eval/runs/type-b-1199/`, pinned by hash in the audit contract
