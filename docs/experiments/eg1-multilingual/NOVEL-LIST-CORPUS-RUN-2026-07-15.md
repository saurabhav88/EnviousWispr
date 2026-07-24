# Novel English list corpus run — 2026-07-15

## Scope and hard gates

- Purpose: build model-blind English positive-list and prose-restraint development cases for the universal EG-1 path.
- This work does not choose or imply separate full language models. Product priority remains one universal offline model; a shared base plus small language deltas is only a fallback.
- Candidate gold is `native_reviewed: false` and `training_eligible: false`.
- No candidate model outputs were generated or inspected in this corpus lane.

## Sealed selection

- Original target: 100 positive-list plus 100 prose-restraint cases.
- Schedule change: because subscription generation was slower than forecast, the pilot was predeclared as the first 75 checkpoint-order specifications for each role before restraint output existed.
- Selection rule: `first_n_checkpoint_order_without_output_inspection`.
- Sealed manifest SHA-256: `7d7831eb14406f15c1e9c12cbdf98e3d198b370ee5623cfa9a565307d08dd174`.
- Canonical definition SHA-256: `5a7cb24ef6fe61f7f67cee66338fc0a4adcf1da16697ff31e2c10f6faf50ca04`.
- Sealed generator SHA-256: `ead3e1b9cbd6b9dad65092296de33e2c5baec716598b008d69d2bae2e8890a3b`.
- Positive checkpoints 16–17 (cases 76–85) remain reserved for the later full run and were not selected for this pilot.

## Generation receipts

- Accepted positive checkpoints: 17 batches / 85 rows. Pilot selection uses batches 1–15 / 75 rows.
- Accepted restraint checkpoints: 15 batches / 75 rows.
- Restraint rejected attempts: 3, with no rejected attempt checkpointed or manually repaired:
  - batch 6 attempt 1: duplicate semantic-family label;
  - batch 7 attempt 1: invalid forbidden span;
  - batch 8 attempt 1: duplicate semantic-family label.
- Each failed restraint batch was regenerated as a whole and accepted on attempt 2.
- A bounded concurrency probe was abandoned after both calls idled; serial generation was restored and no probe output was accepted.

## Publication audit and stop

- The first portable-validation attempt completed its first screening pass and was in written-byte revalidation when an independent audit found transaction and receipt gaps.
- The validator process was deliberately terminated before publication. No final corpus, checkpoint bundle, receipt, or candidate model output was published.
- Killed-run temporary JSONL bytes remain preserved under `scripts/eval/corpus/eg1-list-pilot-xxou8g_w/` for audit only. They are not a committed result.
- All original checkpoints remain untouched under `/tmp/eg1-english-list-novel-v1-checkpoints/` (17 positive, 15 restraint).

## Audit hardening before rerun

The replacement assembler now:

- recomputes the canonical definition, full balanced specifications, first-N selection, excluded suffix, distributions, and exact safety flags;
- lexically remaps sealed absolute paths from the original repo root to the current repo root for portable replay;
- reads each source/checkpoint once, hashes and parses those same bytes, snapshots those exact bytes, and reparses/rehashes the snapshot;
- screens generated input and expected output against every source input/output field and every earlier generated input/output field;
- records exact comparison counts, field-pair counts, cross-batch/cross-role counts, and per-axis maxima with provenance;
- publishes one exclusive bundle, refuses an existing bundle, and writes the receipt last as the commit marker;
- removes only the bundle directory created by the current invocation if a pre-receipt failure occurs.

The manifest writer is now exclusive/no-overwrite. The general generator remains byte-exact at the sealed hash during this one assembly because generation mode and its output writers are inactive; changing it earlier would invalidate the sealed prompt/checkpoint contract. After successful bundle publication, its writers must be changed to exclusive mode in a separate post-run hash/commit.

## Current status

- Generation: complete for the sealed 75 + 75 pilot.
- Publication: complete after two 5,028,900-comparison written-byte passes. The current exclusive receipt-last bundle is `scripts/eval/corpus/eg1_english_list_pilot75_v2_bundle`; receipt SHA-256 is `131cc84898db829859aa6d73940df8685882adeedb76057a050231bcf3efc000`.
- Corpus hashes: positive `1fffba6215670a9a1cfd3cb723d39a6ee479b9dfbae47224aa8ed04a7520baee`; restraint `e44cdceb4a1eca8ea2b90528af170897021218b506122f9d9952546495055e21`.
- Independent audit: PASS. All 41 receipt-bound members, nine source snapshots, 30 checkpoints, and both outputs match; the historical-generator proof and exact first-75 selection lineage reproduce. A separate full 5,028,900-comparison replay found zero exact/high-similarity violations and reproduced every counter and maximum from both internal passes.
- V1/V2 equivalence: all 150 IDs, ordering, semantic fields, and similarity scores are identical. The corpus byte hashes changed only because 94 audit-only `nearest_source` path strings now name the V2 bundle directory.
- Privacy boundary: the V2 bundle includes private source snapshots needed to reproduce leakage screening. The entire bundle and receipt are intentionally gitignored and must not be force-added; tracked records expose only aggregate hashes, counts, and pass/fail evidence.
- Model evaluation: the corpus is cleared for unreviewed development use; exact-Mac execution remains blocked only until the executable V2 decision contract is sealed in a contract-only commit.
- Post-publication generator hardening: atomic exclusive output and same-byte parsing/hashing are enforced under live SHA-256 `7eee13f4bf14609f4e748ed4cab71ff6ade211688d85fddbcbfde51b0e1282bf`; the receipt binds historical sealed generator `ead3e1b9cbd6b9dad65092296de33e2c5baec716598b008d69d2bae2e8890a3b`, now preserved as the real immutable snapshot `scripts/eval/historical/generate_eg1_english_list_benchmark.ead3e1b9.py`.
- Current complete evaluator suite: 158/158 unittest-discovery tests, plus 181 pytest tests and 14 pytest subtests, passing.
