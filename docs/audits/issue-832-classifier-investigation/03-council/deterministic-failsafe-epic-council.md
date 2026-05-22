# Council review — deterministic failsafe cleaner epic bible (superseded approach)

## OPENAI (gpt-5.5-2026-04-23)

## Two missing premises before reviewing the ladder

1. **“Raw transcript” is internally ambiguous.**  
   The plan says today’s raw fallback has “fillers and run-ons intact,” but later says `originalText` entering `LLMPolishStep` is already filler-stripped and emoji-converted. Those cannot both be true without defining two different “raws.”  
   **Needed premise:** what exact text object is the fallback baseline: ASR raw, post-filler/emoji text, post-custom-words text, or something else? The eval, trigger wiring, and user-facing quality claim all depend on this.

2. **The plan assumes the fallback trigger is semantically trustworthy.**  
   `pipelineFellBackToRaw = filterFellBackToRaw || validatedText == context.text` may conflate true safety fallback with “AFM returned the same text because no polish was needed.”  
   **Needed premise:** `LLMPolishStep` can distinguish fallback reason: output-filter rejection, provider unavailable, provider threw, validation failure, or legitimate no-op. Without that, PR-1 may invoke the cleaner on successful AFM no-ops and silently change text that did not need rescue.

---

# 1. PR ladder: mostly right, but not every rung is shippable-complete as written

The broad order is defensible:

1. Build minimum safe fallback.
2. Improve deterministic fixer quality.
3. Add riskier normalization.
4. Increase the number of cases routed to the fallback.

That said, several rungs need sharper completion gates before they are truly independently shippable.

## PR-1 — Minimum-viable failsafe

This is the most important rung, and it is close, but not shippable-complete unless it includes:

- A precise fallback-reason signal, not `validatedText == context.text` as a trigger.
- A hard language gate, since v1 is English-only and non-English must pass through unchanged.
- A hard “no worse than raw” gate, not only “strong majority better.”
- Telemetry for trigger reason and fallback outcome.
- A kill switch or runtime config so the fallback can be disabled without reverting if it unexpectedly harms paste quality.
- Exception containment around the cleaner, including the path where AFM itself already threw.

The plan says “if the cleaner throws, paste raw,” which is right, but PR-1 needs to prove that every invocation site, especially the AFM `catch` path, preserves that guarantee.

**Potential ordering tweak:** the eval harness may deserve to land before live wiring, or as the first part of PR-1 with a “do not enable if gate fails” rule. Shipping harness + live fallback together is acceptable only if the PR has an explicit stop condition when the eval fails.

## PR-2 — Self-correction + repeated-word collapse

This can be shippable, but the rung needs a stronger semantic-preservation gate.

Repeated-word and self-correction cleanup can easily damage intentional text:

- “very very good”
- “had had”
- “no no no”
- quoted speech
- poetry/song lyrics
- stutter-like dictated content
- product names or custom words repeated intentionally

The plan’s “conservative by design” language is good, but the PR gate should explicitly require adversarial tests for intentional repetition and quoted/command-shaped content.

## PR-3 — Number/date/ITN normalization

This rung is not quite shippable-complete as written because it combines two different activities:

1. Evaluate `text-processing-rs` vs native Swift.
2. Ship number/date/time/email/URL/phone normalization.

Those are different risk profiles. The adopt/build decision is not itself a user-shippable complete rung unless the selected implementation is also fully integrated, tested, gated, and wrapped safely.

This PR also has the largest heart-path risk if Rust/FFI is adopted. A Swift thrown error can be caught; a native crash from FFI may not be recoverable. If `text-processing-rs` remains an option, the PR needs explicit crash-containment thinking, initialization failure handling, thread-safety validation, and a fallback-to-raw path that survives library absence or load failure.

Also, ITN is semantically risky:

- “twenty twenty four” could be a phrase, a year, a product name, or dictated literal words.
- “one two three” could be a sequence, not `123`.
- “at sign” in prose versus email.
- “dot com” in prose versus URL.
- “May fifth” versus “may fifth” as ordinary words.

PR-3 should likely ship each ITN family behind conservative gates, rather than treating number/date/email/URL/phone normalization as one atomic fixer.

## PR-4 — Strengthen output-side execution check

Putting PR-4 after a usable fallback is right. Widening the trigger before the fallback is good would increase the number of users who see raw or rough fallback text.

However, PR-4 should not depend on PR-3 being perfect. If PR-3 proves risky or delayed, PR-4 should still be able to ship after PR-1/PR-2. The important product outcome is reducing executed-command pastes; better ITN is secondary.

---

# 2. Evaluation methodology: measuring the right thing, but incompletely

The plan correctly rejects the 315-case general-polish score as the main yardstick. A deterministic failsafe should be compared against the fallback the user would otherwise receive, not against AFM on clean prose.

But §4 has three gaps.

## Gap A: the corpus is biased toward already-caught cases

“Cases where AFM trips the output check” measures fallback quality only on cases the current detector already catches. That is useful for Gap A, but it does not measure the user-visible #832 harm rate, because most bad AFM executions currently escape.

You need two separate metrics:

1. **Conditional fallback quality:**  
   Among cases routed to deterministic fallback, is deterministic output better than the previous raw fallback?

2. **End-to-end safety outcome:**  
   Among instruction-shaped dictations, how often does the final pasted text still contain an executed/composed/transformed response instead of the dictated words?

The second number is the real #832 headline metric.

## Gap B: “better than raw” is too soft unless “worse” is separately fatal

“Cleaner beats raw on a strong majority and never makes a case worse” is close, but “never makes worse” should be the hard gate, not a secondary phrase.

The judge rubric should separately score:

- Preserves dictated words.
- Does not execute/answer/compose/translate.
- Does not invent structure.
- Does not delete meaningful content.
- Does not alter quoted text/code/URLs/emails/custom words.
- Improves or preserves readability.

A prettier but semantically changed output must fail, even if a human-satisfaction judge prefers it superficially.

## Gap C: the eval needs to match the exact pipeline input

Because the plan is ambiguous about whether fallback input is ASR raw or post-filler/emoji/custom-word text, the eval could accidentally compare the cleaner against the wrong baseline.

The eval should store and compare:

- ASR raw transcript.
- Text entering `LLMPolishStep`.
- AFM output.
- Output-filter decision and reason.
- Deterministic fallback output.
- Final pasted text.

Without those columns, it will be hard to know whether the cleaner is improving the actual fallback path or an artificial offline input.

---

# 3. Anti-overfit discipline: directionally good, but still vulnerable

The plan’s anti-overfit discipline is much better than the abandoned input detector, but it can still drift back into overfit through the output check.

## Main risk: holdout leakage through repeated iteration

A hard-separated tuning corpus and holdout corpus are necessary but not sufficient if the team repeatedly checks holdout recall after each heuristic change. The holdout then becomes the tuning set in practice.

Add a rule like:

- Heuristics are developed only on tuning/failure-analysis data.
- Holdout is run once per PR candidate, not during iteration.
- If holdout failures inspire new rules, those examples move into the next tuning corpus, and a fresh holdout slice is created.
- PR-4 reports both old-holdout and fresh-final-holdout numbers if any iteration happened after seeing holdout results.

## False-fire ceiling is under-specified

The 315-case general corpus false-fire ceiling of 0.3% is useful but probably too narrow.

Output-side execution checks may falsely fire on legitimate user dictation that naturally contains composed artifacts:

- A user intentionally dictates an email with “Hi Matt,” and “Best,”.
- A user dictates a template with placeholders.
- A user dictates Markdown, code, a legal clause, a recipe, a script, or a customer-support response.
- A user says “write this exactly: draft a Slack to Matt saying I’ll be late.”

A clean-prose corpus may not stress those cases. PR-4 needs a **legitimate-artifact false-positive corpus**, not only the 315-case general corpus.

Also, with 315 cases, 0.3% effectively means one false fire. That is a fragile metric. The gate should specify the denominator, confidence expectations, and whether one severe false fire blocks the PR.

## Catch-rate denominator must be explicit

“Holdout catch rate” should mean:

> Of AFM outputs independently labeled as executed/composed/transformed, what percentage does the output filter reject?

It should not mean:

> Of all command-shaped inputs, what percentage did the filter reject?

Those are different. The filter is output-side, so the denominator should be bad AFM outputs, not all inputs.

---

# 4. Placement review

Current placement is reasonable:

- `SafeDeterministicPolisher` in `EnviousWisprPostProcessing` fits the existing ownership of deterministic text cleanup.
- Trigger wiring in `LLMPolishStep` avoids adding `EnviousWisprLLM → EnviousWisprPostProcessing`.

But the trigger owner deserves pressure.

## Alternative owner

A dedicated `TextProcessingStep` / `FallbackPolishStep` immediately after `LLMPolishStep`.

## Cost of that alternative

- Requires `LLMPolishStep` to publish a reliable fallback reason into pipeline context.
- Adds a strict ordering dependency: it must run after AFM validation and before paste.
- The AFM `catch` path must still populate enough context for the next step to recover.
- More moving parts and more context-state surface area.

## Benefit of that alternative

- Keeps `LLMPolishStep` focused on provider invocation/validation.
- Makes fallback behavior easier to unit-test as a pipeline stage.
- Matches the house precedent of deterministic post-processing steps.
- Avoids hiding more text-transformation responsibility inside the LLM orchestration step.

If inline remains the choice, the plan should explicitly say `LLMPolishStep` owns only the routing decision, while the text transformation remains entirely delegated to `EnviousWisprPostProcessing`.

---

# 5. Failure-mode gaps

The plan covers “if cleaner throws, paste raw,” but a few concrete failure modes are missing.

## Cleaner failure modes

Need explicit handling for:

- Empty string.
- Whitespace-only string.
- Very long transcript.
- Extremely punctuation-heavy input.
- Code snippets.
- URLs/emails/handles.
- Quoted text.
- Non-English or mixed-language text.
- Custom words and product names.
- Acronyms and initialisms.
- Emoji-converted text already present.
- Thread-safety if fixers use shared caches/data files.
- Regex catastrophic backtracking if regex-heavy fixers are used.

## NaturalLanguage framework fallback

PR-1 proposes evaluating `NLTagger` for sentence boundaries. That needs a timeout/performance guard and deterministic fallback. `NaturalLanguage` is on-device, but it is still a framework dependency on the paste path.

## Rust/FFI risk in PR-3

If `text-processing-rs` is adopted, “if it throws, paste raw” may not protect against:

- native crash,
- bad memory access,
- initialization failure,
- architecture-specific load issue,
- concurrency bug,
- packaging/signing/notarization issue.

That does not mean “do not adopt it,” but it does mean PR-3 needs a stronger failure-containment plan than the Swift fixers.

---

# 6. Telemetry gaps

Telemetry is important here because the fallback is safety behavior, and silent regressions would be hard to detect.

Minimum events/counters should include privacy-preserving fields only:

- AFM polish attempted.
- AFM output-filter tripped.
- AFM provider unavailable.
- AFM call threw.
- AFM validation returned same-as-input.
- Deterministic fallback invoked.
- Deterministic fallback succeeded.
- Deterministic fallback failed and raw was pasted.
- Cleaner skipped due to non-English/mixed-language/unsupported input.
- Final path: AFM output, deterministic fallback, or raw fallback.
- Length delta bucket, not raw text.
- Fixer families applied, e.g. capitalization, punctuation, repetition, ITN, without content.

For diagnostics, local debug logs may include richer before/after text only if existing privacy policy and user expectations allow it. Otherwise, avoid content logging.

Also useful: a metric for “fallback invoked because equality heuristic” if that path remains. Ideally that count should disappear once explicit fallback reasons exist.

---

# 7. Workflow-stage gaps

## AFM-only versus all providers must be decided before PR-1

The open question “does the failsafe also cover non-AFM fallback routes?” should not remain open when PR-1 is planned.

Given the stated scope, PR-1 should probably be **AFM-only** unless there is evidence that cloud providers share the same failure mode and route through the same output filter. Otherwise the fallback can accidentally alter cloud-provider no-op/failure behavior outside the epic’s scope.

## Language gating belongs before cleaner invocation

Because multilingual cleaning is a non-goal, the fallback stage must check language before applying English fixers. “Non-English falls back to raw unchanged” needs an explicit source of truth:

- ASR language hint?
- User language setting?
- detected language from earlier pipeline?
- per-segment language metadata?

If none exists, PR-1 needs to add or consume one before enabling the cleaner.

## Custom words / domain words

The plan should state whether custom-word correction happens before `LLMPolishStep`. If yes, deterministic fallback must preserve those corrections. If no, the fallback may be cleaner-looking but still worse for user-specific vocabulary.

## Output-filter metadata should be richer

The output filter should return reason codes, not just `filterFellBackToRaw`.

Useful reason codes:

- executed instruction,
- safety/validation divergence,
- empty/invalid output,
- provider unavailable,
- provider error,
- same-as-input/no-op,
- unsupported language.

This would make routing, telemetry, and eval much less ambiguous.

---

# Bottom line

The epic is directionally sound: deterministic fallback for AFM execution failures is the right architectural shape, and PR-4 being last is mostly right.

The main coverage gaps are:

1. Define the exact fallback input/baseline; “raw” is currently contradictory.
2. Replace the equality-based trigger with explicit fallback reasons.
3. Make “never worse than raw” a hard eval gate.
4. Add end-to-end #832 safety metrics, not only conditional fallback-quality metrics.
5. Strengthen anti-overfit with holdout-use discipline and a legitimate-artifact false-positive corpus.
6. Decide AFM-only scope and language gating before PR-1.
7. Treat PR-3/FFI/ITN as the highest semantic and crash-containment risk.
8. Add privacy-preserving telemetry for trigger reason, fallback invocation, cleaner failure, and final pasted path.

## GEMINI (gemini-3.1-pro-preview)

Here is the rigorous, coverage-focused critique of the Epic Bible, evaluating it strictly against its stated goals and the constraints provided.

### 1. Forgotten Premises
*   **Premise 1: Model drift invalidates output-shape assumptions.** The epic pivots from an input-detector to an output-detector to avoid overfitting to raw dictation. However, it forgets that LLM output shapes are highly volatile. AFM's use of bracketed placeholders `[Insert Name]`, specific dropped verbs, or salutation styles ("Here is the drafted message:") will change silently when the underlying model updates. An output check locked to today’s model artifacts is safer than guessing input intent, but it trades *data* overfit for *model-behavior* overfit.
*   **Premise 2: Fallback latency impact.** The user already waited for the LLM to process the audio, generate text, and trigger the output filter. By the time the pipeline falls back, the user has experienced max latency. PR-3 proposes evaluating a Rust FFI (`text-processing-rs`) or Apple's `NaturalLanguage` tagger (PR-1). If the deterministic cleaner takes noticeable time to initialize or process on top of the already-spent LLM round-trip, the user experiences a double-penalty on latency before the paste executes.

### 2. PR Ladder Ordering & Shippability
*   **Order Critique:** The ladder defers PR-4 (strengthened output check) to the very end. The stated rationale is "pointless before the failsafe is worth firing." However, currently the safety net catches only 5/21 cases. If PR-1, PR-2, and PR-3 ship first, they are shipping heavy, complex machinery (including a potential Rust FFI adoption) that *will almost never run in production*.
*   **Recommendation:** Move PR-4 (or a V1 of PR-4) to immediately follow PR-1. This ensures the MVP failsafe actually fires in production, allowing you to gather live telemetry on the fallback path before investing heavily in the complex linguistic tasks of PR-2 and PR-3.
*   **Shippable-Complete?** Yes, each rung technically leaves the app in a compiling, working state. 

### 3. Evaluation Methodology (Section 4)
*   **The Gap:** The yardstick asks Codex, *"Is (b - deterministic) a better paste than (a - raw transcript)?"* This is logically sound for a component test, but it misses a critical boundary condition: **destructive edits**.
*   Because the failsafe runs deterministically via regex/ITN without contextual understanding, the risk isn't just "is it less pretty than raw," it is "did it change the semantic meaning or destroy a proper noun?" 
*   **Correction:** The rubric must be amended to include a hard failure gate: *"Did (b) destroy, mutate, or drop words that change the meaning compared to (a)?"* If (b) formats numbers better but accidentally truncates a sentence because of a naive `NLTagger` split, it is worse than raw text.

### 4. Anti-Overfit Discipline (Section 3 Part 2)
*   **Is it sufficient?** No, it has a blind spot. 
*   The discipline relies on a static tuning corpus (`instruction_execution_v1`) and a static holdout corpus (`instruction_holdout_v1`). If the founder iteratively tweaks the `EnviousOutputFilter` rules (e.g., adding a check for a new sign-off phrase like "Best," or "Let me know"), and checks the holdout score repeatedly during development to see if the catch-rate improved, the holdout *becomes* a tuning set. 
*   **Correction:** To maintain true discipline, the holdout corpus must only be scored *once* at the end of PR-4's development. If used iteratively to gate intermediate commits, the output check will drift right back into the overfit trap. 

### 5. Placement & Trigger Wiring
*   **Proposed Placement:** Cleaner in `EnviousWisprPostProcessing`, Trigger inline in `LLMPolishStep`.
*   **Alternative Placement:** Move the Trigger into `EnviousWisprLLM`'s `EnviousOutputFilter`. When the filter catches an execution, it directly triggers the cleaner before returning the result to the pipeline.
*   **The Cost:** This would force `EnviousWisprLLM` to take a new module dependency on `EnviousWisprPostProcessing` (to access the cleaner). This reverses the ideal dependency flow—an LLM networking/filtering module shouldn't need to know about deterministic text-formatting modules. The Epic's proposed placement (inline in `LLMPolishStep` or as a new `TextProcessingStep` in the pipeline module) correctly avoids this architectural cost. A dedicated `DeterministicFallbackStep` directly after `LLMPolishStep` is the cleanest approach.

### 6. Failure-Mode & Telemetry Gaps
*   **Telemetry Gap (Silent Degradation):** If PR-4 works, users will suddenly see deterministic output (no grammar fixes, no homophone correction) 30% of the time instead of full LLM polish. To the user, this looks like the app's AI randomly stopped working well. There is no telemetry requirement in the epic to track the *ratio* of LLM-polish vs Failsafe-polish in production. Without logging `fallback_triggered = true` to product analytics, you will have no idea if your LLM prompts are regressing in the wild.
*   **Failure-Mode Gap (The `catch` block):** Section 2.1 states "if it throws, the pipeline still pastes raw text." However, PR-3 introduces potential Rust FFI (memory safety / panic boundaries) or `NaturalLanguage` taggers. If a Swift-to-Rust bridge panics, it doesn't just throw a Swift `Error`—it crashes the app. The design must explicitly require that any 3rd-party ITN engine used in PR-3 is strictly bounded and cannot bypass the Swift error-handling boundary to violate the "Heart path must never fail" directive.
