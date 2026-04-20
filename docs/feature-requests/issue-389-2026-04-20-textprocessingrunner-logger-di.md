# Issue #389 — TextProcessingRunner: make logger injectable for testability — 2026-04-20

GitHub issue: `#389`. Parent / epic: #385 (origin) and #319 Phase G (bible §17A). Tier: SMALL (REFACTOR aggregate under Phase G). Status: DRAFT.

User Rubric: N/A — #319 Hardening and Refactors is internal-only, no user-visible surface.

---

## 0. TL;DR

`TextProcessingRunner` calls `AppLogger.shared.log(...)` directly at six sites. Tests cannot verify log side effects (e.g., "a timeout produces a TextProcessing log entry"). Inject an `any PipelineLogging` with `AppLogger.shared`-equivalent default; tests pass an in-memory recorder. SMALL: ~30 LOC net, one production file + protocol + test.

## 1. Problem

`Sources/EnviousWisprPipeline/TextProcessingRunner.swift` has **six** call sites of `AppLogger.shared.log(...)` (grep-verified 2026-04-20, lines 33, 58, 63, 67, 72, 103). None are observable by tests without global-state inspection or disk reads, so tests skip log assertions entirely. Audit-classified problem: test theater — we claim to test logging behavior but do not. Coupled to #388 (same file, same refactor PR shape), but mechanically independent.

Found by Codex during 2026-04-19 audit (`docs/audits/2026-04-19-postasr-test-rewrite.txt`).

## 2. Goals & non-goals

### 2.1 Goals

- Replace direct `AppLogger.shared` usage with a `PipelineLogging` protocol dependency.
- Default-construct the runner with `AppLogger.shared` so production wiring is unchanged.
- Add at least one test that asserts a log side effect that was previously untestable.

### 2.2 Non-goals

- Refactoring `AppLogger` itself.
- Replacing `AppLogger.shared` elsewhere in the codebase.
- Changing the log format, category strings, or `LogLevel` taxonomy.
- Introducing the protocol in `Core` (Pipeline-local is enough; the Core dep direction stays clean).

## 3. Design

New protocol in `EnviousWisprPipeline`:

```swift
public protocol PipelineLogging: Sendable {
  func log(_ message: String, level: LogLevel, category: String) async
}
```

Adapter making the existing `AppLogger.shared` conform:

```swift
public struct AppLoggerAdapter: PipelineLogging {
  public init() {}
  public func log(_ message: String, level: LogLevel, category: String) async {
    await AppLogger.shared.log(message, level: level, category: category)
  }
}
```

`TextProcessingRunner` constructor:

```swift
@MainActor
internal final class TextProcessingRunner {
  private let logger: any PipelineLogging

  init(logger: any PipelineLogging = AppLoggerAdapter()) {
    self.logger = logger
  }
  // ...
}
```

All nine `await AppLogger.shared.log(...)` sites become `await self.logger.log(...)`. Production callers pass nothing (default wins); tests pass a recorder.

Test-side recorder:

```swift
final class RecordingPipelineLogger: PipelineLogging, @unchecked Sendable {
  struct Entry: Equatable { let message: String; let level: LogLevel; let category: String }
  private let lock = NSLock()
  private var entries: [Entry] = []
  func log(_ message: String, level: LogLevel, category: String) async {
    lock.lock(); defer { lock.unlock() }
    entries.append(.init(message: message, level: level, category: category))
  }
  func snapshot() -> [Entry] { lock.lock(); defer { lock.unlock() }; return entries }
}
```

## 4. MANDATORY Contract deltas

- **Added `PipelineLogging` protocol.**
  - Semantics: dependency injection seam for log sinks inside the Pipeline module. A policy type, not an event. No implicit runtime invariants on conforming types beyond the signature.
  - Invariant: production code that constructs `TextProcessingRunner` without arguments gets identical behavior to today (calls flow through `AppLogger.shared`).
- **Added `AppLoggerAdapter` struct.** Thin adapter; no state; no new behavior.
- **Changed `TextProcessingRunner.init()` signature** from implicit default (no params) to `init(logger: any PipelineLogging = AppLoggerAdapter())`. Default preserves every existing call site.

No persisted fields. No Codable. No legacy data.

## 5. MANDATORY E2E state & lifecycle audit

| Path | Behavior under this change |
|---|---|
| Live / new item | Runner invoked per dictation. Default logger routes to `AppLogger.shared`. Identical observable behavior. |
| Saved / reloaded item | N/A — runner transient. |
| Retry or re-run | `TranscriptPolishService` constructs or shares a runner; behavior unchanged with default logger. |
| Background / async completion arriving after state changed | Existing `Task { await AppLogger.shared.log(...) }` fire-and-forget shape is preserved. Await-on-logger is same semantics. |
| User manual override / edit | N/A. |

**Upstream sources.** Every construction of `TextProcessingRunner`. Grep `grep -rn "TextProcessingRunner(" Sources/ Tests/`. Expected: pipeline finalizer construction site(s) + test harnesses. If any call site passes a non-default logger today, Phase G must preserve intent.

**UI side effects.** None. Log output is already out-of-band from UI.

**Persistence.** `AppLogger.shared` writes to `~/Library/Logs/EnviousWispr/app.log` in dev builds; silent in release post-R3. The injection seam does not alter this; production default preserves it.

**App-kill scenario.** N/A.

**Concurrency guard.** Protocol method is `async` to match `AppLogger.shared.log`; MainActor isolation on runner unchanged.

## 6. MANDATORY Downstream consumer matrix

| Contract delta | Consumer | Current | Required | Change? | Verified by |
|---|---|---|---|---|---|
| `TextProcessingRunner.init(logger:)` (new default param) | runner construction site(s) in Pipeline module | calls `TextProcessingRunner()` | unchanged (default fills) | No | compile |
| (same) | test harnesses | may or may not construct runner | may now construct with `RecordingPipelineLogger` | Yes (test-only) | new test |
| `PipelineLogging` protocol | `AppLoggerAdapter` | N/A (new type) | conforms | N/A | compile |
| internal `logger.log(...)` calls | six sites in runner (lines 33, 58, 63, 67, 72, 103) | call `AppLogger.shared.log(...)` via `Task { }` | call `self.logger.log(...)` via `Task { }` | Yes | compile + recorder test |

Discovery method:
```
grep -rn "TextProcessingRunner(" Sources/ Tests/
grep -rn "AppLogger.shared" Sources/EnviousWisprPipeline/TextProcessingRunner.swift
```

## 7. MANDATORY Failure-mode × caller table

| Failure mode | Origin | Caller | Expected UX | Persisted | Metadata | Retry |
|---|---|---|---|---|---|---|
| logger throws or stalls | in-memory recorder in tests | runner | test asserts whatever it needs to | N/A | N/A | N/A |
| `AppLogger.shared` hangs in production | Pipeline logger call sites | `TextProcessingRunner` | currently fire-and-forget via `Task { }` — preserve that shape | N/A | N/A | N/A |
| **Logger stall makes text processing non-responsive** (new, from GPT council 2026-04-20) | injected logger blocking or hanging | `TextProcessingRunner.run(...)` | runner's own `await AppLogger.shared.log(...)` calls are currently inside `Task { }` fire-and-forget envelopes (grep-verify at lines 33, 58, 63, 67, 72, 103). Preserving that envelope is load-bearing — logging must NOT become heart-path-blocking | N/A | N/A | N/A |

Current production code wraps `AppLogger.shared.log(...)` in fire-and-forget `Task { }` at every site. Preserve that envelope; the DI change only swaps the target of the inner `await`.

## 8. MANDATORY Caller-visible signals audit

- `TextProcessingRunner.logger` — private, internal-only. No UI or persistence keying.
- `PipelineLogging` — no implicit runtime invariants beyond the signature.
- No change to `TextProcessingRunResult`.

Grep:
```
grep -rn "\.logger\b" Sources/
```
No external consumer should depend on the runner's logger slot.

## 9. MANDATORY Fallback source-of-truth audit

No new fallback branch.

## 10. File-by-file changes

- **`Sources/EnviousWisprPipeline/TextProcessingRunner.swift`**: add `private let logger`; add init param; swap nine `AppLogger.shared.log` sites to `self.logger.log`.
- **New file** `Sources/EnviousWisprPipeline/PipelineLogging.swift` (or appended to `TextProcessingRunner.swift` if council prefers one file): protocol + `AppLoggerAdapter`.
- **New test file** `Tests/EnviousWisprPipelineTests/TextProcessingRunnerLoggerTests.swift`: `RecordingPipelineLogger` + at least three tests (per §11).
- **Existing runner construction sites**: no change — default param covers them.

## 11. Testing

Unit tests (new):
- `stepTimeout_logsTextProcessingWarning` — run a step that exceeds its budget; assert the recorder contains a `TextProcessing` category entry with "timed out" in the message.
- `stepSuccess_logsPipelineTimingEntry` — run a successful step; assert a `PipelineTiming` entry exists.
- `correctionDebug_logsInOutWhenTextChanges` — run a step that mutates text; assert `CorrectionDebug` entries contain `IN:` and `OUT:` lines. (This is the log side effect that prior tests could not verify.)
- `correctionDebug_logsNoChangeWhenTextIdentical` — run a step that returns the same text; assert a `CorrectionDebug` "no change" entry.

UAT: none — internal-only.

Benchmarks: confirm no measurable overhead from the protocol indirection. Not expected given all log calls already hop off MainActor via `Task { }`.

## 12. Blast radius & rollback

Touched: `EnviousWisprPipeline` only. Untouched: `AppLogger`, AppState, UI, persistence. Rollback: single-commit revert; default param vanishes; production callers keep compiling because they never passed an argument.

## 13. Ship criteria

- [ ] `scripts/swift-test.sh` passes
- [ ] `swift build -c release` exit 0
- [ ] Writer-Codex truth-audit pass
- [ ] Adversarial-Codex review pass (fresh session)
- [ ] Grep confirms no direct `AppLogger.shared` calls remain in `TextProcessingRunner.swift`
- [ ] Recorder-based tests demonstrate at least one log side effect that was previously untestable
- [ ] Zero em-dashes / en-dashes
- [ ] `polish-eval-smoke` green
- [ ] `scripts/heart-path-check.sh` green

## 14. Open questions

- Co-land with #388 (same file)? Recommendation: separate PRs for clean revert, but share a worktree / branch-chain if sequencing is tight. Council to decide.
- Should `PipelineLogging` be promoted to `Core` for reuse by future pipelines? Today: no, YAGNI — keep it in `EnviousWisprPipeline`.

## 15. Related

- Origin epic: #385
- Bible: `docs/feature-requests/issue-319-2026-04-18-q2-hardening-epic.md` §17A Phase G (G2)
- Siblings: #388 (G1), #394 (G3), #396 (G4), #398 (G5)
- Audit: `docs/audits/2026-04-19-postasr-test-rewrite.txt`
