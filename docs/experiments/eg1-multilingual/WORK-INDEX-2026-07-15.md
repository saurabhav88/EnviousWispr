# EG-1 24-Hour Work Index

Status: paused checkpoint after the July 15-16 research run. This index separates measured results, infrastructure, and unfinished work.

Claude Code resume front door: `CLAUDE-CODE-SALVAGE-HANDOFF-2026-07-16.md`; GitHub owner: issue #1570.

## Bottom line

The run did not produce a release winner. It did establish that the old 93.7% headline is not a trustworthy real-world quality number, prompt-only list tuning is unsafe, the old 1,890-case Type B set is heavily contaminated, and the current training mixture is far too English-heavy and list-light to answer the multilingual question.

The strongest discovery candidate is Gemma 4 E4B on observed meaning safety, with Qwen3.5-4B retained as a technically compatible reserve. Current EG-1 remains the shipping baseline. None may be called a winner until the new public human-speech proxy exists and the exact same cases, prompt, runtime, and scoring path compare every arm.

## Measured findings

### Current EG-1 and its data

- Current EG-1 is Qwen3-4B-Instruct-2507 plus a rank-16 LoRA trained for two epochs on 5,656 mostly English examples.
- PEFT adapter: 126.1 MiB. Converted F16 LoRA GGUF: 63.0 MiB. Shipped merged Q5: 2.69 GiB.
- Only 259 training outputs are lists. Only three are two-item lists.
- The earlier multilingual smoke contributed only 40 synthetic, non-native-reviewed rows per non-English language; all 160 non-English rows were 2.74% of that mixture.

### Prompt-only list experiment

The fresh 75 positive plus 75 restraint comparison ran through the exact shipped-request Mac path.

- List activation: 52/75 baseline to 68/75 list prompt.
- Strict positive success: 11/75 to 15/75.
- Paired gain: four cases, `p=0.125`; it missed the predeclared eight-case minimum.
- False lists: 25/75 to 32/75.
- Positive scope loss: 15/75 to 23/75.
- Blind semantic review: 12/150 damaging prompt-arm outputs versus 8/150 baseline, including six prompt-only damaging cases.

Decision: reject prompt-only as the solution.

### Model discovery controls

| Candidate | Measured development signal | Decision |
|---|---|---|
| Gemma 4 E4B | Lowest observed meaning damage in the 56-case blind audit: 1/56, versus 5 for Qwen3.5 and 7 for untouched Qwen3 | Discovery leader; serious balanced-data experiment still justified |
| Qwen3.5-4B | Strong grammar/German signal; 5/56 damaging rows and weak untuned lists | Universal reserve |
| Qwen3.5-9B | 40/92 strict, 15 damaging edits, 7/16 Russian, 2/20 English two-item, 0/100 broad list activation | Stop; extra capacity did not solve the task |
| Current EG-1 | 8/56 damaging rows in the current multilingual audit; weak short-list activation | Keep as shipping baseline |
| Phi-4-mini | 11/20 English list signal, but 18/56 multilingual and 26/92 damaging edits | Reject |
| Ministral 3 3B | 30/92 strict, 24/56 multilingual, 5/16 Russian, 1/20 English two-item | Reject |
| EuroLLM-9B | 2/5 Spanish smoke outputs leaked internal wrapper text | Hard stop at smoke |

Two Gemma tuning recipes were also trained and evaluated. They improved parts of list shape but introduced scope or medical-timing damage, so neither advanced.

### Qwen language evidence

No statistically valid five-language strength ranking exists yet. The clean audit reran successfully with `ranking_status=insufficient_evidence` and 10/10 tests.

- Narrow current-EG-1 diagnostic: German 8/8, French 6/8, Spanish 2/8.
- Untouched Qwen3 changes sharply between prompt/review paths: German 0/8 versus 6/8, French 3/8 versus 6/8, Spanish 1/8 versus 3/8.
- Russian changes from 3/16 to 7/16 on the same cases when the prompt changes.

The only honest conclusion is that German currently looks strongest in a tiny diagnostic and the order is prompt-sensitive.

## Benchmark and leakage work

### Old Type B invalidated

- Exact overlap with training: 1,549/1,890.
- Conservative normalized overlap: 1,551/1,890.
- Provenance-family exposure: 1,866/1,890; conservative normalized-family exposure reaches 1,868/1,890.
- The 900 overflow rows are not a clean replacement: 899/900 share an exposed family.

### Type B V2 structure preserved

- Exact 1,890-case category, length, tier, and trap matrix retained.
- All 23 questionable provisional rows are replaced.
- 1,890 active assignments are balanced across 126 packets of 15; the custody ledger contains 1,913 primary/reserve records.
- Blocked registry covers 11,236 historical source rows, 7,198 opaque families, and 13,733 normalized text hashes.
- The exact-Mac gate already accepts a 1,890-case `type_b_v2` suite, but final public-speech content and Type B-specific freeze/scoring are not built.

### Fresh English list pilot

The separate 75+75 development pilot was fully leakage-audited. Its independent replay recomputed 5,028,900 comparisons with zero exact or high-similarity violations. It supported the prompt decision above; it does not replace Type B.

### Multilingual benchmark gate

The repository now has an adversarially tested 800-row development-authoring and rating gate, a power-driven frozen-size gate, family-clustered statistics, four-method leakage scanning, exact historical-receipt verification, and immutable rating inputs. The stronger human roster path passed its full fail-closed lifecycle, but founder direction now uses licensed public human speech because human authors/reviewers will not be available.

## Runtime and architecture proof

- One shared Q5 base plus five current-size F16 adapters is about 3.00 GiB total; five full models would be about 13.45 GiB and remains disqualified.
- One selected adapter can load offline with about 79 MiB additional idle memory and sub-second readiness. Two simultaneous adapters failed output isolation, so the safe fallback is one selected adapter plus a local server restart.
- Qwen3.5-4B LoRA compatibility was proven on AlienSV: 248/248 text modules, all 120 GDN placements, zero vision/MTP targets, exactly 32,464,896 trainable parameters, one optimizer step in 20.347 seconds, and a 129,927,008-byte adapter. This is compatibility evidence, not quality evidence.
- The final exact Mac/MPS fail-closed lifecycle passed in 1,061.131 seconds (17m41s). Production leakage evidence correctly stopped at `calibration_required_noncertifying`; synthetic evidence stopped at `synthetic_not_quality_evidence`; neither published evaluation output.

## Public human-speech pivot

The final work lane researched the replacement for unavailable human-authored benchmarks.

- Balanced five-language backbone: FLEURS plus MINDS-14, both CC-BY-4.0 and available in EN/DE/FR/ES/RU.
- FLEURS is broad but read speech; MINDS-14 is genuinely spoken but limited to banking and lacks public speaker IDs.
- English Type B recommendation: equal source allocation from held-out FLEURS, VoxPopuli parliamentary speech, and AMI meeting speech.
- Inputs should come from EnviousWispr's real ASR over the public audio. Public transcripts anchor semantic truth. List gold can be constructed from held-out speech fragments using predeclared templates without inventing item content.
- Important limitation: we can prove separation from Envious-held training/evaluation data, but cannot prove that Qwen's unknown base pretraining never saw public transcripts. “Leakage-clean” must be scoped accordingly.

No audio was downloaded, no public-speech row was selected, and no candidate output was generated before the pause.

## Engineering inventory

Draft PR: [#1562](https://github.com/saurabhav88/EnviousWispr/pull/1562), branch `codex/eg1-multilingual-overnight`.

At the pause checkpoint, the PR contains:

- 70 commits over `main`;
- 441 changed files;
- 86,003 added lines reported by GitHub;
- 41 top-level evaluation/training scripts;
- 29 evaluator test files;
- 10 tracked contracts;
- 336 experiment documents and machine-readable run/score/manifest receipts, including 212 AlienSV artifacts, 48 Mac-run artifacts, and 36 training artifacts.

The volume is mostly reproducible evidence: prompts, manifests, per-run outputs, hashes, scores, contracts, and test fixtures rather than application product code.

## Validation receipts

- Final integrated repository suite: 587 passed, 2 expected private-data skips, 118 subtests in 126.54 seconds.
- Calibration lane: 23/23 focused tests.
- Final authoring/scanner focused lane: 123 cases with one expected private skip before the real private run.
- Evaluator suite at final authoring bytes: 438 tests plus 92 subtests, three expected private skips.
- Canonical committed-diff reviews on final authoring and integration fixes reported no actionable defects. Review sandboxes could not bind local sockets; unrestricted suites passed those tests.
- Branch privacy incident was contained by rewriting the public feature branch, restoring the private corpus only under ignored storage, and verifying it absent from reachable public commits.

## Durable pointers

- Claude Code salvage handoff: `CLAUDE-CODE-SALVAGE-HANDOFF-2026-07-16.md`
- Founder readout: `FOUNDER-READOUT-2026-07-15.md`
- Complete chronological log: `OVERNIGHT-LOG-2026-07-15.md`
- Qwen language audit: `QWEN3-LANGUAGE-EVIDENCE-AUDIT-2026-07-15.md`
- Benchmark protocol: `MULTILINGUAL-BENCHMARK-V2-SPEC.md`
- Training design: `TRAINING-DATA-DESIGN-V2.md`
- Model scorecard: `MODEL-SCORECARD-V1.md`
- Qwen3.5 compatibility proof: `QWEN35-RESERVE-BF16-LORA-PREFLIGHT-2026-07-15.md`
- Web-speech pivot draft: `WEB-SPEECH-PROXY-BENCHMARK-V1.md`

## Not completed

- No statistically defensible Qwen five-language ranking.
- No release-quality model or prompt winner.
- No public-speech source contract or downloader is finalized.
- No 800-row web-speech development corpus or frozen corpus exists.
- No leakage-clean content exists for the new 1,890-case Type B proxy.
- No balanced final training dose has been generated or approved.
- No finalist has run the frozen, Type B V2, and exact shipped Mac sequence.
- No production packaging or user-facing model-selection work was started.

## Resume order

1. Finalize and test the pinned web-speech source contract. Resolve the exact 800-development/1,600-minimum-frozen allocation while preserving the existing harness and statistical power rules.
2. Build the metadata verifier and ignored downloader; freeze selection commitments before candidate output.
3. Run selected audio through the actual EnviousWispr ASR path and materialize development only.
4. Compare vanilla Qwen3, current EG-1, and prompt arms on the common development proxy.
5. Generate a balanced training-only dose and train Gemma primary plus Qwen3.5 reserve on AlienSV only if development evidence justifies it.
6. Lock one finalist, then open frozen once, run the 1,890-case Type B V2 proxy once, and finish with exact shipped Mac validation.
