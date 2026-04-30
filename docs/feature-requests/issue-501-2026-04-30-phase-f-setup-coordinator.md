# Phase F — SetupCoordinator extraction (#501)

Parent epic: #319 (Hardening & Refactors). Bible §17. Depends on: nothing (independent). Blocks: Phase E (#502 — ceiling calibration).

## Preface — Lane + Live UAT declaration (PR #498 — MANDATORY)

- **Declared lane:** code (mixed_pr: false)
- **Phase 3 obligations:** logic tests + smoke + Live UAT (synthetic dictation through real speakers + Settings tab visual confirmation) + Codex code-diff
- **Live UAT:** Y — manual-human required for the Settings UI portion (no synthetic AX path covers Settings tabs cycling through setup states); synthetic dictation covers the heart-path regression check

## Preface — User Rubric

User Rubric: N/A — Hardening & Refactors is internal-only (Bible §0.7). No user-visible surface change. Settings tabs must look and behave identically.

## 0. TL;DR

Bundle three setup-related concerns currently owned by AppState (`ollamaSetup`, `whisperKitSetup`, `whisperKitPreloadTask` plus the observation wiring) into a new `SetupCoordinator` class living **alongside AppState in the existing executable target** (`Sources/EnviousWispr/App/SetupCoordinator.swift` — no new SPM target). AppState owns one `setup` property instead of three, exposed concretely (`let setup: SetupCoordinator`, not `any SetupCoordinating`). View call sites change `appState.X` → `appState.setup.X` (38 mechanical rewrites across 3 files). Net: AppState concrete-property count drops from 19 → 17. Pre-loaded for Phase E ceiling calibration.

**Revised 2026-04-30 post-grounded-review:** Codex (`docs/audits/2026-04-30-phase-f-grounded-review.txt`) returned PROCEED-WITH-REVISIONS, killing the new SPM library target. D7's primary rationale (test-target access) is stale — `Package.swift:134` already includes `"EnviousWispr"` as a dep of `EnviousWisprTests`. New target would force unnecessary `public` API exposure on app-shell code, contradicting `architecture-rules.md` "public is expensive." Phase F now ships F-Exec.

## 1. Problem

AppState owns 19 file-scope concrete properties. Three of them — `ollamaSetup` (Ollama for cloud-style polish), `whisperKitSetup` (WhisperKit model lifecycle), `whisperKitPreloadTask` (background observation that triggers a model preload when WhisperKit becomes ready) — form a single cohesive concern (initial setup of optional limbs) that does not need to live on the central state object. Phase A+C+D shaved AppState to its current shape; Phase F removes the next-cohesive-cluster. Without F, Phase E's regression-test ceilings cannot be calibrated honestly because the post-A+C+D state is not the architectural target.

## 2. Goals & non-goals

### 2.1 Goals

- AppState's three setup properties consolidated into one new owner.
- New `SetupCoordinator` lives in `Sources/EnviousWispr/App/SetupCoordinator.swift` (executable target). No new SPM target.
- AppState exposes `let setup: SetupCoordinator` concretely (NOT `any SetupCoordinating`) — `OnboardingV2View.swift:39-42` documents that SwiftUI `@Observable` tracking does not work through protocol existentials.
- All view consumers continue observing the same `OllamaSetupService` / `WhisperKitSetupService` instances (Option A passthrough — no semantic-API wrapper).
- `PipelineSettingsSync.onNeedsPreloadObservation` callback rerouted to call SetupCoordinator instead of AppState.
- Settings tabs (AI Polish, Speech Engine) render and respond identically to current behavior.
- Heart path is unaffected (raw transcription does not depend on setup services).

### 2.2 Non-goals

- No semantic-API wrapping (Option B per Bible §17.3 substep 2). Property-passthrough only. If a future phase needs `setup.ollamaReady`-style accessors, that is a separate phase.
- No `reset()` method on the protocol (per Bible §17.3.1; no caller exists).
- No extraction of `BenchmarkCoordinator` or `TelemetryObservationCoordinator` (Bible §17.7 — post-epic).
- No move of `OllamaSetupService` or `WhisperKitSetupService` themselves; they already live in `EnviousWisprLLM` and `EnviousWisprASR` respectively.

## 3. Design

### 3.1 No Package.swift changes

`SetupCoordinator` lives in `Sources/EnviousWispr/App/SetupCoordinator.swift` alongside AppState. No new SPM target. `EnviousWisprTests` already depends on `"EnviousWispr"` (`Package.swift:134`), so unit tests can import SetupCoordinator directly. Future extraction to a library target stays an option if a second production module ever needs it.

### 3.2 SetupCoordinator class

```swift
// Sources/EnviousWispr/App/SetupCoordinator.swift
import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLLM

// Internal — no public API; lives in executable target alongside AppState.
@MainActor
@Observable
final class SetupCoordinator {
  let ollamaSetup = OllamaSetupService()
  let whisperKitSetup = WhisperKitSetupService()

  @ObservationIgnored
  private var whisperKitPreloadTask: Task<Void, Never>?

  private let asrManager: any ASRManagerInterface
  private let preloadAction: @MainActor () async -> Void

  init(
    asrManager: any ASRManagerInterface,
    preloadAction: @escaping @MainActor () async -> Void
  ) {
    self.asrManager = asrManager
    self.preloadAction = preloadAction
  }

  func startPreloadObservation() {
    whisperKitPreloadTask?.cancel()
    whisperKitPreloadTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        guard self.asrManager.activeBackendType == .whisperKit else { return }
        let currentState = self.whisperKitSetup.setupState
        if currentState == .ready {
          await self.preloadAction()
          return
        }
        await withCheckedContinuation { continuation in
          withObservationTracking {
            _ = self.whisperKitSetup.setupState
          } onChange: {
            continuation.resume()
          }
        }
      }
    }
  }
}
```

The body of `startPreloadObservation()` is a verbatim move of `AppState.startWhisperKitPreloadObservation()` (currently lines 639–668), with `self.asrManager` and `self.preloadAction` substituted for the AppState-bound references.

### 3.3 AppState shape change

```swift
// Sources/EnviousWispr/App/AppState.swift — diff sketch

// REMOVED (lines 25, 26, 31 today):
// let ollamaSetup = OllamaSetupService()
// let whisperKitSetup = WhisperKitSetupService()
// private var whisperKitPreloadTask: Task<Void, Never>?

// ADDED at file scope (in same region):
let setup: SetupCoordinator

// REMOVED (lines 637–668 today): startWhisperKitPreloadObservation() body
// — entire method moves to SetupCoordinator.

// CHANGED in init() after asrManager + whisperKitPipeline are constructed:
self.setup = SetupCoordinator(
  asrManager: asrManager,
  preloadAction: { [weak whisperKitPipeline] in
    await whisperKitPipeline?.prepareBackendSilently()
  }
)

// CHANGED at line 375:
settingsSync.onNeedsPreloadObservation = { [weak setup = self.setup] in
  setup?.startPreloadObservation()
}

// CHANGED at line 619 (the "kick the tires" call right after init):
Task { [weak self] in
  await self?.setup.whisperKitSetup.detectState()
  self?.setup.startPreloadObservation()
}
```

`PipelineSettingsSync` keeps taking `whisperKitSetup: WhisperKitSetupService` directly. AppState passes `setup.whisperKitSetup` instead of the old top-level property at the construction site (line 217).

### 3.4 D7 supersession

D7 (decisions doc 2026-04-18) said "build SetupCoordinator in a library target from day one." Its primary rationale (test-target access) was stale — `Package.swift:134` already includes `"EnviousWispr"` in `EnviousWisprTests.dependencies`. Codex grounded review 2026-04-30 (`docs/audits/2026-04-30-phase-f-grounded-review.txt`) recommended PROCEED-WITH-REVISIONS specifically to drop the library target: a new SPM module forces unnecessary `public` API exposure on app-shell code, contradicting `architecture-rules.md` "public is expensive" rule. **D7 is superseded by Phase F's grounded review.** Update `issue-319-open-decisions-2026-04-18.md` D7 entry as part of this PR.

### 3.5 Edge cases (per workflow-process §10)

- **Interrupted:** SetupCoordinator deinit has `whisperKitPreloadTask?.cancel()` not explicitly written but the Task captures `[weak self]` so cancellation propagates when the coordinator is freed. AppState owns it for the app lifetime, so this is theoretical.
- **Deleted:** N/A — `setup` is a `let` on AppState, no deletion path.
- **Mutated:** Backend-switch settings change calls `onNeedsPreloadObservation` → `setup.startPreloadObservation()`, which cancels the prior task and restarts. Identical behavior to today.
- **Concurrent:** Two backend switches in fast succession → both fire `startPreloadObservation()` → first task cancels, second proceeds. Identical to today.
- **Nil:** `[weak setup = self.setup]` capture in the `onNeedsPreloadObservation` closure handles AppState death (theoretical) without keeping setup alive.
- **Stale:** Views observe `setup.ollamaSetup` and `setup.whisperKitSetup` directly. SwiftUI's @Observable change tracking sees the underlying service's properties changing because the path `appState.setup.ollamaSetup.setupState` traverses two `@Observable` boundaries (AppState and SetupCoordinator both are @Observable, the leaf service is @Observable). Spot-check during Live UAT.

## 4. **MANDATORY** Contract deltas

| Symbol | Before | After | Visibility | Notes |
|---|---|---|---|---|
| `AppState.ollamaSetup` | `let ollamaSetup: OllamaSetupService` | removed | — | replaced by `appState.setup.ollamaSetup` |
| `AppState.whisperKitSetup` | `let whisperKitSetup: WhisperKitSetupService` | removed | — | replaced by `appState.setup.whisperKitSetup` |
| `AppState.whisperKitPreloadTask` | `private var Task<Void, Never>?` | removed | — | moves to `SetupCoordinator` |
| `AppState.startWhisperKitPreloadObservation()` | `private func` | removed | — | body moves to `SetupCoordinator.startPreloadObservation()` |
| `AppState.setup` | — | `let setup: SetupCoordinator` | internal | new owned property — concrete type, NOT existential (preserves @Observable tracking) |
| `SetupCoordinator` | — | `final class @MainActor @Observable` | internal | new — lives in executable target |

No protocol surface in v1. No `public` API. No `reset()`.

## 5. **MANDATORY** E2E state & lifecycle audit

State that lives in SetupCoordinator: the two service instances + the preload task handle. State that lives elsewhere and is read by SetupCoordinator: `asrManager.activeBackendType` (read-only via interface), `whisperKitPipeline.prepareBackendSilently()` (call-only via injected closure). No new persisted state. No new app-lifecycle hooks.

App-quit cleanup: `appState.ollamaSetup.cleanup()` at `AppDelegate.swift:417` becomes `appState.setup.ollamaSetup.cleanup()`. No new cleanup needed for SetupCoordinator itself; the Task is owned and will be cancelled when the coordinator deinits at app termination.

## 6. **MANDATORY** Downstream consumer matrix

| Consumer | File | Sites | Migration |
|---|---|---|---|
| AI Polish Settings tab | `Sources/EnviousWispr/Views/Settings/AIPolishSettingsView.swift` | 29 | `appState.ollamaSetup.X` → `appState.setup.ollamaSetup.X` |
| Speech Engine Settings tab | `Sources/EnviousWispr/Views/Settings/SpeechEngineSettingsView.swift` | 8 | `appState.whisperKitSetup.X` → `appState.setup.whisperKitSetup.X` |
| AppDelegate quit hook | `Sources/EnviousWispr/App/AppDelegate.swift:417` | 1 | `appState.ollamaSetup.cleanup()` → `appState.setup.ollamaSetup.cleanup()` |
| PipelineSettingsSync init | `Sources/EnviousWispr/App/AppState.swift:217` | 1 | pass `setup.whisperKitSetup` instead of `whisperKitSetup` |
| AppState.init internal | `Sources/EnviousWispr/App/AppState.swift:619, 620, 375` | 3 | route through `self.setup` |

Total: **42 sites** (38 external + 4 internal). All mechanical rewrites. Verified by Codex grep 2026-04-30.

## 7. **MANDATORY** Failure-mode × caller table

| Failure | Caller | Behavior before | Behavior after | Heart-path impact |
|---|---|---|---|---|
| OllamaSetupService unreachable | AI Polish view | Status shows "not running", buttons reflect state | Identical (same instance, same observation path) | None — limb |
| WhisperKitSetupService download fails | Speech Engine view | Status shows error, retry button enabled | Identical | None — limb |
| Backend switch during preload | settingsSync | Old preload task cancels, new starts | Identical (cancellation logic moves verbatim) | None — limb |
| App quit during pull | AppDelegate | `ollamaSetup.cleanup()` cancels active pull | Identical | None |

No failure mode changes. Heart path (audio capture → ASR → paste) does not consult either setup service.

## 8. **MANDATORY** Caller-visible signals audit

Settings tabs subscribe to `@Observable` property changes via SwiftUI's tracking. The change `appState.ollamaSetup.setupState` → `appState.setup.ollamaSetup.setupState` lengthens the keypath but does not change the observation graph: SwiftUI walks `appState` (Observable) → `setup` (Observable, new) → `ollamaSetup` (Observable, same) → `setupState`. All three boundaries are tracked. Live UAT must confirm that state transitions still re-render the views without lag or stuck state.

## 9. **MANDATORY** Fallback source-of-truth audit

No fallbacks. If SetupCoordinator misbehaves, the user sees broken Settings tabs but heart-path dictation continues. Per heart/limbs doctrine, this is acceptable — Settings UI for limb configuration is itself a limb.

## 10. File-by-file changes

| File | Change | Est. LOC delta |
|---|---|---|
| `Sources/EnviousWispr/App/SetupCoordinator.swift` | NEW (executable target, internal API) | +85 |
| `Sources/EnviousWispr/App/AppState.swift` | Remove 3 properties + 1 method; add 1 property; rewire 3 call sites | −40, +10 |
| `Sources/EnviousWispr/Views/Settings/AIPolishSettingsView.swift` | 29 mechanical renames | ±29 (no net LOC) |
| `Sources/EnviousWispr/Views/Settings/SpeechEngineSettingsView.swift` | 8 mechanical renames | ±8 (no net LOC) |
| `Sources/EnviousWispr/App/AppDelegate.swift` | 1 mechanical rename | ±1 |
| `Sources/EnviousWispr/App/PipelineSettingsSync.swift` | No change to sync itself; AppState passes `setup.whisperKitSetup` at construction site | 0 |
| `Tests/EnviousWisprTests/Architecture/SetupCoordinatorTests.swift` | NEW — preload observation start/cancel/fire test with fake `ASRManagerInterface` + recording closure | +75 |
| `docs/feature-requests/issue-319-open-decisions-2026-04-18.md` | Update D7 entry: superseded by Phase F grounded review | +5 |

**Net: ~+135 lines.** No `Package.swift` change, no new SPM target.

## 11. Testing

### 11.1 Live UAT spec

**Pre-build:** `scripts/swift-test.sh` green.

**Build:** `/wispr-rebuild-and-relaunch`.

**Synthetic dictation regression (Code-lane default):**
- `Tests/UITests/wispr_eyes.py test_recording(audio=tts("Phase F regression check sample one"), sentence="Phase F regression check sample one", hold=2.5, expect="Phase F", timeout=15)`. Expected: clipboard contains the transcribed sentence within 15 seconds. Confirms heart path unaffected.

**Settings UI manual-human (cannot be synthesized):**
1. Open Settings → Speech Engine. Confirm WhisperKit setup state matches current backend (ready/downloading/etc.).
2. Trigger a backend switch (toggle Speech Engine selection if WhisperKit is selectable). Confirm preload observation re-fires (look for `[AppState]`-or-`[SetupCoordinator]` log line about preload starting).
3. Open Settings → AI Polish. Confirm Ollama status renders. Click "Detect" → state cycles through detect/ready/error as expected.
4. Quit the app. Confirm log line for `ollamaSetup.cleanup()` fires once.

Output: `live-uat.json` in run dir with `{tts_sentence, expected_token, observed_clipboard, exit_code, app_path, settings_uat_pass: true|false}`.

### 11.2 Other test obligations

Unit test in `Tests/EnviousWisprTests/Architecture/SetupCoordinatorTests.swift`:
- Construct SetupCoordinator with a fake `ASRManagerInterface` whose `activeBackendType` is `.parakeet`. Call `startPreloadObservation()`. Assert the preload-action closure is NOT invoked (recording closure → counter stays 0).
- Construct with fake whose `activeBackendType` is `.whisperKit` and inject a `WhisperKitSetupService` whose `setupState` returns `.ready` synchronously. Assert preload-action closure invoked exactly once.
- Call `startPreloadObservation()` twice → first task cancelled, second proceeds. Verify via task-handle inspection or invocation count.

Tier obligation per workflow-process §11: **MEDIUM** (no SPM target change after F-Exec pivot). Adds: wispr-eyes on affected Settings UI per Live UAT §11.1.

## 12. Blast radius & rollback

**Blast radius:**
- 42 call sites (38 external + 4 internal) across 4 files plus 1 new file plus AppState shape change.
- No SPM target change → no clean-build cost.
- No persisted state, no settings migration.

**Rollback:** `git revert` of the merge commit. Properties return to AppState. SetupCoordinator file deleted. Package.swift target removed. Views revert to old keypath. No data loss.

## 13. Ship criteria

- [ ] `swift build -c release` exits 0
- [ ] `scripts/swift-test.sh` exits 0 (includes the new SetupCoordinatorTests)
- [ ] `swift test` includes SetupCoordinatorTests in passing set
- [ ] AppState concrete-property count drops to 17 (verified by grep: `grep -cE "^  let [a-z]" Sources/EnviousWispr/App/AppState.swift` → expected 17)
- [ ] Zero remaining hits for `appState\.ollamaSetup\b` and `appState\.whisperKitSetup\b` in `Sources/`
- [ ] Live UAT pass per §11.1
- [ ] Codex code-diff clean (no findings, or all addressed)
- [ ] Periphery scan clean (or new findings explicitly acknowledged)
- [ ] Architecture closeout block in PR description (per architecture-rules.md)
- [ ] PR description names the run dir per workflow-process §1 step 9

## 14. Open questions

All resolved by Codex grounded review 2026-04-30:

1. ~~F-Lib vs F-Exec~~ → **F-Exec** (no new SPM target).
2. ~~Target name~~ → N/A.
3. ~~SetupCoordinator @Observable?~~ → **Yes**, concrete `let setup: SetupCoordinator` on AppState. Codebase has working multi-level @Observable paths (e.g., `appState.transcriptCoordinator.transcripts` at `TranscriptHistoryView.swift:21-29`); existential typing breaks tracking per `OnboardingV2View.swift:39-42`.

**Council:** skipped per `feedback_empirical_over_council` — Codex grep-verified the only structural fork. PR body will note `council-skip: codex-grounded-review settled the only structural fork, no user surface, no design ambiguity remaining`.

## 15. Related

- Bible: `docs/feature-requests/issue-319-2026-04-18-q2-hardening-epic.md` §17
- Decisions doc: `docs/feature-requests/issue-319-open-decisions-2026-04-18.md` D7
- Phase E (#502) — depends on this for ceiling calibration
- Architecture rules: `.claude/rules/architecture-rules.md` (anti-god-object, dependency direction)
