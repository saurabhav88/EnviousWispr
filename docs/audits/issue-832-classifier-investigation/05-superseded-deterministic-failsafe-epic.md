# Issue #832 — Deterministic Failsafe Polisher — Epic Bible — 2026-05-21

GitHub issue: `#832`. Parent / epic: standalone (third approach to #832). Tier: LARGE (multi-PR). Status: DRAFT — pre-council.

> This is an **epic bible**, not a single-PR plan. It establishes the architecture, the PR ladder, the
> evaluation methodology, and the anti-overfit discipline. Each PR on the ladder gets its own
> `docs/feature-requests/issue-832-<date>-<slug>.md` plan filling the full `TEMPLATE.md` before it is built.
> Council + Codex grounded review run on THIS bible first (architecture coverage), then per-PR.

---

## Preface — decisions already locked

Two founder decisions, locked before this bible was written. Recorded here so council does not relitigate them.

1. **Failsafe only, no input detector.** The deterministic cleaner is what the pipeline falls back to when
   AFM's output check trips or AFM is unavailable. There is NO new input-side command detector. GPT's POC
   `HardExecutionRiskDetector` is **dropped** — it is structurally the same input detector #832 already built
   and abandoned for overfit recall (27/27 tuning, 5/21 holdout — see #832 comment 2026-05-21).
2. **Scope includes strengthening the output-side execution check** so the failsafe actually fires often
   enough to matter (see §3 part 2).

Two further drops from GPT's proof-of-concept (`SafeDeterministicPolisher.swift`, relayed by the founder):

3. **`CommandFrameFormatter` is dropped.** It injects a colon mid-sentence ("translate this to French I'll be
   late" becomes "translate this to French: I'll be late"), inventing structure the user never dictated. By
   the project's own polish rubric that is a meaning/structure change, i.e. a fail. The failsafe cleans
   lightly; it does not reformat commands into labeled blocks.
4. **The emoji and filler-removal fixers are dropped as duplicates.** The pipeline already runs a
   production-grade `EmojiFormatter` (1,561-entry CLDR dictionary, issue #341) and `FillerRemovalStep`
   BEFORE AFM polish. The failsafe's input is already filler-stripped and emoji-converted. It must not
   re-implement either.

## Preface — Lane + Live UAT declaration

**Lane:** Code (per-PR; PR plans confirm against `git diff --name-only origin/main`). The eval-harness PR
(see ladder) is Mixed (Code + Eval-harness) and declares both lanes.

**Live UAT:** Y — per PR. Founder rebuilds, dictates a command-shaped sentence ("draft a Slack to Matt
saying I'll be late"), confirms the pasted result is the *cleaned dictated words*, not a composed message,
and is visibly cleaner than the raw transcript.

## Preface — User Rubric

`User Rubric: N/A — #832 is a user-visible bug (label: bug), not an epic feature; it is not under epics
#314/#316/#317/#320/#321.` The user-facing benefit is stated plainly in §1 and §2; persona-roleplay council
is not required. Standard coverage council still runs.

---

## 0. TL;DR

AFM on-device "AI Polish" executes instructions embedded in dictation (a "draft a Slack to Matt" comes back
as a finished message) roughly one time in three. Two fixes were tried and set aside: an input-side command
detector (overfit recall) and AFM prompt rewriting (this session's 315-case benchmark disproved seven prompt
variants — every one still executes most colloquial commands). This epic is the third approach: a
**deterministic, non-LLM text cleaner** that the pipeline falls back to when AFM misbehaves. A cleaner with
no generative model **cannot execute a command** — empirically confirmed this session (the deterministic POC
scored 27/30 on the two instruction test categories where every AFM variant scored 3-6/15). The epic ships
as a PR ladder: a minimum-viable failsafe first, then production-grade fixers, then a strengthened output
check so the failsafe fires often enough to move #832's headline number. Evidence it worked: a
failsafe-specific eval (defined in §4) shows the cleaned fallback beats the raw-transcript fallback on the
cases where AFM trips, and the strengthened output check raises holdout catch rate without overfitting.

## 1. Problem

`docs/audits/2026-05-21-afm-instruction-execution-pressure-test.md`: 20/60 instruction dictations executed
(composed / answered / transformed) — 1 in 3. The user dictates words to be typed; AFM types something else.
Founder-flagged Tier-1: "actively changing what I'm writing into something completely different is
absolutely unacceptable."

Today, when AFM's `EnviousOutputFilter` *does* catch a problem, the fallback is the **raw, unpolished
transcript** — no capitalization, no punctuation, fillers and run-ons intact. So even the cases the safety
net catches produce an ugly paste. Two gaps:

- **Gap A — the fallback is ugly.** Raw transcript is better than an executed command, but it is not what
  the user expects from a polish step.
- **Gap B — the safety net rarely fires.** `EnviousOutputFilter`'s instruction-execution guard caught 5/21
  on a fresh holdout (#832 comment 2026-05-21). Most executed commands sail through.

This epic closes both: a clean deterministic fallback (Gap A) and a stronger output check (Gap B).

## 2. Goals & non-goals

### 2.1 Goals

- A deterministic, non-LLM `SafeDeterministicPolisher` that lightly cleans text: capitalization,
  punctuation, light self-correction collapse, repeated-word collapse, and number/date normalization.
- Each fixer is production-grade, held to the `EmojiFormatter` bar (own module or own clearly-bounded type,
  own design doc / plan, own heavy test suite, own data file where one applies). Founder direction
  2026-05-21: "I want our custom emoji solution quality for every fixer part."
- The cleaner replaces the raw-transcript fallback wherever AFM polish falls back or is unavailable.
- A strengthened `EnviousOutputFilter` output-side execution check with a measured holdout catch rate.
- A failsafe-specific eval harness (§4) that measures the right thing: cleaned-fallback vs raw-fallback on
  the cases AFM trips.
- Zero heart-path risk: the cleaner is a limb; if it throws, the pipeline still pastes raw text.

### 2.2 Non-goals

- A primary / default polish path. The deterministic POC scored 20.6% as a general polisher on the 315-case
  prose corpus — it is a failsafe, never a replacement for AFM on clean dictation.
- An input-side command detector (locked drop, Preface 1).
- Grammar rewriting, sentence rephrasing, homophone correction — beyond deterministic reach; AFM's job.
- Multilingual cleaning. v1 is English; non-English dictation falls back to raw transcript unchanged.
- Touching cloud polish (Gemini / OpenAI / Ollama). #832 is AFM-specific; cloud paths do not route through
  `EnviousOutputFilter`.

## 3. Architecture

### Part 1 — the deterministic cleaner and where it plugs in

**Placement of the cleaner.** `SafeDeterministicPolisher` and its fixers live in
`Sources/EnviousWisprPostProcessing/` — the module that already owns deterministic post-processing
(`EmojiFormatter`, `WordCorrector`, `FillerRemovalStep`'s sibling logic). It depends only on
`EnviousWisprCore`, respecting dependency direction.

**Placement of the trigger wiring.** The failsafe is invoked from `LLMPolishStep`
(`Sources/EnviousWisprPipeline/LLMPolishStep.swift`). `EnviousWisprPipeline` already depends on BOTH
`EnviousWisprLLM` and `EnviousWisprPostProcessing` (verified — `Package.swift`), so this needs **no new
module dependency edge**. The alternative — calling the cleaner from inside `EnviousOutputFilter` — is
rejected: `EnviousOutputFilter` lives in `EnviousWisprLLM`, which depends only on `EnviousWisprCore`;
wiring there would force a new `EnviousWisprLLM → EnviousWisprPostProcessing` edge.

**The hook signal.** `LLMPolishStep` already computes
`ctx.pipelineFellBackToRaw = (result.polishMetadata?.filterFellBackToRaw ?? false) || (validatedText == context.text)`
(`LLMPolishStep.swift:251-252, 304-305`). When AFM polish falls back, this is `true` and `ctx.polishedText`
is the raw transcript. The failsafe: when the active provider is AFM and `pipelineFellBackToRaw` is `true`
(or the AFM polish call threw entirely — the `catch` path), set
`ctx.polishedText = SafeDeterministicPolisher.polish(originalText)` instead of the raw transcript.
`originalText` is `context.text` as it entered `LLMPolishStep` — already filler-stripped and
emoji-converted by upstream steps.

**Open placement question for council / grounded review (§7).** Whether the swap is best done inline in
`LLMPolishStep` or as a dedicated post-`LLMPolishStep` `TextProcessingStep` (the `EmojiFormatter` precedent).
A dedicated step is more testable and matches house pattern; inline is fewer moving parts. PR-1's plan
picks one with grounded-review backing.

### Part 2 — strengthening the output-side execution check

`EnviousOutputFilter.executedInstruction` already inspects AFM's *output* for composed-artifact signals
(salutation, sign-off, bracketed placeholder, dropped request verb, input/output divergence —
`EnviousOutputFilter.swift:233-286`). This is **not** the rejected input detector: it reads what AFM
actually produced, a far more tractable signal than guessing intent from raw dictation. Its recall is low
(5/21 holdout) only because it has not been invested in since the #832 pivot.

Part 2 strengthens this check. **Anti-overfit discipline is mandatory and stated up front**, because this
is the same shape as the abandoned detector:

- **Two corpora, hard-separated.** A *tuning* corpus (the existing `instruction_execution_v1`, 80 cases)
  and a *holdout* corpus (`instruction_holdout_v1`, never tuned on). Recall is reported on the **holdout**.
- **The target is a holdout number, never a tuning number.** "27/27 on tuning" is explicitly not a success
  criterion. PR-4's plan sets a concrete holdout catch-rate target with founder sign-off.
- **False-fire ceiling on the 315-case general corpus is the hard gate.** The strengthened check must not
  regress clean-prose false-fire beyond the validated 0.3% gated baseline (#832 comment 2026-05-21).
- If holdout recall cannot be raised materially without breaching the false-fire ceiling, Part 2 reports
  that honestly and the failsafe stands on Part 1 alone. The deterministic gate has a known ceiling; the
  epic does not pretend otherwise.

## 4. Evaluation methodology — the right yardstick

The 315-case `category_stress_v1` corpus measures *general polish quality on raw dictation*. The
deterministic POC scored 65/315 (20.6%) on it — but that is the wrong test for a failsafe. The failsafe
never sees raw dictation in normal use; it runs only when AFM has already misbehaved. Its bar is
**"better than the raw transcript the user gets today,"** not "as good as AFM on clean prose."

**The failsafe eval (built in the eval-harness PR).** Corpus = the cases where AFM trips the output check
(drawn from `instruction_execution_v1` + `instruction_holdout_v1` + filter-trip cases from the 315-corpus
runs already captured this session). For each case, three columns: (a) raw transcript, (b) deterministic
cleaner output, (c) what AFM produced. The judge question: **"Is (b) a better paste than (a)?"** Scored
by Codex, one arm at a time, human-satisfaction rubric — the same method validated this session. Success
= the cleaner beats raw on a strong majority and never makes a case worse.

The instruction-resistance number stays measured on the existing 315-corpus instruction categories
(`anti_instruction`, `anti_instruction_command`) — the POC's 27/30 there is the confirmed baseline.

## 5. PR ladder

Each PR ships complete (`no-half-done-handoffs`): no forwarding shims, old behavior removed and new wired
in the same PR. Each gets its own full `TEMPLATE.md` plan, council, and Codex grounded review.

- **PR-1 — Minimum-viable failsafe.** `SafeDeterministicPolisher` skeleton + capitalization fixer +
  punctuation fixer + the `LLMPolishStep` trigger wiring. Replaces the raw-transcript fallback with a
  cleaned one for the AFM path. Ships with the failsafe eval harness so PR-1 itself is measured. After
  PR-1, a fallback is already cleaner than today.
- **PR-2 — Self-correction + repeated-word collapse fixers.** Each an `EmojiFormatter`-grade module with
  its own design doc and adversarial test suite. Conservative by design (the POC's reset-marker approach
  is the floor, not the ceiling).
- **PR-3 — Number / date / ITN normalization.** Inverse text normalization for spoken numbers, dates,
  times, emails, URLs, phones. Evaluate the FluidInference `text-processing-rs` engine (same vendor as our
  forked ASR library) vs a bounded native fixer; PR-3's plan makes that build-vs-adopt call with evidence.
- **PR-4 — Strengthen the output-side execution check** (Part 2). Holdout-measured, false-fire-gated.

Ordering rationale: PR-1 delivers user-visible value immediately (clean fallback). PR-2/PR-3 raise fixer
quality. PR-4 is last because it widens *how often* the (now good) failsafe fires — pointless before the
failsafe is worth firing.

## 6. Risks

- **The cleaner is visibly rougher than AFM.** Accepted — it runs only when AFM already broke. The eval
  (§4) measures it against raw transcript, not against AFM.
- **Sentence segmentation is hard deterministically.** A regex caps/punctuation pass cannot reliably split
  run-ons. PR-1 evaluates Apple's `NaturalLanguage` framework (`NLTagger` sentence units — deterministic,
  on-device, already imported in `AppleIntelligenceConnector`) for sentence boundaries before falling back
  to naive splitting.
- **Part 2 overfit.** Mitigated by the §3 anti-overfit discipline (holdout-only targets, false-fire gate).
- **Module placement.** Resolved in §3; grounded review confirms no dependency-direction violation.

## 7. Open questions for council / grounded review

1. Inline-in-`LLMPolishStep` vs dedicated post-polish `TextProcessingStep` for the trigger wiring.
2. Does the failsafe also cover the non-AFM fallback routes (`validatedText == context.text`), or AFM only?
3. Is the failsafe eval corpus (§4) drawn from the right sources, and is "better than raw" the right judge
   question, or should it also gate "never worse than raw" as a hard fail?
4. PR-3: adopt FluidInference `text-processing-rs` (Rust, FFI) vs a bounded native Swift ITN fixer — which
   is the lower long-term-maintenance call?
5. Part 2: is a holdout catch-rate target meaningful at all, or should Part 2 be reframed as "reduce
   false-negatives on the specific composed-artifact shapes we can detect deterministically"?

## 8. Related

- #832 issue thread — original detector plan (`issue-832-2026-05-21-afm-instruction-execution-guard.md`),
  Gate-2 approval, and the 2026-05-21 validation-and-pivot comment.
- `docs/audits/2026-05-21-afm-instruction-execution-pressure-test.md` — the pressure test.
- `docs/audits/2026-05-21-afm-instruction-guard-validation-and-pivot.md` — why the detector was paused.
- This session's prompt benchmark — `~/Downloads/afm-benchmark/` (7 AFM arms + production + deterministic
  POC, 315-case corpus, Codex-judged). Proves prompt tuning cannot solve instruction-execution and the
  deterministic POC cannot execute commands.
- `docs/feature-requests/issue-341-2026-05-16-emoji-formatter.md` — the production-grade-fixer quality bar.
- GPT's proof-of-concept: `~/Downloads/SafeDeterministicPolisher.swift`.