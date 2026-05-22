# Codex grounded review — issue #832 classifier architecture vs. EnviousWispr code

Tool: codex exec (gpt-5.5, read-only sandbox), 2026-05-21. Verdict: PROCEED-WITH-REVISIONS.

---

**Q1 — Direction**
Verdict: **PARTIAL.** The 3-part architecture fits the codebase, but the actual wiring should be slightly different from the summary.

Current real path:

- Both pipelines own the text steps in this order: word correction, filler removal, emoji, LLM polish: `TranscriptionPipeline.swift:198-200`, `WhisperKitPipeline.swift:212-214`.
- `TextProcessingRunner` creates `TextProcessingContext(text: rawText...)`, then runs each enabled step with a timeout: `TextProcessingRunner.swift:60-90`.
- AFM is selected inside `LLMPolishStep.process` when `llmProvider == .appleIntelligence`: `LLMPolishStep.swift:207-253`.
- The AFM connector then does language gate, router decision, `LanguageModelSession.respond`, and output filter: `AppleIntelligenceConnector.swift:320-352`, `:414-421`, `:473-480`.

Where to wire the proposed parts:

- **Input classifier:** before AFM is called. If it lives in `EnviousWisprLLM`, put it in `AppleIntelligenceConnector.polish` after language gate and before `ApplePolishRouter.decide`: `AppleIntelligenceConnector.swift:320-335`. If it lives in `EnviousWisprPostProcessing`, do **not** import that into LLM; wire it in `LLMPolishStep.process` before `polisher.polish(...)`: `LLMPolishStep.swift:207-234`.
- **Novel-word guard:** extend `EnviousOutputFilter.filter(input:output:instructionRisk:)`; that is already the AFM post-output safety choke point: `EnviousOutputFilter.swift:27-86`.
- **Deterministic fallback:** should be chosen in `LLMPolishStep`, because that layer has the pre-AFM text and owns final `polishedText` / fallback flags: `LLMPolishStep.swift:243-253`.

**Q2 — Abort-AFM Claim**
Verdict: **FALSE as an architecture dependency; UNVERIFIABLE-FROM-CODE for cooperative cancellation.**

The code uses one-shot `respond(...)` calls: `AppleIntelligenceConnector.swift:415-418`, `:474-477`. The local FoundationModels interface exposes async `respond(...)`, `streamResponse(...)`, and `isResponding`, but no explicit `cancel`, `abort`, or `stop` API: local SDK `FoundationModels.swiftinterface:335-358`, `:501-509`.

The current pipeline timeout only cancels the Swift child task: `TaskTimeout.swift:13-30`, called through `TextProcessingRunner.swift:43-53` and `:89-90`. That proves the host task can be cancelled; it does **not** prove AFM generation stops inside Apple’s framework.

So the concurrent “start AFM, run classifier, abort AFM if command” plan should not be relied on. Run the classifier serially before AFM. If the classifier is truly ~2ms warm, the added latency is ~2ms, which is negligible beside the AFM call and the existing 10s AFM polish budget: `LLMPolishStep.swift:57-65`.

**Q3 — Classifier Placement + Module Boundaries**
Verdict: **TRUE: dependency direction matters here.**

`EnviousWisprLLM` depends only on `EnviousWisprCore`: `Package.swift:72-75`. `EnviousWisprPipeline` already depends on both LLM and PostProcessing: `Package.swift:78-86`.

So if the classifier lives in `EnviousWisprPostProcessing`, clean wiring is:

- `LLMPolishStep` consults the classifier before calling `AppleIntelligenceConnector`.
- If command / uncertain / unsupported, it skips AFM and returns deterministic fallback.
- `AppleIntelligenceConnector` stays AFM-only and does not import upward or sideways.

NaturalLanguage/CoreML do not need SwiftPM package dependencies; they are Apple system frameworks. The repo already imports `NaturalLanguage` in the LLM target and uses `NLLanguageRecognizer`: `AppleIntelligenceConnector.swift:3`, `:88-90`. `NLEmbedding` itself is available in the local SDK as sentence embeddings on macOS 11+: `NLEmbedding.h:25-26`, but I found no repo use of `NLEmbedding`.

No current entitlement points at CoreML/NaturalLanguage. The app entitlements are audio input and Apple Events only: `EnviousWispr.entitlements:5-8`.

**Q4 — Novel-Word Guard vs Existing Filter**
Verdict: **EXTEND `EnviousOutputFilter`, but do not reuse the existing divergence check as-is.**

The existing `instruction_execution_guard` is gated by `instructionRisk`: `EnviousOutputFilter.swift:42-49`. Its divergence sub-check is bidirectional: low input retention **or** high output novelty: `EnviousOutputFilter.swift:272-284`.

That is not the same as the proposed backstop. The proposed guard is **novel-words-only** for high-novelty generation. The existing divergence check includes missing input words, which your own findings say false-fires on normal polish. If made always-on, it would reintroduce the killed false-positive path.

So: add a separate high-threshold novelty-only sub-check inside `EnviousOutputFilter`, probably after wrapper/preamble stripping and before broad length guard. Keep the existing gated divergence check separate.

**Q5 — Deterministic Fallback**
Verdict: **PARTIAL.**

Today, when the filter trips it returns the input passed to the connector, not a cleaner output: `EnviousOutputFilter.swift:46-65`. `LLMPolishStep` then writes that into `ctx.polishedText` and marks fallback using metadata or equality with `context.text`: `LLMPolishStep.swift:243-253`.

`LLMPolishStep` does have the right pre-AFM text for a fallback: `context.text` is the current text going into polish: `LLMPolishStep.swift:211`, `:244`, `:252`. But note the subtlety: it is not guaranteed to be raw ASR anymore. Earlier steps can mutate it; `FillerRemovalStep` writes `ctx.text = result`: `FillerRemovalStep.swift:63-65`, and `TextProcessingRunner` passes the evolving context between steps: `TextProcessingRunner.swift:78-90`.

So define fallback precisely:

- If “deterministic fallback” means existing non-LLM post-processing, use `context.text`.
- If it means a new cleaner, invoke it in `LLMPolishStep` before/after classifier decision and set `ctx.polishedText` to that result.
- Rename or extend metadata; `filterFellBackToRaw` becomes misleading if fallback is no longer raw.

**Q6 — Biggest Missing Risk**
Verdict: **BIGGEST RISK: cold-start/loading on the hot path.**

The plan treats classifier cost as “~2ms,” but that is only warm inference. The codebase has already been burned by Apple model loads that do not observe cooperative cancellation: `WhisperKitBackend.swift:27-32`, `:46-50`; `WhisperKitPipeline.swift:163-168`.

`LLMPolishStep` and the runner are `@MainActor`: `LLMPolishStep.swift:11-12`, `TextProcessingRunner.swift:25`. Steps are invoked through the runner on that path: `TextProcessingRunner.swift:89-90`. A lazy Core ML / embedding load inside the first AFM polish can block the UI/paste path or outlive cancellation. The implementation needs a warm/load strategy, single-flight protection, and failure caching before it can be treated as a 2ms classifier.

**Overall Verdict**
**PROCEED-WITH-REVISIONS**

Required revisions:

1. Make the classifier a **serial pre-AFM gate**. Do not depend on aborting `respond(...)`.
2. If classifier lives in PostProcessing, wire it from `LLMPolishStep`, not from `EnviousWisprLLM`.
3. Add novel-words-only as a separate `EnviousOutputFilter` guard; do not promote the existing missing-word divergence check to always-on.
4. Define fallback as “current deterministic post-processing text” vs “raw ASR,” and update metadata naming accordingly.
5. Treat classifier cold-start/loading as a first-class heart-path risk, not part of the 2ms warm path.

Apple docs checked: https://developer.apple.com/documentation/FoundationModels/LanguageModelSession
