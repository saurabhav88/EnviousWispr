# Issue #394 — TranscriptionPipeline not injectable — hard-wires TranscriptFinalizer and paste executor — 2026-04-20

GitHub issue: `#394`. Parent / epic: #385 (origin) and #319 Phase G (bible §17A). Tier: SMALL/MEDIUM (REFACTOR under Phase G). Status: DRAFT.

User Rubric: N/A — #319 Hardening and Refactors is internal-only.

---

## 0. TL;DR

`TranscriptionPipeline.init(...)` at `Sources/EnviousWisprPipeline/TranscriptionPipeline.swift:107-119` constructs its own `TranscriptFinalizer` inline. Tests cannot drive the pipeline directly with a mock finalizer. PR #391's HeartPathIntegrationTests worked around this with a local harness that bypassed the pipeline entirely. Fix: add an **internal / `@testable`-accessible** overload that accepts a pre-built `TranscriptFinalizer`; keep the current `public init(...)` production signature unchanged. SMALL: ~40 LOC, one production file + tests.

**Revised 2026-04-20 after grounded review (NO sign-off).** The v1 plan proposed a `public init(finalizer: TranscriptFinalizer? = nil)` signature. That is an access-control trap: `TranscriptFinalizer` is `internal` at `TranscriptFinalizer.swift:53`, so exposing it as a parameter on a `public` init widens visibility unnecessarily and is exactly the Swift-6 compile concern Gemini raised in round 1. Corrected design: add a SEPARATE `internal` init overload for tests, leave the `public init(...)` alone.

**Also corrected 2026-04-20:** v1 claimed G3 depends on G4 ("need fake `PasteCascadeExecutor` to mock finalizer"). FALSE — grep-verified `TranscriptFinalizer.swift:75-82` already exposes a closure-based seam init (`save:`, `textProcessingRunner:`, `deliverPaste:`), and `Tests/EnviousWisprTests/Pipeline/TranscriptFinalizerTests.swift:24` already uses it. Tests can construct a `TranscriptFinalizer` with fake closures today — no dependency on G4. G3 is independent.

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

## 3. Design — revised 2026-04-20 after grounded review

Add a second, **internal** init overload on `TranscriptionPipeline` that accepts a pre-built `TranscriptFinalizer`. Production callers use the existing `public init(...)` at `:107` unchanged. Tests use the internal overload via `@testable import EnviousWisprPipeline`.

```swift
public final class TranscriptionPipeline: DictationPipeline {
  private let transcriptFinalizer: TranscriptFinalizer
  // ... existing properties ...

  // Existing production init — UNCHANGED.
  public init(
    /* existing deps including transcriptStore */
  ) {
    // ... existing setup ...
    self.transcriptFinalizer = TranscriptFinalizer(transcriptStore: transcriptStore)
  }

  // NEW internal init for tests. Same module visibility as TranscriptFinalizer.
  // @testable import makes this reachable from Tests/EnviousWisprTests.
  internal init(
    /* same existing deps */,
    transcriptFinalizer: TranscriptFinalizer
  ) {
    // ... same existing setup ...
    self.transcriptFinalizer = transcriptFinalizer
  }
}
```

Tests construct the pipeline with a `TranscriptFinalizer` built from the existing closure seams (`save:`, `deliverPaste:` — grep-verified at `TranscriptFinalizer.swift:75-82`). Test code:

```swift
@testable import EnviousWisprPipeline

let recordingDeliverPaste: @MainActor (PasteDeliveryRequest) async -> PasteDeliveryResult = { req in
  recorder.append(req.text)
  return .success(/* whatever matches the real contract */)
}

let finalizer = TranscriptFinalizer(
  save: { _ in /* no-op */ },
  textProcessingRunner: TextProcessingRunner(),
  deliverPaste: recordingDeliverPaste
)

let pipeline = TranscriptionPipeline(/* existing deps */, transcriptFinalizer: finalizer)
```

No `TranscriptFinalizer` visibility change. No new public surface. No dependency on G4's paste executor.

**Why NOT the v1 `public init(finalizer:...)` approach:** `TranscriptFinalizer` is declared `internal` at `TranscriptFinalizer.swift:53`. Putting an internal type in a `public` init signature widens access on the type indirectly and costs us the narrow-access discipline from `architecture-rules.md` §Access Control. The internal-overload approach reuses existing seams, matches the `TranscriptFinalizerTests.swift:24` pattern already in the suite, and costs zero public-surface change.

**Why NOT go through `TranscriptFinalizer`'s closure seam directly at the pipeline level:** That would duplicate the finalizer-level injection and create two truthy paths to the same seam. Reuse the existing finalizer path; only open one new door at the pipeline level.

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
