# Issue #394 — TranscriptionPipeline not injectable — hard-wires TranscriptFinalizer and paste executor — 2026-04-20

GitHub issue: `#394`. Parent / epic: #385 (origin) and #319 Phase G (bible §17A). Tier: SMALL/MEDIUM (REFACTOR under Phase G). Status: DRAFT.

User Rubric: N/A — #319 Hardening and Refactors is internal-only.

---

## 0. TL;DR

`TranscriptionPipeline.init(...)` constructs its own `TranscriptFinalizer`; the finalizer owns the only clean paste seam (`deliverPaste`) plus the real text-processing runner. Tests cannot drive the pipeline directly with a mock paste executor or alternate LLM step. HeartPathIntegrationTests (PR #391) worked around this with a local harness. Fix: accept `TranscriptFinalizer` through init with a default that reproduces current production wiring (Option A). SMALL/MEDIUM: ~60 LOC, one production file + tests.

**Precondition (council-added 2026-04-20): G4 (#396) must merge before G3 starts.** Grep-verified 2026-04-20 that `TranscriptFinalizer.swift:60-61` already has default-valued seams for `TextProcessingRunner` and `PasteCascadeExecutor`. Option A relies on being able to construct a `TranscriptFinalizer` with fake collaborators inside tests. The fake `TextProcessingRunner` exists today (runner is already mockable); the fake `PasteCascadeExecutor` does NOT exist until G4 ships. Without G4, Option A compiles but the resulting test cannot observe paste behavior — defeats the point. Fallback if G4 reveals deeper blockers: switch G3 to Option B (inject paste seam + runner directly as a dependency struct; no reliance on finalizer construction).

## 1. Problem

`Sources/EnviousWisprPipeline/TranscriptionPipeline.swift` (1319 lines) constructs `TranscriptFinalizer` internally (grep-verify exact line). Tests that want to exercise the heart path end-to-end must either:

1. Build the pipeline and let it hit a real `TranscriptFinalizer` → real paste (clipboard mutation in test) → real persistence. Fragile and hostile in CI.
2. Build a shadow harness around `TranscriptFinalizer` and skip `TranscriptionPipeline` altogether — what PR #391 ended up doing.

Consequence: cancellation observability is indirect (the harness infers paste non-occurrence rather than observing it on the pipeline surface). Any future coverage (streaming, pre-warm, backend switching) has the same blocker.

## 2. Goals & non-goals

### 2.1 Goals

- Add init-time DI for `TranscriptionPipeline`'s collaborators so tests can pass mocks for paste delivery and text processing.
- Preserve heart-path behavior exactly in release.
- Unblock at least one previously-NOT_TESTABLE scenario in `HeartPathIntegrationTests`.

### 2.2 Non-goals

- Redesigning `TranscriptFinalizer`'s public surface. Accepting it as an injected dependency is enough.
- Changing `WhisperKitPipeline` in this phase. `TranscriptionPipeline` and `WhisperKitPipeline` stay intentionally separate per `architecture-rules.md` §Intentional Duplication.
- Unifying paste delivery across pipelines.
- Introducing an `any TranscriptionPipelineDelegate` protocol in this PR. A default-valued struct is enough; a protocol can come later if another pipeline needs it.

## 3. Design

Two options; recommend Option A (smaller surface, same testability).

**Option A (recommended): inject `TranscriptFinalizer`.**

```swift
public final class TranscriptionPipeline: DictationPipeline {
  private let finalizer: TranscriptFinalizer
  // ... existing properties ...

  public init(
    /* existing deps */,
    finalizer: TranscriptFinalizer? = nil
  ) {
    // ... existing setup ...
    self.finalizer = finalizer ?? TranscriptFinalizer(/* current production args */)
  }
}
```

Default preserves production wiring. Tests pass a `TranscriptFinalizer` built from mock sub-collaborators.

**Option B: inject the finalizer's two most-useful seams directly.**

```swift
public struct TranscriptionPipelineDependencies {
  public let deliverPaste: @MainActor (String) async -> Void
  public let textProcessingRunner: TextProcessingRunner
  // default-initializer reproduces current production wiring
}
```

Option B is narrower but introduces a new dependency-object type. Option A reuses the existing finalizer as the seam and keeps the pipeline's public surface almost unchanged (one new optional init param).

**Prefer Option A** unless grep-verification reveals that `TranscriptFinalizer` itself is not testably constructible with mocks today (in which case the real blocker is inside the finalizer, and #394 needs to pull #396's paste-executor work forward). Grep before writing code.

## 4. MANDATORY Contract deltas

- **Changed `TranscriptionPipeline.init(...)` signature** — added one optional parameter `finalizer: TranscriptFinalizer? = nil`.
  - Semantics: Dependency injection seam. Nil = "use production default"; non-nil = "use this one."
  - Invariant: production callers omitting the arg get identical behavior to today. Tests passing a mock-backed finalizer observe paste delivery through their mock, not through the real paste path.
- **No new public types.** `TranscriptFinalizer` is already public (grep-verify — if not, promote only the minimal surface the pipeline's init needs, or go Option B).

No persisted fields. No legacy data.

## 5. MANDATORY E2E state & lifecycle audit

| Path | Behavior under this change |
|---|---|
| Live / new dictation | Production wiring identical. Default-constructed finalizer. Heart path completes as today. |
| Saved / reloaded item | N/A — pipeline is a per-session orchestrator; it does not persist. |
| Retry or re-run | Unchanged. Re-polish flows through `TranscriptPolishService`, not the pipeline. |
| Background / async completion arriving after state changed | Existing cancellation + late-state guards at `TranscriptionPipeline.swift:372` remain. |
| User manual override / edit | Unchanged. |

**Upstream sources.** Every construction of `TranscriptionPipeline`. Grep `grep -rn "TranscriptionPipeline(" Sources/ Tests/`. Expected: `AppState` is the single production construction site (verified by prior sessions per bible §4.1). Tests may construct with mock finalizer.

**UI side effects.** None — UI observes pipeline state transitions, not its collaborators.

**Persistence.** `TranscriptFinalizer.swift:126` calls `try save(transcript)` — this stays identical in production. In tests with a mock finalizer, tests decide whether to persist.

**App-kill scenario.** Unchanged — pipeline is transient.

**Concurrency guard.** Init-time injection does not cross actor boundaries (both constructor and default are MainActor per existing pipeline isolation).

## 6. MANDATORY Downstream consumer matrix

| Contract delta | Consumer | Current | Required | Change? | Verified by |
|---|---|---|---|---|---|
| `TranscriptionPipeline.init(finalizer:)` | `AppState` (production) | omits param | omits param, gets default | No | compile |
| (same) | `HeartPathIntegrationTests` | constructs ad-hoc harness | constructs pipeline with mock finalizer | **Yes (test)** | new test file |
| Future test scenarios (streaming, backend switch) | (not yet written) | blocked | unblocked | Yes (future) | follow-on tests |

Discovery method:
```
grep -rn "TranscriptionPipeline(" Sources/ Tests/
grep -rn "TranscriptFinalizer(" Sources/ Tests/
```

## 7. MANDATORY Failure-mode × caller table

| Failure mode | Origin | Caller | Expected UX | Persisted | Metadata | Retry |
|---|---|---|---|---|---|---|
| mock finalizer throws in test | test harness | pipeline under test | test asserts | N/A | N/A | N/A |
| production finalizer throws (same as today) | finalizer internal | pipeline | current behavior preserved | depends on where | current | current |

No new production failure mode. Phase G3 does not alter any error path.

## 8. MANDATORY Caller-visible signals audit

- `TranscriptionPipeline.finalizer` — private, internal-only. No UI / persistence keys off it.
- No changes to `Transcript` or `DictationPipelineEvent`.

Grep:
```
grep -rn "\.finalizer\b\|TranscriptFinalizer\b" Sources/
```

Confirm no external code reaches into pipeline internals for the finalizer today (would be an architectural violation regardless).

## 9. MANDATORY Fallback source-of-truth audit

No new fallback branch. If the mock finalizer throws in a test, the test is the source-of-truth for the assertion. Production path is unchanged.

## 10. File-by-file changes

- **`Sources/EnviousWisprPipeline/TranscriptionPipeline.swift`**: add optional `finalizer:` init param; assign internal `self.finalizer = finalizer ?? TranscriptFinalizer(...)`.
- **Possibly** `Sources/EnviousWisprPipeline/TranscriptFinalizer.swift`: promote visibility on any member the new init needs. Prefer not to widen; if a widening is required, disclose in PR per `architecture-rules.md` §Access Control.
- **New tests** in `Tests/EnviousWisprPipelineTests/TranscriptionPipelineInjectionTests.swift`: construction sanity + one heart-path scenario that was previously NOT_TESTABLE.

## 11. Testing

Unit tests (new):
- `defaultFinalizer_isUsedWhenNilPassed` — construct pipeline without arg; assert finalizer is non-nil and wired.
- `injectedFinalizer_drivesPasteDelivery` — construct pipeline with a mock finalizer whose paste seam records the text; trigger the completion path (or nearest direct equivalent); assert mock recorded the expected text.
- `cancellationBeforeFinalize_doesNotInvokeDeliverPaste` — previously NOT_TESTABLE without seam. With a recording finalizer, assert no paste was delivered after cancellation.

UAT: none — internal-only behavior unchanged in release.

Benchmarks: confirm no measurable change. Optional param default is a no-op when omitted.

## 12. Blast radius & rollback

Touched: `EnviousWisprPipeline` (pipeline file, possibly finalizer visibility tweak). Untouched: `WhisperKitPipeline`, AppState, UI, persistence, paste implementation. Rollback: single-commit revert; default param vanishes; `AppState` construction compiles unchanged.

## 13. Ship criteria

- [ ] `scripts/swift-test.sh` passes
- [ ] `swift build -c release` exit 0
- [ ] Writer-Codex truth-audit pass
- [ ] Adversarial-Codex review pass (fresh session)
- [ ] New test demonstrates a heart-path scenario now testable that was NOT_TESTABLE before
- [ ] `polish-eval-smoke` green
- [ ] `scripts/heart-path-check.sh` green — heart path latency unchanged
- [ ] Zero em-dashes / en-dashes
- [ ] Architecture DoD: heart protection confirmed; no access widening beyond minimum; intentional-duplication rule respected (WhisperKitPipeline untouched)

## 14. Open questions

- Option A (inject finalizer) vs Option B (inject two seams): council to pick. Recommendation A unless finalizer itself is not cleanly mockable.
- Should we promote `TranscriptionPipelineDependencies` to a named type now (Option B) in anticipation of symmetric work on `WhisperKitPipeline`? Recommendation: no — YAGNI. Defer until a second pipeline actually needs it.

## 15. Related

- Origin epic: #385
- Bible: `docs/feature-requests/issue-319-2026-04-18-q2-hardening-epic.md` §17A Phase G (G3)
- Siblings: #388 (G1), #389 (G2), #396 (G4), #398 (G5)
- Related PRs: #391 (HeartPathIntegrationTests), #392 (pipeline error-path bug), #393 (finalizer empty-check spec)
- Rule: `architecture-rules.md` §Intentional Duplication (do not collapse pipelines)
