# Issue #398 — ASRManager setInitialBackendType/switchBackend reset branches need a seam to exercise from loaded state — 2026-04-20

GitHub issue: `#398`. Parent / epic: #385 (origin) and #319 Phase G (bible §17A). Tier: SMALL (REFACTOR under Phase G). Status: DRAFT.

User Rubric: N/A — #319 Hardening and Refactors is internal-only.

---

## 0. TL;DR

`ASRManager.setInitialBackendType(_:)` (`ASRManager.swift:45`) and `switchBackend(to:)` (`:52`) reset `isModelLoaded` and `isStreaming` to `false`. A cold manager already has both false — a test that starts cold, calls either method, and asserts `false` cannot distinguish "reset branch fired" from "reset branch deleted." Tonight's PR #400 shipped seven tests; an eighth covering `switchBackend` reset was dropped as SUBTLE_THEATER. Fix: inject backends (Option C from the issue body) so a fake backend can report `isReady=true` without a real model load, letting tests exercise the reset branches from a loaded state. SMALL: ~40 LOC, one production file + tests.

## 1. Problem

`Sources/EnviousWisprASR/ASRManager.swift:23-24`:

```swift
private var parakeetBackend = ParakeetBackend()
private var whisperKitBackend = WhisperKitBackend()
```

Both backends own model-loading state internally. `ASRManager.isModelLoaded` is set to `await self.activeBackend.isReady` inside `loadModel()`. To put a real manager into a "loaded" state, a test would have to invoke a real model download + load on the CI machine — not viable, not deterministic.

Original PR #400 test name:

```swift
// BEFORE (SUBTLE_THEATER):
func setInitialBackendTypeSelectsWhisperKitFromColdAndResetsFlags() { ... }

// AFTER (renamed; reset claim removed because unverifiable):
func setInitialBackendTypeSelectsWhisperKitFromCold() { ... }
```

The same blind spot blocks `switchBackend` reset-branch testing and any future coverage of in-flight throw recovery (scenarios a/c/d in the original Target 3 plan).

## 2. Goals & non-goals

### 2.1 Goals

- Inject `ParakeetBackend` and `WhisperKitBackend` through init so tests can provide fakes that claim `isReady=true` without a real model load.
- Default production init preserves today's wiring exactly (construct both concrete backends inline).
- Unblock at least three previously-NOT_TESTABLE scenarios: `switchBackend` reset from loaded state, `switchBackend` unloads previous backend, `setInitialBackendType` resets flags when called after synthetic load.

### 2.2 Non-goals

- Changing the backend protocol `ASRBackend`.
- Refactoring `ParakeetBackend` or `WhisperKitBackend` internals.
- Changing `ASRManagerInterface`.
- Adding test-only initializers that accept preset flag state (Option A from issue body) — rejected because it masks the real issue (backends are the seam, flags are derived state).
- `#if DEBUG` helpers (Option B) — rejected because "exposes state for testing" is an anti-pattern when the real fix is composable DI.

## 3. Design

Option C from the issue body: inject backends.

```swift
@MainActor
@Observable
public final class ASRManager: ASRManagerInterface {
  public private(set) var activeBackendType: ASRBackendType = .parakeet
  public private(set) var isModelLoaded = false
  public private(set) var isStreaming = false
  // ... other properties unchanged ...

  private var parakeetBackend: any ASRBackend
  private var whisperKitBackend: any ASRBackend

  public init(
    parakeetBackend: (any ASRBackend)? = nil,
    whisperKitBackend: (any ASRBackend)? = nil
  ) {
    self.parakeetBackend = parakeetBackend ?? ParakeetBackend()
    self.whisperKitBackend = whisperKitBackend ?? WhisperKitBackend()
  }

  public var activeBackend: any ASRBackend {
    switch activeBackendType {
    case .parakeet: return parakeetBackend
    case .whisperKit: return whisperKitBackend
    }
  }
  // ... unchanged ...
}
```

Tests construct `ASRManager(parakeetBackend: FakeReadyBackend(), whisperKitBackend: FakeReadyBackend())` where `FakeReadyBackend` reports `isReady=true` and records calls to `unload()`.

## 4. MANDATORY Contract deltas

- **Changed `ASRManager.init()`** to `init(parakeetBackend:whisperKitBackend:)` with both params optional and defaulting to the concrete types today's code constructs. Production callers (which all use `ASRManager()`) compile unchanged.
- **Changed `parakeetBackend` / `whisperKitBackend` property types** from concrete `ParakeetBackend` / `WhisperKitBackend` to `any ASRBackend`.
  - Semantics: the protocol is already the sole surface the rest of `ASRManager` consumes (via `activeBackend: any ASRBackend`). Existentials replace concretes with no loss of function.
  - Invariant: every caller continues to see a backend that conforms to `ASRBackend`. The switch in `activeBackend` still dispatches by `activeBackendType`.

No persisted fields. No legacy data.

## 5. MANDATORY E2E state & lifecycle audit

| Path | Behavior under this change |
|---|---|
| Live / new dictation | Production default init constructs real backends. Load / transcribe / streaming paths identical. |
| Saved / reloaded item | N/A — ASRManager does not persist. |
| Retry or re-run | Unchanged. |
| Background / async completion arriving after state changed | `inFlightLoadTask` single-flight logic unchanged. |
| User manual override / edit | Backend switch via UI / settings goes through `switchBackend(to:)` — unchanged observable behavior. |

**Upstream sources.** Grep `grep -rn "ASRManager(" Sources/ Tests/`. Expected: `AppState` construction + test harnesses. Verify count before changing.

**UI side effects.** UI observes `activeBackendType`, `isModelLoaded`, `isStreaming`, `downloadProgress` — all unchanged in production.

**Persistence.** None.

**App-kill scenario.** ASRManager is transient; no state recovery.

**Concurrency guard.** `@MainActor` on the class unchanged. Protocol existentials for backends are Sendable-compatible because `ASRBackend` is already `Sendable` (verify during implementation — if not, add conformance requirement or use `any ASRBackend & Sendable`).

## 6. MANDATORY Downstream consumer matrix

| Contract delta | Consumer | Current | Required | Change? | Verified by |
|---|---|---|---|---|---|
| `ASRManager.init(...)` | `AppState` | `ASRManager()` | `ASRManager()` (defaults fill) | No | compile |
| (same) | tests | may use `ASRManager()` today | may now pass fakes | Yes (test) | new test |
| `parakeetBackend` / `whisperKitBackend` property type | none external (`private`) | concrete | `any ASRBackend` | No (private) | compile |
| `activeBackend` getter | callers of `activeBackend` | returns `any ASRBackend` today | same | No | compile |
| `ASRManagerProxy` | existing proxy (grep-verify relationship) | unchanged | unchanged | No | compile |

Discovery:
```
grep -rn "ASRManager(" Sources/ Tests/
grep -rn "ParakeetBackend\|WhisperKitBackend" Sources/
grep -rn "activeBackend\b" Sources/
```

## 7. MANDATORY Failure-mode × caller table

All production failure paths preserved:

| Failure mode | Origin | Caller | Expected UX | Persisted | Metadata | Retry |
|---|---|---|---|---|---|---|
| `loadModel` throws | backend.prepare | `ASRManager.loadModel` | error propagates; `inFlightLoadTask` clears | N/A | N/A | user retry |
| `switchBackend` on same type | guard at `:53` | `switchBackend` | no-op (unchanged) | N/A | N/A | N/A |
| `finalizeStreaming` when `isStreaming=false` | guard at `:149` | `finalizeStreaming` | throws `ASRError.streamingNotSupported` (unchanged) | N/A | N/A | N/A |
| `unloadModel` while streaming | guard at `:168` | `unloadModel` | logs refusal (unchanged) | N/A | N/A | N/A |

No new production failure mode. Fake backends in tests can synthesize throws; test design chooses what to assert.

## 8. MANDATORY Caller-visible signals audit

- `parakeetBackend` / `whisperKitBackend` are `private`; no external consumers.
- `activeBackend` is `public` but its type (`any ASRBackend`) is unchanged.
- `isModelLoaded` / `isStreaming` continue to be `public private(set)` with the same semantics.

Grep to confirm no external reader of the private backends:
```
grep -rn "\.parakeetBackend\b\|\.whisperKitBackend\b" Sources/ Tests/
```

Expected: only inside `ASRManager.swift`.

## 9. MANDATORY Fallback source-of-truth audit

No new fallback branch.

## 10. File-by-file changes

- **`Sources/EnviousWisprASR/ASRManager.swift`**:
  - Lines 23-24: change property types from concrete to `any ASRBackend`.
  - Line 26: change `public init()` to `public init(parakeetBackend: (any ASRBackend)? = nil, whisperKitBackend: (any ASRBackend)? = nil)`; assign via `??` defaults.
- **New test file** `Tests/EnviousWisprASRTests/ASRManagerBackendInjectionTests.swift`:
  - `FakeASRBackend` (records calls, controllable `isReady`, controllable `unload()` / `prepare()` throws).
  - Three scenario tests per §11.
- **No other file changes**. `ASRManagerProxy` and `ASRManagerInterface` untouched.

## 11. Testing

Unit tests (new):
- `switchBackend_fromLoadedState_resetsIsModelLoadedToFalse` — construct with fake backends reporting `isReady=true`; simulate "loaded" state via a call to `loadModel` against a fake that succeeds synchronously; call `switchBackend(to: .whisperKit)`; assert `isModelLoaded == false`. This was PREVIOUSLY NOT_TESTABLE.
- `switchBackend_unloadsPreviousBackend` — construct with two recording fakes; set initial to parakeet; `switchBackend(to: .whisperKit)`; assert parakeet fake received `unload()` exactly once.
- `setInitialBackendType_afterLoad_resetsFlags` — construct with a fake; loadModel to set `isModelLoaded=true`; call `setInitialBackendType(.whisperKit)`; assert `isModelLoaded == false` AND `isStreaming == false`. Previously NOT_TESTABLE.
- `switchBackend_sameType_isNoOp` (council-added) — construct with two recording fakes; set initial to parakeet; call `switchBackend(to: .parakeet)`; assert neither fake received `unload()`; assert `activeBackendType` still `.parakeet`. Locks the guard at `:53`.
- `switchBackend_sameType_fromLoadedState_doesNotResetFlags` (council-added) — same-type switch from loaded state must preserve `isModelLoaded=true`. Regression gate against accidentally removing the early-return guard.

Existing tests in `ASRManagerColdStateContractTests` continue to pass unchanged — default init preserves cold-manager behavior.

UAT: none — internal-only, no observable behavior change in release. A dev-build smoke (open app, trigger a recording) is sufficient sanity.

Benchmarks: none required. Existential dispatch vs concrete has negligible impact at the granularity of an ASR call (whole call tree already crosses actor boundaries multiple times).

## 12. Blast radius & rollback

Touched: `EnviousWisprASR` only. Untouched: `EnviousWisprPipeline`, `AppState`, UI. Rollback: single-commit revert; no external call sites affected.

## 13. Ship criteria

- [ ] `scripts/swift-test.sh` passes
- [ ] `swift build -c release` exit 0
- [ ] Writer-Codex truth-audit pass
- [ ] Adversarial-Codex review pass (fresh session) — specifically asked to verify that reset-branch tests actually distinguish "branch fired" from "branch deleted," not just "flag ends up false"
- [ ] At least three new tests per §11 pass
- [ ] Grep confirms `ASRManager.swift:23-24` properties are `any ASRBackend`, not concrete
- [ ] Zero em-dashes / en-dashes
- [ ] `polish-eval-smoke` green (unchanged, but cheap to run)
- [ ] `scripts/heart-path-check.sh` green
- [ ] Architecture DoD: heart protection (ASR is heart), Danger Zone discipline — no new coupling between manager and concrete backends; protocol becomes the sole seam

## 14. Open questions

- **RESOLVED 2026-04-20 after council + grep:** `ASRBackend` is declared `public protocol ASRBackend: Actor` at `Sources/EnviousWisprASR/ASRProtocol.swift:9`. Actor conformance gives `Sendable` for free. `any ASRBackend` existentials ARE Sendable. Implication for tests: fakes must be `actor` types (not structs or classes). `final actor FakeASRBackend: ASRBackend { ... }`. Existing `ASRManager` already `await`s every backend call (`await activeBackend.prepare()`, `await activeBackend.unload()`, `await activeBackend.isReady`) — no new cross-actor work introduced by the injection.
- Should `ASRManagerProxy` receive the same DI pattern? Defer — G5 scope is manager only; proxy is a separate concern under its own issue if needed.
- **Council-flagged concern (Gemini 2026-04-20):** `@Observable` macro + existential stored properties. Should compile cleanly because `any ASRBackend` is Sendable via Actor conformance, but verify during implementation that Observation macro-synthesized code does not introduce unexpected isolation warnings. If it does, move the backend storage out of `@Observable` scope (e.g., into a nested non-observable holder).
- **Council-flagged edge case (GPT 2026-04-20):** `switchBackend` called with the same `type` as `activeBackendType` — today the guard at `:53` returns early. Tests should lock this behavior (no-op, no reset). Added as test case in §11.
- **Council-flagged edge case (GPT 2026-04-20):** unload failure on the previous backend during `switchBackend`. Today `await activeBackend.unload()` doesn't throw (per protocol); but if a future backend's unload hangs, `switchBackend` hangs. Not in G5 scope to fix; documented here for future issue.

## 15. Related

- Origin epic: #385
- Bible: `docs/feature-requests/issue-319-2026-04-18-q2-hardening-epic.md` §17A Phase G (G5)
- Siblings: #388 (G1), #389 (G2), #394 (G3), #396 (G4)
- PR #400 — Target 3 `ASRManagerColdStateContractTests` (shipped seven tests; this PR unblocks the eighth and more)
- Adjacency: bible §12 R2 (WhisperKitBackend adapter) — R2 narrows the backend's public surface; G5 injects the backend into the manager. Independent phases but both touch the ASR boundary.
