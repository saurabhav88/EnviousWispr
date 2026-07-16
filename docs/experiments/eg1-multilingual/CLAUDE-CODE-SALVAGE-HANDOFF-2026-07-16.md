# EG-1 24-Hour Research Salvage Handoff

Status: paused, evidence preserved, no release candidate produced.

Audience: Claude Code or any engineer resuming EG-1 multilingual/list-quality work.

This is the front door for salvaging the July 15-16 research run. Read this before the 2,049-line chronological log. The purpose is to separate proven evidence from promising hypotheses, infrastructure that can be reused, work that should be discarded, and the shortest path to a measurable model improvement.

Related records:

- Dedicated salvage issue: GitHub issue #1570
- Running tracker: GitHub issue #1364
- Draft research PR: GitHub PR #1562
- Branch: `codex/eg1-multilingual-overnight`
- Full work index: `WORK-INDEX-2026-07-15.md`
- Full chronological log: `OVERNIGHT-LOG-2026-07-15.md`

## STATUS

- The overnight automation is paused.
- No training, ASR, benchmark-generation, or model-evaluation process is running.
- Current EG-1 remains the shipping baseline.
- There is no release winner.
- No public-speech audio was downloaded and no web-speech benchmark rows were selected.
- No frozen benchmark output was opened.
- The branch was clean and pushed at `e981909a` before this handoff update.
- PR #1562 is a draft and must not be merged as a product improvement. It is an evidence-heavy research branch.

## FOUNDER CONSTRAINTS

These are pass/fail requirements, not scoring preferences:

1. EnviousWispr must work fully offline after the initial model download.
2. Preferred architecture: one multilingual model for all supported languages.
3. Allowed fallback: one shared full base plus small, optional language LoRA adapters.
4. Disqualified: making a user download multiple full-size language models.
5. A larger single universal model is allowed; size is weighted after quality and architecture gates.
6. English remains primary. Initial multilingual priority is English, German, French, Spanish, and Russian.
7. Do not build product packaging or model-selection UI until a candidate beats the benchmark.
8. The larger leakage-clean Type B replacement remains the real gate; a quick pilot must not replace it.

## WHAT THE 24-HOUR RUN ACTUALLY DELIVERED

The run built a reproducible research lab and invalidated several bad assumptions. It did not produce a better downloadable model.

At pause, draft PR #1562 contained 70 commits, 441 changed files, and 86,003 additions. Most of that volume is prompts, manifests, hashes, row-level outputs, scorers, contracts, fixtures, and test receipts. Do not confuse repository volume with product progress.

## USE AS-IS

These conclusions are sufficiently supported for future work.

### 1. The old quality headline is not a held-out real-world score

- Shipping v2 training overlaps exactly with 1,549/1,890 old Type B rows.
- Conservative normalized overlap is 1,551/1,890.
- Provenance-family exposure is 1,866/1,890; normalized-family exposure is 1,868/1,890.
- The overflow set is also exposed by family on 899/900 rows.

Decision: never use 93.7%, 94.4%, or the old overflow result as proof of generalization or multilingual quality. They remain historical development results only.

### 2. Current EG-1's training mixture explains the observed gaps

- Base: `Qwen3-4B-Instruct-2507`.
- Tune: rank-16 QLoRA, two epochs, 5,656 mostly English examples.
- Only 259 training outputs are lists.
- Only three training outputs are two-item lists.
- The earlier multilingual smoke added only 40 synthetic, non-native-reviewed rows per non-English language. All 160 non-English rows were 2.74% of that mixture.

Decision: reliable short-list and multilingual behavior cannot be inferred from the current data dose.

### 3. Prompt-only list tuning is rejected

Exact Mac shipping-path A/B on 75 new positive-list plus 75 restraint cases:

| Metric | Shipping prompt | List prompt |
|---|---:|---:|
| List activation | 52/75 | 68/75 |
| Strict positive success | 11/75 | 15/75 |
| False lists | 25/75 | 32/75 |
| Positive scope loss | 15/75 | 23/75 |
| Meaning-damaging outputs | 8/150 | 12/150 |

- Paired strict gain was four cases, exact McNemar `p=0.125`.
- The sealed gate required at least eight net strict gains and `p<0.05`.
- Six meaning-damaging cases occurred only under the candidate prompt.

Decision: do not retune or ship the list-v2 prompt. Prompt changes may remain an experiment arm, but targeted training data is required.

### 4. Several base-model lanes are closed

| Model | Technical result | Decision |
|---|---|---|
| Qwen3.5-9B | 40/92 strict, 15 damaging, 7/16 Russian, 2/20 two-item, 0/100 broad list activation | Reject |
| Phi-4-mini | 18/56 multilingual; 26/92 damaging, including translations and identifier corruption | Reject |
| Ministral 3 3B | 30/92 strict, 24/56 multilingual, 5/16 Russian, 1/20 two-item | Reject |
| EuroLLM-9B | Internal wrappers leaked in 2/5 smoke outputs | Reject at smoke |

Decision: do not spend more training or Mac-runtime time on these exact model lanes without new contrary evidence.

### 5. Adapter storage and runtime are viable as a fallback

- Current PEFT adapter: 126.1 MiB.
- Converted F16 LoRA GGUF: 63.0 MiB.
- Merged Q5 model: 2.69 GiB.
- One base plus five current-size F16 adapters: about 3.00 GiB.
- Five full models: about 13.45 GiB.
- One selected adapter loaded cleanly with about 79 MiB additional idle memory and sub-second readiness.
- Simultaneously preloading two adapters failed output isolation.

Decision: if a universal tune fails, the technically viable fallback is one shared base plus exactly one selected adapter loaded at server start, with a local restart when switching. Do not preload multiple active adapters.

### 6. The exact Mac and evaluation safety gates work

- Final integrated suite: 587 passed, 2 expected private-data skips, 118 subtests in 126.54 seconds.
- Exact private Mac/MPS fail-closed lifecycle: 1,061.131 seconds, exit 0.
- Production evidence correctly stopped as noncertifying; synthetic evidence correctly stopped as not quality evidence; neither published an evaluation bundle.
- The fresh 75+75 prompt pilot recomputed 5,028,900 leakage comparisons with no exact or high-similarity violations.

Decision: preserve the exact request path, artifact identity, leakage checks, failure handling, paired scoring, and immutable receipts when simplifying the branch.

## USE WITH CAVEATS

These are useful leads or tools, not final conclusions.

### Gemma 4 E4B

- Lowest observed meaning damage in the small blind multilingual audit: 1/56.
- Current EG-1 was 8/56; Qwen3.5-4B was 5/56.
- Two trained Gemma recipes were rejected because they introduced scope or medical-timing damage.
- Gemma GGUF experiments were much larger: approximately 5.37-7.48 GiB depending on quantization.

Use: primary serious balanced-data experiment.

Caveat: call it the discovery leader, never a winner. Small development samples do not establish release quality.

### Qwen3.5-4B

- Small development signal was 5/56 damaging outputs with useful German/grammar behavior but weak lists.
- AlienSV compatibility was proven: 248/248 text modules, all 120 GDN placements, 32,464,896 trainable parameters, one optimizer step in 20.347 seconds, and a 129,927,008-byte adapter.

Use: reserve universal challenger because it is compact and trainable.

Caveat: the one-step adapter proves compatibility only. It is not a quality candidate.

### Language ordering evidence

- Tiny current-EG-1 diagnostic: German 8/8, French 6/8, Spanish 2/8.
- Russian moved from 3/16 to 7/16 on the same cases when the prompt changed.

Use: prioritize German after English and keep French, Spanish, and Russian in the first balanced comparison.

Caveat: no statistically valid five-language ranking exists. The observed order is small-sample and prompt-sensitive.

### Type B V2 structure

- The 1,890-slot category/length/tier/trap matrix is preserved.
- It has 23 replacement reserves, 126 packets of 15, and 1,913 custody records.
- The blocked registry contains 11,236 source rows, 7,198 families, and 13,733 normalized text hashes.

Use: retain the allocation and contamination registry.

Caveat: the content, public-speech source selection, Type B-specific scorer, and final freeze do not exist.

### Authoring/calibration machinery

The 800-row human-authoring, four-role custody, leakage, ratings, power, and calibration paths are technically hardened.

Use: salvage its immutable-input, family-isolation, rating, and fail-closed patterns.

Caveat: the founder removed human authors/reviewers as an operational dependency. Do not restart the large human-roster workflow. Adapt the useful controls to licensed public speech.

## DO NOT USE

Do not carry these claims or approaches forward:

- The old 93.7%/94.4% result as held-out accuracy.
- The old Type B or overflow corpora as sealed release benchmarks.
- The list-v2 prompt as a production fix.
- Multiple complete language-specific model downloads.
- Simultaneous multi-adapter preloading in the current llama-server path.
- The human four-role authoring workflow as the current benchmark plan.
- Synthetic or model-judged calibration thresholds as production certification.
- The Qwen3.5 one-step adapter as a trained candidate.
- The 40-rows-per-language smoke as evidence that universal multilingual tuning works or fails.
- Any claim that Gemma has won, German support is proven, or the five languages have a stable quality ranking.
- Any rejected Gemma checkpoint; both failed meaning/scope safety.
- Any repeated prompt hand-tuning on the sealed 75+75 cases.

## PUBLIC HUMAN-SPEECH BENCHMARK DECISION

Because native human authors/reviewers are unavailable, use licensed public speech as the next-best reproducible proxy.

### Common five-language benchmark

- Backbone: FLEURS plus MINDS-14.
- Languages: EN, DE, FR, ES, RU.
- FLEURS provides broad topics and reference transcripts but is read speech.
- MINDS-14 provides genuinely spoken queries but is banking-only and has no public speaker IDs.
- Run public audio through EnviousWispr's real ASR. The ASR output is the polish input; the public transcript anchors content truth.

### English Type B replacement

- Recommended source split: 630 held-out FLEURS units, 630 VoxPopuli units, 630 AMI IHM meeting-speech units.
- Preserve the existing 1,890-case Type B matrix.
- List cases may combine 2-5 held-out speech fragments under predeclared list-cue templates, while keeping every component source family attached for leakage control.

### Required caveat

We can prove separation from Envious-held training and evaluation data. We cannot prove that public transcripts were absent from the unknown pretraining corpus of a base model such as Qwen. State this limitation in every release claim.

## MISSING WORK

The following deliverables do not exist yet:

1. Final pinned source/revision/license contract for the web-speech datasets.
2. Tested metadata verifier and ignored audio downloader.
3. Materialized 800-row multilingual development proxy.
4. Sealed minimum 1,600-row multilingual frozen proxy.
5. Public-speech content and dedicated scoring for Type B V2.
6. Comparable vanilla Qwen3, current EG-1, prompt, Gemma, and Qwen3.5 runs on one common development set.
7. A serious balanced training-only corpus.
8. A promoted model candidate.
9. One-time frozen, Type B V2, and exact shipped-Mac finalist results.
10. Production packaging or language-selection UI.

## SHORTEST SALVAGE PATH

Do this in order. Do not add more research lanes until this produces comparable model numbers.

1. Finalize FLEURS + MINDS-14 source revisions, licenses, selection rules, family keys, and source hashes.
2. Materialize development only: 160 cases per language, 800 total. Keep frozen selections committed only by private seed/hash and do not generate candidate outputs for them.
3. Run the 800 public audio cases through the real EnviousWispr ASR path.
4. Compare, on identical inputs and scoring, only these initial arms: vanilla Qwen3, shipping EG-1, the already-rejected prompt as a control, untouched Gemma, and untouched Qwen3.5-4B.
5. Use the result to create one balanced training-only dose covering language, list length, restraint, corrections, identifiers, numbers, medical timing, and no-op preservation.
6. Train exactly two candidates in parallel on AlienSV: Gemma primary and Qwen3.5-4B reserve.
7. For each recipe, run one smoke and one full development benchmark. Stop any recipe that does not improve the target without meaningful safety regressions.
8. Lock one finalist. Only then materialize/open frozen outputs and run the new 1,890-case Type B once.
9. Run the survivor through the quantized exact shipped Mac path.
10. Only after a benchmark win, design packaging or adapter-selection UX.

## STOP RULES

- One smoke plus one full development run per exact recipe.
- No repeated tuning against frozen, Type B, or the sealed 75+75 prompt pilot.
- No aggregate headline may hide a failing language or safety slice.
- Meaning, scope, names, identifiers, numbers, negation, corrections, and timing are hard safety gates.
- If neither serious universal tune wins, then test one shared-base-plus-selected-adapter fallback. Do not jump to multiple full models.

## DEFINITION OF THE NEXT MEANINGFUL RESULT

The next update should not be another infrastructure count. It should be one comparison table showing the same 800 public-speech development cases run through the five initial arms, with per-language list success, restraint/false-list rate, meaning/scope damage, inference failures, paired uncertainty, exact prompt/artifact identity, and raw-output receipts.

That table is the decision point for whether to train Gemma, Qwen3.5-4B, both, or neither.

## FILE MAP

| Need | File |
|---|---|
| Concise full-run index | `WORK-INDEX-2026-07-15.md` |
| Founder-readable summary | `FOUNDER-READOUT-2026-07-15.md` |
| Every chronological experiment receipt | `OVERNIGHT-LOG-2026-07-15.md` |
| Web-speech benchmark design | `WEB-SPEECH-PROXY-BENCHMARK-V1.md` |
| Five-language benchmark contract | `MULTILINGUAL-BENCHMARK-V2-SPEC.md` |
| Training data design | `TRAINING-DATA-DESIGN-V2.md` |
| Model comparison | `MODEL-SCORECARD-V1.md` |
| Qwen language evidence | `QWEN3-LANGUAGE-EVIDENCE-AUDIT-2026-07-15.md` |
| Qwen3.5 LoRA compatibility | `QWEN35-RESERVE-BF16-LORA-PREFLIGHT-2026-07-15.md` |

## BRANCH HANDLING

PR #1562 is too broad to treat as a product PR. GitHub issue #1570 owns the salvage and next benchmark result. Claude Code should first use this handoff to identify the smallest benchmark and runner subset worth preserving. It may then either reduce/split #1562 or replay the selected files onto a fresh branch from current `main`. Do not merge all 441 files merely because the test suite is green.
