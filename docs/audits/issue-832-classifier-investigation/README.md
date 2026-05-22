# Issue #832 — AFM Instruction-Execution: Classifier Investigation

**Status:** investigation complete, architecture converged, one feasibility gate open.
**Date:** 2026-05-21. **Issue:** [#832](https://github.com/saurabhav88/EnviousWispr/issues/832).

This folder is the complete research trail for the third (and current) approach to #832. It
supersedes the first two approaches recorded on the issue thread (a downstream detector, and
AFM polish-prompt tuning).

---

## 1. The problem

On-device "AI Polish" uses AFM (Apple Foundation Models, `FoundationModels` framework). It is
meant to lightly clean a dictated transcript. Instead, ~1 in 3 command-shaped dictations
("draft a Slack to Matt...", "tldr this thread", "make this warmer...") get **executed** — AFM
composes / translates / summarizes instead of transcribing the spoken words. Founder-flagged
Tier-1: the app types something the user never said.

## 2. What was tried and ruled out

| # | Approach | Result | Ruled out because |
|---|---|---|---|
| 1 | Downstream rule detector (artifact shapes) | 5/21 holdout recall | Overfit; see issue thread 2026-05-21 |
| 2 | Input-side rule/regex command detector | 27/27 tuning, 5/21 holdout | Rules cannot enumerate open-ended phrasing |
| 3 | AFM polish-prompt tuning | 7 variants benchmarked, all fail | AFM ignores "do not execute" — see §3 |
| 4 | AFM as a zero-shot classifier | precision 12%, recall 57% | AFM too weak at instruction-following |

## 3. The prompt benchmark (`01-prompt-benchmark/`)

A 315-case stress corpus (`corpus-315.jsonl` — 21 categories × 15, including 15
`anti_instruction_command` real commands and 15 `anti_instruction` hard-negative traps). Seven
AFM polish prompts plus the full production pipeline were run through real on-device AFM and
scored by Codex one arm at a time against a human-satisfaction rubric.

| Arm | Score | Notes |
|---|---|---|
| E — v32-Single (ChatGPT) raw | 243/315 (77.1%) | best prompt |
| Production pipeline | 241/315 (76.5%) | router + filter + fallback + #832 guard |
| B — Candidate-v2 raw | 238/315 | |
| Prod-E-Lite (1 prompt, prod shell) | 237/315 | GPT's experiment — lost |
| A — current prompt raw | 231/315 | |
| D / F / C | 167 / 166 / 78 | |

**Core finding:** no prompt solves instruction-execution. On `anti_instruction_command` every
arm scored 3-9/15. Prompt tuning is a dead end. Scoreboard: `01-prompt-benchmark/afm-benchmark-scoreboard.html`.
Run files `run*.jsonl`, Codex verdicts `codex-judgments/*.json`, candidate prompts `prompts/`.

## 4. The classifier probes (`02-classifier-probes/`)

The command-vs-dictation decision was reframed as a classification task.

- **AFM as classifier** (`classifier-prompt.txt`, `runClassifier.jsonl`): precision **11.9%**,
  recall 57%. AFM cannot classify its own failure mode — the same instruction-following
  weakness that causes #832.
- **Frontier models as classifier** (`cloud-classifier-prompt.txt`, `cloud-classifier-output.json`):
  GPT-5.5 and Gemini-3.1 BOTH scored **15/15 commands caught, 0/300 false alarms** — perfect,
  zero-shot, including all 15 hard-negative traps.

**Conclusion:** the command/dictation boundary is clean and learnable. The rule detectors did
not fail because the task is ambiguous; they failed because rules cannot enumerate phrasing.
AFM did not fail because the task is hard; it failed because AFM is a weak instruction-follower.

### Output-side validation probes (results in §6 of this README)

- **Novel-word diff** (words AFM's output added vs the dictation): catches *generative*
  execution (composed messages, translation, code — 18-66 novel words) but is blind to
  *transformative* execution (summarize / soften / tldr — ~0 novel words). 6/15 commands
  produced zero novel words.
- **Bidirectional diff** (novel words OR missing input words): catches 11-12/15 commands but
  **false-fires on ~24% of normal dictation**, because legitimate polish also changes tokens
  ("five pm"→"5 PM", "support at gmail dot com"→"support@gmail.com", homophone fixes,
  self-correction collapse). Killed as an always-on mechanism.

## 5. Council review (`03-council/`)

Three rounds, GPT-5.5 + Gemini-3.1, converged.

- Round 1 — classifier design approach. Both proposed output validation as the safety boundary.
- Round 2 — empirical findings fed back; the novel-word hole surfaced.
- Round 3 — bidirectional probe results; full convergence on the final architecture.

There is also a council review of the now-superseded deterministic-cleaner epic
(`deterministic-failsafe-epic-council.md`) and the superseded epic bible itself
(`05-superseded-deterministic-failsafe-epic.md`).

## 6. Codex grounded review (`04-codex-architecture-review.md`)

`codex exec`, read-only, against the real codebase. Verdict: **PROCEED-WITH-REVISIONS**.
Architecture is structurally sound and fits the code; 5 revisions:

1. Classifier runs **serially before AFM** — Apple's `FoundationModels` API has no
   abort/cancel, so council's "run concurrent, abort AFM" is not possible. Cost is negligible:
   a warm classifier is ~2ms against AFM's 10s polish budget.
2. Classifier lives in `EnviousWisprPostProcessing`, wired from `LLMPolishStep` (not from
   `EnviousWisprLLM` — dependency direction).
3. Novel-words-only guard is a **separate** new sub-check in `EnviousOutputFilter`; the
   existing bidirectional divergence check must NOT be promoted to always-on.
4. Define the fallback precisely — by the time polish runs, the text is already
   filler-stripped; `filterFellBackToRaw` metadata needs renaming.
5. **Biggest risk: classifier cold-start.** The "~2ms" is warm only. A lazy Core ML / embedding
   load on the `@MainActor` paste path can stall the app (the codebase was burned by this with
   WhisperKit). The classifier must be pre-warmed, with single-flight protection and failure
   caching.

## 7. The converged architecture

```
ASR raw transcript
  → upstream pipeline steps (word correction, filler removal, emoji)
  → on-device command/dictation classifier  [primary detector, runs in LLMPolishStep]
       command / uncertain / non-English / OOD / classifier unavailable
                                          → deterministic cleaner output
       dictation                          → AFM polish
                                              → novel-words-only output guard
                                                   high novelty → deterministic cleaner
                                                   else         → AFM output
```

- **Primary detector** = a small on-device classifier (command vs dictation). Candidate build:
  Apple `NLEmbedding` sentence embedding + logistic-regression head → Core ML; fallback build
  is a distilled MiniLM-class Core ML transformer (~15MB). Trained offline by distilling
  frontier-model labels. On-device, free, private, no network.
- **Backstop** = novel-words-only output guard. Deterministically catches high-novelty
  generative execution / hallucination at ~1% false-fire. Honest naming: a hallucination
  detector, not a complete command detector.
- **Fallback** = deterministic non-LLM cleaner for everything uncertain.
- **Telemetry** = privacy-safe counters (fallback-trigger rate, length-deviation anomaly
  counter) so the real #832 rate is observable in production without logging dictation text.

**Residual risk (accepted):** a classifier false-negative on a transformative command — the
novel-word backstop will not catch it (transformative execution adds ~0 novel words). Bounded:
the output is still the user's own content reworded, not an invented message; the catastrophic
generative case is deterministically caught by the backstop.

## 8. Open gate — classifier feasibility probe (not yet run)

The one unproven question: can a classifier small enough to run on-device hold the
hard-negative boundary ("translate this" vs "he asked me to translate this")? Frontier models
do it perfectly; a ~100KB on-device model is the open question.

Probe design (council-specified): generate ~800 labeled examples including hard-negative
minimal pairs via frontier models (offline, dev-time), train the `NLEmbedding`+logistic-
regression classifier, evaluate under grouped/family holdout. Decision rule: if false-positive
rate on the narration holdout exceeds ~5%, abandon `NLEmbedding` for a distilled MiniLM Core ML
transformer. Codex adds a second probe job: measure model load time, to size the pre-warm
budget.

## 9. Folder index

| Path | Contents |
|---|---|
| `01-prompt-benchmark/` | 315-case corpus, 10 run files, Codex judgments, scoreboard HTML, all candidate prompts |
| `02-classifier-probes/` | AFM-as-classifier and frontier-model-as-classifier prompts + outputs |
| `03-council/` | 3 classifier-design council rounds + the superseded-epic council review |
| `04-codex-architecture-review.md` | Codex grounded review of the architecture |
| `05-superseded-deterministic-failsafe-epic.md` | The earlier deterministic-cleaner epic bible (superseded by the classifier architecture) |
| `SafeDeterministicPolisher-gpt-poc.swift` | GPT's proof-of-concept deterministic cleaner |
