# Issue #1570 — EG-1 English retrain #1: lists, formatting, restraint — 2026-07-16

Status: **APPROVED — Codex grounded review PROCEED-AS-PLANNED after 3 rounds (2026-07-16).** Council replaced by Codex (web-enabled) per founder directive because the plan hinges on live dataset-license facts. Stable sections from Codex overnight research (read, not re-derived) + eg1-model-provenance + Fluid-1 teardown. All six round-#1 dataset licenses independently web-verified (audits: `docs/audits/2026-07-16-eg1-english-retrain-grounded-review{,-r2,-r3}.txt`).

## Preface — Lane + Live UAT declaration
- Primary lane: **Eval-harness** (data generation + training + scoring under `scripts/eval/`), gitignored training data (`Docs/dev-tooling`). Final artifact swap is a separate **distribution** step (manifest bump / R2), NOT in this plan's first PR.
- Live UAT: **Y** at the artifact-swap step only (dictate real spoken lists through the running app; verify bullet output + no meaning damage). The data/training/eval phase is graded on the frozen corpora, not the app.
- User Rubric: English-primary power user who dictates lists/emails/notes.

## Workflow-stage authority
Issue #1570 currently requires the common 800-case public-speech comparison before new model training. This English retrain may enter Gate 2 / a full training run only after either:
1. that comparison is complete; or
2. the founder posts an explicit sequencing override and updates issue #1570's acceptance criteria.
The founder verbally directed English-first sequencing (session 2026-07-16). ACTION: record that override on #1570 before creating the accepted training corpus or starting training. Until #1570 is updated, this plan may complete sourcing, licensing, corpus design, source ingestion, and generator implementation, but must not materialize or accept the balanced training corpus, start any training run, or make a ship claim.

## 0. TL;DR
Fix EG-1's three measured English weaknesses — under-activation of genuine lists (esp. two-item/scoped), leftover spoken-command residue, without breaking its currently-strong restraint — by adding ~1,000 public-source-grounded, balanced English training pairs to the existing set and retraining the SAME base (Qwen3-4B) on the SAME shipped prompt via the documented QLoRA recipe. Grade the quantized artifact on the frozen English sets. Ship as a weights-only EG-1 update if it clears the predeclared bar.

## 1. Problem
Users report EG-1 is weak at exactly what makes cloud polishers popular: turning spoken lists into clean bullets and formatting email/notes structure. Codex's overnight scan makes training-data starvation the leading testable hypothesis: list examples are scarce, two-item lists are nearly absent, and prompt-only tuning caused regressions. Retrain #1 tests that hypothesis. It does not yet prove that the Qwen3-4B base has no relevant ceiling.

## 2. Goals & non-goals
### 2.1 Goals
- Raise genuine-list activation (esp. two-item + scoped-implicit) measurably (defined in §11).
- Remove leftover spoken formatting commands.
- Hold restraint (do not convert ordinary prose to lists) — currently ~100%.
- Keep core English polish non-inferior (lower bound > -2pp).
- Keep the same base + same shipped prompt + same download size (~2.7GB) → clean weights-only hot-swap.

### 2.2 Non-goals
- Multilingual (retrain #2, on top of this).
- Base-model switch (Gemma etc. benched unless this plateaus).
- Prompt-contract change (behavior in weights; promptTemplateID unchanged).
- Building the full public-speech benchmark lab (rejected over-engineering).

## 2.5 Grounding brief (evidence, read not re-derived)
**Weakness diagnosis (Codex overnight, OVERNIGHT-LOG DATA-004 / EVAL-005/006/007):**
- 259/5,656 training outputs are lists; item skew: 2-item=**3**, 3=179, 4=25, 5=30, 6=2, 7=19, 8=1.
- 80 `LF-*` + 80 `LFT-*` rows leaked from the old benchmark into training → old 94-95% headline is contaminated (82% family overlap), NOT held-out quality.
- Current EG-1 + shipped prompt: positive-list activation 72/100, 71/100 strict; two-item activation 11/20. UNDER-activates.
- Restraint currently strong: 100/100 restraint, 98/100 strict on the 100-trap set.
- Prompt-only "list-v2" boosts activation (86/100) but damages meaning, loses scope, leaves command headers, REGRESSES restraint → behavior must be trained into weights at prompt parity.

**Training pipeline (eg1-model-provenance, #1265):** Base Qwen3-4B-Instruct-2507; QLoRA (Unsloth, r16/a32, lr 5e-5, 2 epochs, response-only loss) on the RTX 4090 ($0); merge → GGUF → Q5_K_M → judge the QUANTIZED artifact. Training prompt MUST equal shipped prompt (drift = ±18pp). Weights-only update keeps promptTemplateID → hot-swap.

**Ceiling context (Fluid-1 teardown):** competitor ~100k real dictations; realistic internal target 20-50k; per-behavior we are near-zero on lists → high buffer, cheap first win.

**Single-authority / negative claims:** eval harness `scripts/eval/` is the ONLY polish eval harness (never fork); new data + scorers extend in place. All new training pairs must be family-disjoint from the frozen eval sets (exact + token + char-ngram + embedding screen) — reuse the existing scanner.

## 3. Design
### 3.1 Approach
Add ~1,000 balanced English pairs (dropping the ~160 leaked `LF-*`/`LFT-*` rows so we don't re-contaminate the eval), retrain per the documented recipe under the CURRENT shipped prompt, quantize, grade on frozen sets.

New English 1,000 stratification (TRAINING-DATA-DESIGN-V2, adopted):
- 400 positive lists — item counts 2/3/5/7 balanced; list types (explicit bullets, explicit numbering, scoped-implicit, bare-label, correction/format-command) balanced; domains (work, personal, technical, medical, legal) balanced; lengths balanced.
- 400 matched prose-restraint — each paired to a positive family, same domain/length/difficulty; types: incidental enumerations, narrative sequences, compound nouns ("laptop charger"), quoted content, alternatives/contrasts, shared modifiers, two-item policy-boundary prose.
- 200 core polish — filler removal, self-correction, punctuation, entity/number/date preservation, minimal edit.
Persona slice (Finding 3): ≥100 of the 1,000 must be email-shaped and ≥100 note-shaped, under the same list/restraint balance and preservation rules.

### 3.2 Data sourcing — license rule (Codex web-verified r1; round #1 GREEN-with-conditions only)
Pin the exact source release/revision, download URL, file hashes, and license snapshot before ingestion. A source-level allowlist controls acceptance; a dataset name alone is not proof. Two paradigms: **(A) Degrade** real structured GOLD → synthesize messy spoken input; **(B) Minimal-clean** real spoken transcript INPUT → minimally-edited output that STAYS prose.

- **OASST1/OASST2 — GREEN with notice:** Apache-2.0. Carry license + applicable NOTICE attribution in the training-source notice bundle and model card. Filter quotations, code, PII, suspected third-party text. (GOLD — lists/emails/steps + prose negatives.)
- **AMI — DROPPED from round #1 (empirical, 2026-07-16).** License is fine (CC-BY-4.0, covered material only), but the content is unfit for this task. Evidence: streamed 4,000 real `ihm` utterances and extracted the 245 matching enumeration/narrative patterns; they are ALL-CAPS, fragmentary, conversational meeting cross-talk about research logistics (e.g. "'CAUSE IF WE'RE GONNA ALLOW DISJOINT SEGMENTS FOR EXAMPLE THEN HOW ARE WE GONNA KNOW WHAT'S GONNA BE IN CONTEXT", "WHEN DO WE HAVE TO MEET AGAIN THEN WITH THIS") — not a person dictating a note/email, and not the "ordinary sentence with an incidental enumeration" restraint shape we need. This confirms grounded-review r1 Finding 3 ("AMI is mostly scenario-based meeting speech… none directly represents an English power user dictating"). Restraint input for round #1 comes from OASST prose instead (empirically strong — see the 7-inline-item canvas-libraries case kept correctly as prose). Dropping AMI also removes its attribution obligation. Raw evidence: `ami_restraint_raw.json` (245 utterances). Re-evaluate AMI only if a dictation-shaped subset is identified.
- **VoxPopuli — GREEN with restrictions:** use only VoxPopuli DATA/transcripts; NOT its CC-BY-NC code/pretrained models/separately-licensed LM data. Carry European Parliament source attribution + complete source URL (obligation, not request). (INPUT — spoken lists, cleanup.)
- **Common Voice CV11–CV16 — GREEN with access conditions:** pin the precise release, accept its terms, never attempt speaker identification, strip speaker IDs/demographics, do not redistribute the raw corpus. (INPUT — single-sentence prose negatives.)
- **FLEURS — LICENSE-GREEN BUT TRAINING-EXCLUDED:** reserve ALL FLEURS rows for the future public-speech EVAL lane so that benchmark stays disjoint. Not a training source.
- **GovInfo — PER-DOCUMENT YELLOW:** accept only material verified as authored by a federal employee within official duties, containing no third-party/contractor/transferred-copyright/covered-faculty/state-local/separately-licensed material. Record originating agency + verification basis per document. (GOLD — agendas/checklists, used sparingly with per-doc clearance.)

**Deferred/excluded:** AESLC/Enron requires actual rights clearance (founder approval alone insufficient — third-party email copyright + privacy). Stack Exchange excluded (CC-BY-SA attribution/share-alike + current AUP bars automated ML collection; note: license is by contribution date, there is no July-2024 cutoff). WikiHow excluded (CC-BY-NC-SA, non-commercial). TED-LIUM excluded (BY-NC-ND).

**Slice → source map (round #1, ~1,000 pairs):**
| Slice | Count | Paradigm | Input | Gold |
|---|---:|---|---|---|
| "Make a list" | 400 | A degrade | synthesized spoken | OASST bullet/numbered answers + per-doc-cleared GovInfo |
| "Keep as prose" (matched restraint) | 400 | A degrade | synthesized spoken (from OASST prose gold) | OASST prose answers with in-line enumerations, normalized |
| General cleanup | 200 | A degrade | synthesized spoken | OASST prose, normalized — **OPEN:** inspect whether Common Voice / VoxPopuli read-speech actually adds value here, or carries the same not-dictation-shaped problem AMI did. Do not assume; inspect before adopting. |

**Round #1 is effectively single-source (OASST, Apache-2.0)** after the AMI drop. Benefit: one license, no attribution obligation, smallest surface. Risk: OASST is chat/assistant register, so the r1 Finding-3 realism concern now concentrates in one source — the >=100-pair stratified realism audit and the acceptance judge are the guards, and the corpus stays labelled "public-source-grounded," never "real-dictation-grounded."

**W4 design guard:** the 400 restraint cases must be *matched* to the 400 list cases on surface trigger words ("and","then",commas,"first/second") so the model learns the boundary, not a keyword. AMI is the highest-value negative source.

### 3.3 Generation + acceptance
**Source realism rule:** call this corpus "public-source-grounded," not "real-dictation-grounded." OASST = chat-style clean text; AMI = mostly scenario-based meeting speech; Common Voice/VoxPopuli = read/formal speech. Before acceptance, manually audit a stratified sample of ≥100 generated pairs for ASR-reachable input, realistic dictation phrasing, minimal edits, semantic fidelity, source-style artifacts. Reject + regenerate any stratum with >5% material failures.

**Pair acceptance contract:** every accepted row records source name, exact release/revision, source document ID, source URL, source-text hash, license snapshot hash, generation-model ID, generation-prompt hash, stratum, and an **`ambiguity: obvious | grey`** label assigned at authoring time before any candidate output exists (RULE: obvious-perfect-low-FP-grey-tolerant — the label is what makes grey-tolerance honest rather than a post-hoc excuse; it can never be changed after seeing a result). Acceptance requires: source-document dedup; PII/secret screening; removal of quotations, code, lyrics, embedded third-party material unless separately cleared; exact preservation of entities, numbers, dates, negation, scope, attribution, obligations; no newly generated medical/legal advice; no teacher commentary or formatting-command residue in the gold output. Both input and output sides screened. English needs NO native-human roster (multilingual concern; overnight custody machinery out of scope).

### 3.4 Prompt parity — SETTLED (founder 2026-07-16)
Train + infer against the CURRENT shipped prompt. Behavior in weights; promptTemplateID unchanged; clean hot-swap. (Rejected: adopting list-v2 as a new prompt contract — the overnight A/B showed prompt-only changes damage restraint + add residue + force a code-lane prompt-family change.)

## 3a/3b/3c — placement / ownership / single-authority
No new app module or coordinator; no runtime ownership change. The model artifact is the only shipped surface, swapped via the existing hot-swap contract. Single-authority: eval harness stays sole scorer; leakage screen sole disjointness gate; §11 is the sole decision contract.

§3c-answer: N/A — self-contained; reuses scripts/eval as the sole scorer/generator home and the existing scan_eg1_multilingual_development_leakage.py as the sole disjointness gate; §11 is the sole go/no-go authority. Nothing new to consolidate; no parallel scorer, benchmark, or custody machinery added.

## 4-9 Runtime state / lifecycle / consumer / failure-mode / signals / fallback audits
**N/A — no app-runtime state change.** Training-data + model-weights change. The generate → screen → train → merge → quantize → judge pipeline is an offline dev flow with no in-app FSM, async runtime edge, or caller-visible signal change. The eventual artifact swap rides the already-audited EG-1 hot-swap + model-delivery contract, whose lifecycle audits are owned there; this plan makes no prompt/template change.

## 10. Mechanism — reuse what exists, verify what's assumed
**Reusable (overnight branch), with honest status:**
- English-list data: `generate_eg1_english_list_benchmark.py` (+ `eg1_english_list_contract.py`, `assemble_eg1_english_list_pilot.py`). Currently generates synthetic DEVELOPMENT candidates, manifest `training_eligible: false` (`generate_eg1_english_list_benchmark.py:839`). EXTENDING it to produce grounded TRAINING pairs from the web sources is NEW work, not already-proven behavior.
- Scorers (proven for scoring): `score_eg1_english_list_ab.py` (net gain ≥8, McNemar p<0.05, zero new restraint false lists, no increased item/scope loss — `:230`), `score_two_item_lists.py`, `score_list_structure.py`, `score_eg1_english_list_novel.py` (self-declares NOT semantic/release proof — `:2`), blind-review tooling for the semantic gate.
- Leakage scanner: `scan_eg1_multilingual_development_leakage.py` — exact + token-ngram + char-ngram + 4-axis embedding, input↔input/output↔output/cross (`:70`,`:785`). **Correction:** production backend returns `calibration_required_noncertifying` (`:858`), NOT an automatic pass/fail gate. Before corpus generation, add only the minimum schema/role adapter for English training rows and calibrate production thresholds against known positive/negative overlaps. A `calibration_required_noncertifying` receipt is not a passing leakage gate. Screen both sides + exact source-document and semantic-family IDs.

**Training script — grounded status:** no separate trainer proven to have produced shipped EG-1 is committed in this checkout; `runs/bakeoff-1265/train_sft_v2.jsonl` is present but gitignored. The committed `train_eg1_multilingual_qlora.py` already matches the named #1265 headline settings (lr 5e-5, 2 epochs, r16/a32, seed 1265 — `:100`), older-Qwen 4-bit QLoRA with attention+MLP targets (`:1289`), and response-only masking (`:1409`), but it has NOT reproduced the shipped Qwen3 artifact. Before full training: recover the rig invocation + environment receipt, diff every effective parameter and package version, run the trainer's preflight, and perform one small reproduction smoke. Use it only if that comparison is exact or every difference is explicitly approved.

**New/edited files (round #1):** web-source ingest + extended generator (training mode) under `scripts/eval/`; new gitignored training jsonl (augmented corpus); calibrated leakage receipt; training invocation (proven recipe, rig, after reproduction smoke); scoring invocations on frozen sets. At SHIP only: manifest/version bump for the weights-only swap (separate PR, distribution lane).

## 11. Testing / eval — predeclared go/no-go bar (SOLE decision authority)
Run the exact shipped prompt, chat template, llama.cpp runtime flags, and quantized Q5_K_M artifact. Record prompt hash, GGUF hash, runtime build, flags.

**Primary endpoint:** on the existing 75-case positive-list A/B set, candidate strict wins minus losses ≥ 8 and two-sided exact McNemar p < 0.05.

**Mandatory safety gates:**
1. Two-item activation improves over the current 11/20, with NO candidate-only item/scope/entity/number/timing/negation/attribution/obligation loss.
2. **Scoped to the OBVIOUS restraint slice only** (founder directive 2026-07-16 — polish-eval.md RULE: obvious-perfect-low-FP-grey-tolerant): zero candidate-only false lists on OBVIOUS restraint cases; total false lists ≤ baseline; restraint strict ≥ 98/100 measured over OBVIOUS only. **GREY restraint cases (genuinely either-way, e.g. an ambiguous three-action boundary like the overnight run's `LFT-040`) are reported as an observation and NEVER fail the gate.** Every restraint case is labelled OBVIOUS or GREY at authoring time, before any candidate output exists; a case cannot be reclassified as GREY after seeing a result. Formatting judgement may be grey; preservation (gate 1) may not.
3. Blind semantic review: zero candidate-only S3/S4 failures; no increase in S2+ failures.
4. Core-polish non-inferiority: lower bound of the paired 95% bootstrap CI for candidate−baseline > -2pp on the FROZEN core-polish set.
5. Frozen email/note persona slice: no candidate-only S3/S4 damage; no structural regression.

**Seeds:** train 1265, 1266, 1267. Seed 1265 is the predeclared shipping candidate; 1266/1267 test robustness and may not be used to cherry-pick a winner. All three must clear the safety gates. Only seed 1265 is opened on the final release set, once.

**Development vs release evidence (Finding 5):** the existing 75+75 / positive-100 / restraint-100 / two-item sets remain DEVELOPMENT + regression gates (already inspected during diagnosis). Before training starts, freeze ONE small final English RELEASE set from UNUSED source documents/families using the existing generator, scorer, and blind semantic-review flow — no new custody system. Do not inspect candidate outputs on it until the recipe + shipping seed are fixed. It must include lists, matched restraint, core cleanup, and email/note dictation.

**Final release-set contract:** before training starts, pin its row count, slice counts, source-family IDs, corpus hash, scorer versions, and exact pass rule. This set is a one-time confirmation, not a second primary endpoint. Seed 1265 passes only if strict list wins exceed losses; there are zero candidate-only false lists **on OBVIOUS restraint cases** (GREY cases are reported, never fail — RULE: obvious-perfect-low-FP-grey-tolerant); zero candidate-only item, scope, entity, number, timing, negation, attribution, or obligation losses (**preservation is absolute and never grey**); zero candidate-only S3/S4 failures; no increase in S2+ failures; and no structural regression on core-cleanup or email/note rows. Every release-set case carries its OBVIOUS/GREY label from authoring, fixed before any candidate output is generated. Otherwise, do not ship.

Live UAT at swap: dictate real spoken lists through the app; confirm bullet output + no damage + latency < budget.

## 12. Blast radius, telemetry, and rollback
The artifact change introduces no transcript or list-content telemetry. Existing non-content telemetry must be segmented by model revision and watched for polish completion, local-polish-not-ready, inference failure, timeout, latency, download/admission failure, and user rollback/removal signals.

Rollback keeps the current artifact revision immutable and available. If the new revision fails, ship an emergency TRUSTED manifest/app update pointing to the prior shard set and hashes (manifests are bundled trust roots — rollback is not a bare manifest repoint). Never overwrite model objects in place or reuse paths with changed bytes. The delivery kill switch stops byte mutation; it is not a model-version rollback. (Matches hot-swap contract: eg1-operations.md:28, model-delivery.md:13.)

## 13. Ship criteria
Section 11 is the single go/no-go authority. Ship only when its primary endpoint, every safety gate, three-seed robustness rule, exact-runtime check, and final release-set check pass. If any gate fails, do not ship. Adjust one declared data variable, run one smoke, then one full three-seed recipe. Do not create a second scorer, benchmark authority, or parallel decision table.

## 14. Open questions
- **[FOUNDER, gating corpus materialization + training]** Record the English-first sequencing override on #1570 (per Workflow-stage authority). Does not block sourcing, licensing, corpus design, source ingestion, or generator implementation; DOES block materializing/accepting the balanced training corpus and any training run.
- Drop vs replace the ~160 leaked `LF-*`/`LFT-*` rows? Lean: drop for round #1.
- [DEFERRED — founder call] Enron/AESLC for extra W2 email density in round #2 (needs real rights clearance, not just approval).
- Teacher model for synthesizing the messy-input side: reuse v2 teacher (gemini-2.5-flash) or a stronger current model? Negligible API cost (existing credits).

## 15. Related
Issue #1570, #1364; PR #1562 (evidence branch, do not merge); eg1-model-provenance, eg1-operations, model-delivery, TRAINING-DATA-DESIGN-V2, OVERNIGHT-LOG DATA-004/EVAL-005/006/007; grounded review r1: `docs/audits/2026-07-16-eg1-english-retrain-grounded-review.txt`.
