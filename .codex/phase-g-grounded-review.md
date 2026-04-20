# Grounded Review — Phase G (Test-seam DI pass) plans after council revisions

You are an independent reviewer with full codebase access. Scope: the 6 files listed below ONLY. Do NOT review other plans, the main bible body, or production code outside the cited paths.

## Context

We are about to start a multi-session refactor called Phase G. Five sub-phases (G1–G5), each a small DI seam refactor to unblock NOT_TESTABLE scenarios found by a CI test-quality audit (epic #385). Plans were drafted, reviewed by GPT + Gemini council (round 1, 2026-04-20), and revised based on council feedback. This is a grounded review: fact-check the revised plans against current code before we commit to execute.

The revised plans are:

1. Bible §17A — `docs/feature-requests/issue-319-2026-04-18-q2-hardening-epic.md` (read §17A Phase G only, roughly lines 2149-2260; also check §0.3 load map and §30 v1.14 changelog).
2. `docs/feature-requests/issue-388-2026-04-20-textprocessingrunner-polish-step-type.md` (G1)
3. `docs/feature-requests/issue-389-2026-04-20-textprocessingrunner-logger-di.md` (G2)
4. `docs/feature-requests/issue-394-2026-04-20-transcriptionpipeline-di-seams.md` (G3)
5. `docs/feature-requests/issue-396-2026-04-20-pastecascadeexecutor-di-seams.md` (G4)
6. `docs/feature-requests/issue-398-2026-04-20-asrmanager-backend-injection.md` (G5)

Key files in production you can read to verify claims:

- `Sources/EnviousWisprPipeline/TextProcessingRunner.swift`
- `Sources/EnviousWisprPipeline/TextProcessingStep.swift`
- `Sources/EnviousWisprPipeline/LLMPolishStep.swift`
- `Sources/EnviousWisprPipeline/WordCorrectionStep.swift`
- `Sources/EnviousWisprPipeline/FillerRemovalStep.swift`
- `Sources/EnviousWisprPipeline/TranscriptionPipeline.swift`
- `Sources/EnviousWisprPipeline/WhisperKitPipeline.swift`
- `Sources/EnviousWisprPipeline/TranscriptFinalizer.swift`
- `Sources/EnviousWisprPipeline/PasteCascadeExecutor.swift`
- `Sources/EnviousWisprASR/ASRManager.swift`
- `Sources/EnviousWisprASR/ASRProtocol.swift`
- `Sources/EnviousWispr/App/AppState.swift`

## What I need

Direct prose review, 800-1500 words. Your engineering opinion on:

1. **File:line citation accuracy.** Every plan cites specific file:line references. Verify each. List mismatches as `plan-path:section → claimed_line → actual_line` tuples. Specifically verify:
   - G1 plan's claim about `TextProcessingRunner.swift:99` dispatching on `stepName == "LLM Polish"`.
   - G2 plan's claim of six `AppLogger.shared.log(...)` sites at lines 33, 58, 63, 67, 72, 103.
   - G3 plan's claim about `TranscriptionPipeline.swift:119` and `WhisperKitPipeline.swift:142` both hardcoding `TranscriptFinalizer`.
   - G3 plan's claim that `TranscriptFinalizer.swift:60-61` has default-valued init params for `TextProcessingRunner` and `PasteCascadeExecutor`.
   - G4 plan's claims about `PasteCascadeExecutor.swift:106` (`AXIsProcessTrusted`), `:147`/`:157` (`NSWorkspace.frontmostApplication`), `:145`/`:179`/`:195`/`:208` (`Task.sleep`), and the 9 `PasteService.*` static call names.
   - G5 plan's claims about `ASRManager.swift:23-24` concrete backends, `:45` `setInitialBackendType`, `:52` `switchBackend`, `ASRProtocol.swift:9` `ASRBackend: Actor`.

2. **Swift 6 strict concurrency compile risk.** For each sub-phase's proposed code sketch, will it compile under this project's Swift 6 settings? Focus on:
   - G1: does adding `errorSurfacePolicy` to `TextProcessingStep` (keeping protocol inheritance as-is) risk Sendable propagation to conformers? Grep current conformer visibility.
   - G2: `PipelineLogging: Sendable` — will `LogLevel` satisfy Sendable? Any conformer concerns?
   - G4: `@MainActor` protocols + `any Clock<Duration>` default + `any RestoreScheduler` with `@MainActor @escaping` closure — does the delayed-restore closure capture `self` in a way that the compiler will accept? Specifically, if `PasteCascadeExecutor` is `@MainActor`, is the `RestoreScheduler.schedule(after:operation:)` closure capturing MainActor state safely?
   - G5: `any ASRBackend` (where `ASRBackend: Actor`) as a stored property on `@Observable @MainActor ASRManager` — does `@Observable` macro synthesize cleanly around an actor existential? If not, flag the expected error.

3. **"Mutually independent" correction accuracy.** Bible §17A.4 now claims G3 depends on G4 (G4's fake `PasteCascadeExecutor` makes `TranscriptFinalizer` testable via Option A). Is that accurate? Could G3 ship with Option A using only the existing `TextProcessingRunner` seam and NOT needing G4? Or is Option A still a trap?

4. **Option A vs Option B on G3.** Gemini called Option A a compile-time trap (can't mock a concrete `TranscriptFinalizer` in Swift 6 without a protocol). The plan now relies on the existing default-valued seams on the finalizer. Construct-with-fake-collaborators is different from mock-the-finalizer-itself. Is the plan's approach actually viable, or should G3 really be Option B?

5. **G4 test coverage of scenario (f).** The revised G4 replaces custom `PasteClock` with native `any Clock<Duration>` for linear sleeps + a narrow `RestoreScheduler` for the queue-and-trigger case. Does the delayed-restore code path at `PasteCascadeExecutor.swift:179`, `:195`, `:208` actually go through a single scheduler call that can be replaced with the protocol, or are there multiple code paths that need independent seams?

6. **Phase G scope honesty.** Does any sub-phase claim to unblock tests that it actually cannot? Specifically, does G5's "switchBackend from loaded state" test proposed in §11 work given the actor-based `ASRBackend` fakes? A fake `actor` backend has to report `isReady=true` somehow; how does the test reach a "loaded" state without running a real `loadModel()`?

7. **Overlapping-deliveries heart-safety concern.** G4's revised §7 adds an "overlapping deliveries interleave save/restore" row. Verify this is a real bug today by tracing the code: can `deliver(_:)` be called twice within the clipboard-restore window? Is the second save-snapshot taken BEFORE the first restore fires?

8. **Sequencing lockable.** Given everything you find, is G1+G2 bundled → G5 → G4 → G3 the correct order? Any specific blocker you'd flip?

9. **Anything the plans miss.** Call out gaps the council didn't catch and the revisions didn't add.

**Sign-off.** YES / YES_WITH_REVISIONS / NO plus a paragraph explaining the call. Be direct. Disagreement with the revised plan is wanted; cooperative approval is a failure mode.

**Rule.** Spot-check against actual code. If correct, say so. If wrong, name file:line. Grep before asserting; never rely on what the plan says the code contains without checking.
