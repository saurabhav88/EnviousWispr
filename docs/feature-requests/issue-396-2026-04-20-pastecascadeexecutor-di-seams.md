# Issue #396 — PasteCascadeExecutor needs DI seams for honest cascade-level testing — 2026-04-20

GitHub issue: `#396`. Parent / epic: #385 (origin) and #319 Phase G (bible §17A). Tier: SMALL/MEDIUM (REFACTOR under Phase G). Status: DRAFT.

User Rubric: N/A — #319 Hardening and Refactors is internal-only.

---

## 0. TL;DR

`PasteCascadeExecutor.deliver(_:)` hard-calls static `PasteService` functions plus `AXIsProcessTrusted()`, `NSWorkspace.shared.frontmostApplication`, and live `Task.sleep`. PR #397 could only ship three clipboard-helper tests because three of six requested cascade scenarios were NOT_TESTABLE_WITHOUT_REFACTOR. Introduce three injectable seams (paste-service protocol, frontmost-app observer, clock/sleeper) with production defaults that reproduce today's wiring. SMALL/MEDIUM: ~80 LOC, one production file + protocols + tests.

## 1. Problem

`Sources/EnviousWisprPipeline/PasteCascadeExecutor.swift` (330 lines) implements the heart path's final step: get text to the user's active app. The cascade has three tiers (AX direct → CGEvent paste → AppleScript) with a save/restore clipboard envelope. Testing requires observing which tier fired, whether fallback was taken, and whether the clipboard was restored. Today, every dependency is a static free function call or a live system observer. No mocking possible without process-level fakes.

NOT_TESTABLE scenarios (from Codex truth-audit):
- (a) AX direct succeeds → cascade stops.
- (b) AX fails → CGEvent succeeds → clipboard-only not reached.
- (e) Executor-level clipboard save/restore orchestration.
- (f) Delayed-restore scheduling window.

Separate open design question (not in scope): CGEvent failure currently does NOT fall through to AppleScript. AppleScript only fires on activation timeout. Decide intent before writing the test for scenario (c). Phase G4 does NOT resolve this; it only introduces the seams that would let the test be written once intent is decided.

## 2. Goals & non-goals

### 2.1 Goals

- Introduce `PasteServiceProtocol` covering every static `PasteService` call the executor makes today.
- Inject frontmost-app observation + activation.
- Inject a clock / sleeper so activation timeout and clipboard-restore delay are deterministic in tests.
- Ship at least four tests covering scenarios (a), (b), (e), (f).
- Keep production wiring identical (default-valued init params route to the existing static functions).

### 2.2 Non-goals

- Resolving the CGEvent→AppleScript fall-through question.
- Rewriting the cascade policy itself. Refactor introduces seams only; behavior is identical.
- Replacing `PasteService` public API elsewhere in the codebase.
- Touching AX insertion internals beyond the seam boundary.

## 3. Design — revised 2026-04-20 after council

**Isolation decision (from council).** `NSWorkspace.shared.frontmostApplication`, `AXIsProcessTrusted`, and pasteboard APIs are main-actor-sensitive on macOS 14+. Declaring the seam protocols merely `Sendable` is the wrong abstraction — it would force cross-actor `await` hops that are unnecessary and invite compile errors on the delayed-restore closure. **Seam protocols are `@MainActor`** so they compose naturally with the executor (which runs on MainActor today — verify during implementation).

**Clock decision (from council).** Swift's native `any Clock<Duration>` handles the linear `Task.sleep` replacements at lines 145/179/195/208. The ONE case that is not a simple sleep is the delayed-restore queue in cascade step 2/3 (clipboard restore scheduled after a delay, needs to be queueable-and-manually-triggerable in tests). For that, a narrow `RestoreScheduler` protocol. Total: two seams, not one custom clock.

Three new protocols in `EnviousWisprPipeline`:

```swift
// Surface for today's static PasteService calls. MainActor because pasteboard work is.
@MainActor
public protocol PasteServiceProtocol {
  func isTextFieldRole(_ element: AXUIElement) -> Bool
  func insertViaAccessibility(_ text: String, element: AXUIElement) -> Bool
  func forceActivateApp(pid: pid_t) -> Bool
  func pasteToActiveApp(_ text: String) -> Bool
  func pasteViaAppleScript(pid: pid_t) -> Bool
  func saveClipboard() -> ClipboardSnapshot
  func restoreClipboard(_ snapshot: ClipboardSnapshot, changeCountAfterPaste: Int)
  func copyToClipboard(_ text: String)
  func copyToClipboardReturningChangeCount(_ text: String) -> Int
  func axIsProcessTrusted() -> Bool
}

// Surface for NSWorkspace reads + activation-wait. MainActor because NSWorkspace is.
@MainActor
public protocol FrontmostAppObserving {
  var currentFrontmostPID: pid_t? { get }
}

// Narrow queue-and-fire for the delayed clipboard-restore window.
// Live impl uses `Task.sleep` under the hood; test impl retains the closure until `triggerPendingRestores()` is called.
@MainActor
public protocol RestoreScheduler {
  func schedule(after interval: Duration, operation: @MainActor @escaping () -> Void)
}
```

**Linear sleeps** (`Task.sleep` at `:145` for activation poll interval) use Swift's native `any Clock<Duration>`:

```swift
private let clock: any Clock<Duration>
// ...
try? await clock.sleep(for: .milliseconds(pollInterval))
```

Executor construction:

```swift
@MainActor
public final class PasteCascadeExecutor {
  private let pasteService: any PasteServiceProtocol
  private let frontmost: any FrontmostAppObserving
  private let clock: any Clock<Duration>
  private let restoreScheduler: any RestoreScheduler

  public init(
    pasteService: any PasteServiceProtocol = LivePasteService(),
    frontmost: any FrontmostAppObserving = LiveFrontmostAppObserver(),
    clock: any Clock<Duration> = ContinuousClock(),
    restoreScheduler: any RestoreScheduler = LiveRestoreScheduler()
  ) {
    self.pasteService = pasteService
    self.frontmost = frontmost
    self.clock = clock
    self.restoreScheduler = restoreScheduler
  }
  // deliver(_:) rewrites static PasteService.* calls to self.pasteService.*, 
  // NSWorkspace reads to self.frontmost, Task.sleep to clock.sleep(for:), 
  // and the delayed clipboard-restore to self.restoreScheduler.schedule(after:operation:).
}
```

**Production wiring preservation.** `LivePasteService` calls the existing static `PasteService.*` functions verbatim. `LiveFrontmostAppObserver` reads `NSWorkspace.shared.frontmostApplication?.processIdentifier`. `LiveRestoreScheduler.schedule(after:operation:)` starts a detached `Task { try? await Task.sleep(for: interval); await MainActor.run { operation() } }`. Default `ContinuousClock()` preserves today's wall-clock semantics for the poll sleep.

**Test fakes:**
- `RecordingPasteService` records every method call (call-order list) and returns preset results per method.
- `FakeFrontmostAppObserver` returns a configurable PID.
- `ControllableClock` is a token-ish clock: `sleep(for:)` returns immediately but records the requested duration.
- `TestRestoreScheduler` stores the `operation` closure in a queue; tests call `triggerPendingRestores()` to fire them synchronously. Covers scenario (f) honestly.

## 4. MANDATORY Contract deltas — revised 2026-04-20 after grounded review

- **Added `PasteServiceProtocol`.** `@MainActor`-isolated (not just `Sendable`) because pasteboard + AX APIs are main-actor-sensitive on macOS 14+. Method signatures MIRROR the exact live-code shapes — grep-verify during implementation. Notable: `pasteToActiveApp(_:) -> PasteDispatchResult` (not `-> Bool` — v1 plan drift; real enum declared at `Sources/EnviousWisprServices/PasteService.swift:260`). `saveClipboard() -> ClipboardSnapshot`, `restoreClipboard(_ snapshot:changeCountAfterPaste:)`, etc.
- **Added `FrontmostAppObserving`.** `@MainActor`. Exposes the single read pattern the executor uses (PID-based frontmost check).
- **Added `RestoreScheduler`.** `@MainActor`. Narrow queue-and-fire surface for the delayed clipboard-restore window. Covers scenario (f) honestly.
- **Used `any Clock<Duration>`** (Swift 5.7+) as a fourth init param for the linear activation-poll sleep at `:145` and the pre-AppleScript stabilization sleep at `:195`. NO custom `PasteClock` type. Native Clock is sufficient for linear sleep; the queue-and-manually-trigger behavior lives on `RestoreScheduler`.
- **Changed `PasteCascadeExecutor.init(...)`** to accept FOUR optional params (paste service, frontmost observer, clock, restore scheduler), each with a production-default adapter.

Semantics: dependency-injection seams, no new policy. Production-default adapters route calls to today's free functions exactly. Tests pass fakes that record calls and control timing.

No persisted fields. No legacy data.

## 5. MANDATORY E2E state & lifecycle audit

| Path | Behavior under this change |
|---|---|
| Live / new dictation | Executor invoked on pipeline completion. Default adapters preserve today's behavior exactly. |
| Saved / reloaded item | N/A — executor has no persistence. |
| Retry or re-run | Re-polish → clipboard → paste path uses this executor too. Default wiring preserved. |
| Background / async completion arriving after state changed | Existing delayed-restore uses a scheduled `Task`. The `RestoreScheduler.schedule(after:operation:)` abstraction preserves that; production adapter is `Task { try? await Task.sleep(for: interval); await MainActor.run { operation() } }`. |
| User manual override / edit | N/A — user does not override paste mechanism. |

**Upstream sources.** Grep `grep -rn "PasteCascadeExecutor(" Sources/ Tests/`. Expected: production construction inside the pipeline's finalizer (and possibly re-polish path). Tests may construct with fakes.

**UI side effects.** None direct — executor drives system paste, which the foreground app observes. Envelope (clipboard save/restore) is invisible to UI.

**Persistence.** `NSPasteboard` is a system-shared surface. Real adapter mutates it exactly as today. Fake adapter does not.

**App-kill scenario.** If the app is killed mid-deliver, the delayed-restore never fires. Today's behavior. Unchanged.

**Concurrency guard.** Executor is MainActor (verify during implementation). Seam protocols are `@MainActor`-isolated, NOT just `Sendable` — pasteboard + AX + NSWorkspace are all main-actor-sensitive and the delayed-restore closure captures MainActor state. No new actor hop introduced; protocol methods compose naturally with the existing MainActor executor.

## 6. MANDATORY Downstream consumer matrix

| Contract delta | Consumer | Current | Required | Change? | Verified by |
|---|---|---|---|---|---|
| `PasteCascadeExecutor.init(pasteService:frontmost:clock:restoreScheduler:)` | production construction site (pipeline or finalizer) | no args | no args (defaults fill) | No | compile |
| (same) | new tests | N/A today | construct with fakes | **Yes** | new test file |
| Static `PasteService` callers elsewhere | grep-find all | unchanged | unchanged | No | grep |
| `AXIsProcessTrusted` / `NSWorkspace.frontmostApplication` callers elsewhere | grep-find all | unchanged | unchanged | No | grep |

Discovery:
```
grep -rn "PasteCascadeExecutor(" Sources/ Tests/
grep -rn "PasteService\." Sources/EnviousWisprPipeline/PasteCascadeExecutor.swift
grep -rn "NSWorkspace.shared.frontmostApplication\|AXIsProcessTrusted" Sources/EnviousWisprPipeline/PasteCascadeExecutor.swift
```

## 7. MANDATORY Failure-mode × caller table

All production failure paths preserved. Council added four heart-safety rows the v1 table missed:

| Failure mode | Origin | Caller | Expected UX | Persisted | Metadata | Retry |
|---|---|---|---|---|---|---|
| AX insertion fails | adapter (today: static fn) | cascade step 1 | cascade continues to step 2 | N/A | N/A | N/A |
| CGEvent paste fails | adapter | cascade step 2 | today: does NOT fall through to AppleScript (separate design question) | N/A | N/A | N/A |
| Activation times out | clock + frontmost observer | executor | fires AppleScript fallback | N/A | N/A | N/A |
| Clipboard restore fails | adapter | delayed restore | silent | user's clipboard may be stale | N/A | N/A |
| **Scheduled restore task throws or is cancelled** (new, from GPT council) | `RestoreScheduler` operation closure | delayed restore queue | clipboard stays polluted with delivered text; user sees dictation text on next paste | clipboard pasteboard holds delivered text | none | user must Cmd-C fresh |
| **Overlapping deliveries interleave save/restore** (new, from GPT council) | executor called twice within the restore window | cascade + `RestoreScheduler` | second delivery's save can capture the first delivery's still-posted text instead of the original user clipboard; restore restores the wrong snapshot | clipboard ends up with wrong content | none | no retry path, silent data-loss |
| **Activation-branch drift during refactor** (new, from GPT council) | regression in any of three cascade tiers' branch conditions while re-wiring from static calls to protocol calls | cascade | AppleScript branch fires when it should not, or CGEvent branch stops firing | N/A | N/A | N/A — characterization test required |
| **Logger-adjacent stall** (not applicable to paste; tracked here for symmetry with G2) | N/A | N/A | N/A | N/A | N/A | N/A |

No new *production* failure mode. Overlapping-deliveries row was always a silent bug; the seam makes it observable (test can reproduce). Test-only fakes synthesize any combination for coverage.

## 8. MANDATORY Caller-visible signals audit

- Executor has no implicit signals beyond what the pipeline already observes (completion, error events).
- Protocol defaults' production behavior must be identical to today's static calls. Verified by: construct executor with defaults in a test, assert a benchmark scenario produces identical observable side effects (clipboard change-count delta) as a control run without the refactor. Not strictly an "implicit signal," but the equivalent regression gate.

Grep to confirm no external reader of executor internals:
```
grep -rn "pasteService\b\|frontmostAppObserver\b" Sources/ Tests/
```

## 9. MANDATORY Fallback source-of-truth audit

No new fallback branch. The executor's existing cascade fallbacks preserve their source-of-truth: each tier either returns success (cascade stops) or failure (cascade advances). The "delivered text" is the `text` argument to `deliver(_:)`; the fallback on total cascade failure is "leave text on clipboard" (existing behavior).

## 10. File-by-file changes

- **`Sources/EnviousWisprPipeline/PasteCascadeExecutor.swift`**: FOUR init params (paste service, frontmost, clock, restore scheduler) + internal rewiring from statics to stored properties. Rewrite `pasteToActiveApp` call site to expect `PasteDispatchResult`, not `Bool` (grep-verify `Sources/EnviousWisprServices/PasteService.swift:276` during implementation).
- **New file** `Sources/EnviousWisprPipeline/PasteCascadeSeams.swift` (or bundled into executor file): three `@MainActor` protocols (`PasteServiceProtocol`, `FrontmostAppObserving`, `RestoreScheduler`) + three live adapters. Clock uses Swift's native `ContinuousClock()` as production default — no new type.
- **New test file** `Tests/EnviousWisprTests/Pipeline/PasteCascadeExecutorTests.swift`: `RecordingPasteService`, `FakeFrontmostObserver`, test-controlled `any Clock<Duration>`, and `TestRestoreScheduler` fakes + four scenario tests (per §11).

## 11. Testing

Unit tests (new):
- `axDirectSuccess_cascadeStopsBeforeCGEvent` — AX succeeds; assert `pasteToActiveApp` never called; assert no AppleScript invoked.
- `axFails_cgEventSucceeds_clipboardOnlyNotReached` — AX fails; CGEvent succeeds; assert `pasteViaAppleScript` not called; assert no clipboard-only-left state recorded.
- `deliver_saveAndRestoreClipboard_orchestrationOrder` — assert save happens before copy; restore happens after paste; ordering recorded deterministically via `ControllableClock`.
- `delayedRestoreWindow_firesAtExpectedInterval` — advance `ControllableClock` by the expected delay; assert `restoreClipboard` called exactly once; advance past, assert not called again.

UAT: runtime smoke via `wispr-eyes` + `record_tts` to confirm the refactor did not break real paste — required per `validation-discipline.md` §6 (runtime UAT catches what static review misses). Run on at least three target apps (Mail, Safari, VS Code) — paste is heart-path and this is the most invasive seam in Phase G.

Benchmarks: `scripts/heart-path-bench.sh --cold` must show no regression. The three protocol indirections add async dispatch but all calls are already `async`; expected overhead is under 5 ms per dictation.

## 12. Blast radius & rollback

Touched: `EnviousWisprPipeline` only (executor + new protocol file). Untouched: `PasteService`, AX internals, CGEvent wiring, AppleScript bridge. Rollback: single-commit revert; production callers omit the new args and compile unchanged. Delayed-restore timing unchanged.

## 13. Ship criteria

- [ ] `scripts/swift-test.sh` passes
- [ ] `swift build -c release` exit 0
- [ ] UAT: paste works in Mail, Safari, VS Code (record_tts + wispr-eyes)
- [ ] `scripts/heart-path-bench.sh --cold` shows no regression vs `.validation/latency-baselines.json`
- [ ] Writer-Codex truth-audit pass
- [ ] Adversarial-Codex review pass (fresh session)
- [ ] Four scenario tests per §11 pass
- [ ] Grep confirms no direct `PasteService.` / `NSWorkspace.frontmostApplication` / `AXIsProcessTrusted()` / `Task.sleep` calls remain in `PasteCascadeExecutor.swift`
- [ ] Zero em-dashes / en-dashes
- [ ] Architecture DoD: heart protection confirmed; Danger Zone rules (`architecture-rules.md` §Audio/ASR Danger Zones applies to paste as heart-critical) — seams introduce no new coupling between app shell and system internals

## 14. Open questions

- CGEvent→AppleScript fall-through (scenario c): design decision, NOT in scope for G4. Record decision separately and open a follow-on issue if behavior change is desired.
- Should `PasteServiceProtocol` be a single monolithic protocol or split into AX / CGEvent / AppleScript role protocols? Recommend monolithic for now; split only if a second consumer needs only a subset. Gemini flagged 10-method protocol will bloat test mocks with fatalErrors for unused methods — partially mitigated by `RecordingPasteService` that returns safe defaults for unused methods, not fatalErrors.
- **RESOLVED 2026-04-20 after council:** Clock decision — use native `any Clock<Duration>` for linear sleeps + narrow `RestoreScheduler` protocol for the queue-and-trigger case. Custom `PasteClock` wrapper dropped.
- **RESOLVED 2026-04-20 after council:** Executor MainActor isolation — confirmed main-actor on the executor (grep-verify during implementation); seam protocols declared `@MainActor` to compose naturally with AppKit APIs and the delayed-restore closure.

## 15. Related

- Origin epic: #385
- Bible: `docs/feature-requests/issue-319-2026-04-18-q2-hardening-epic.md` §17A Phase G (G4)
- Siblings: #388 (G1), #389 (G2), #394 (G3), #398 (G5)
- PR #397 — Target 2 clipboard-helper tests (shipped partial; unblocks the rest)
- Rule: `architecture-rules.md` §Audio/ASR Danger Zones (paste is heart-critical, same discipline)
