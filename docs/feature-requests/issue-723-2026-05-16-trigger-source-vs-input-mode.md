# Issue #723 — Separate trigger_source from input_mode in dictation.invoked telemetry — 2026-05-16

GitHub issue: `#723`. Parent / epic: #318 (Telemetry — internal). Tier: SMALL. Status: DRAFT.

## Preface — Lane + Live UAT declaration

**Lane:** Code (Swift; `Sources/EnviousWisprCore/DictationSessionConfig.swift`, `Sources/EnviousWispr/App/AppState.swift`, two pipeline emitters, three view callers, test fixtures).

**Live UAT:** N — telemetry-only field disambiguation; no behavior change to audio/paste/UI. Verification is `scripts/swift-test.sh` (existing wiring tests + new per-trigger-source distinctness tests). PostHog event shape is verified by unit test, not by a live event emission.

## Preface — User Rubric

User Rubric: N/A — Epic #318 (Telemetry) is internal-only per `workflow-process.md §1 Gate 0.5`. No customer-visible surface; this fixes a dead-field schema bug in a PostHog event used for internal funnel analysis.

## 0. TL;DR

PostHog `dictation.invoked` events currently emit `trigger_source` and `input_mode` carrying identical values (`config.inputMode.rawValue` in both slots). Codex review on PR #719 flagged this as a dead schema field that prevents distinguishing "how dictation was invoked" (hotkey vs menu vs toolbar) from "what recording mode is configured" (PTT vs toggle). Fix: introduce a `TriggerSource` enum, plumb it through `DictationSessionConfig` and each invocation entry point, keep `input_mode` as the configured recording mode. Tier SMALL. Evidence: unit tests assert distinct trigger sources reach the pipeline emitter from distinct callers.

## 1. Problem

`TranscriptionPipeline.swift:537` and `WhisperKitPipeline.swift:499` both call `TelemetryService.shared.dictationInvoked(triggerSource: config.inputMode.rawValue, inputMode: config.inputMode.rawValue, targetApp: ...)`. Both arguments come from the same field on `DictationSessionConfig`. Outcome in PostHog: every event has `trigger_source == input_mode`, making the schema's intent (distinguish invocation surface from recording mode) impossible to realize.

Codex on PR #719 said:
> The pipeline sends `triggerSource: config.inputMode.rawValue` and `inputMode: config.inputMode.rawValue`, while AppState builds `inputMode` from `settings.recordingMode`. That means toolbar/menu starts and hotkey starts cannot be separated; UI paths still call `appState.toggleRecording()` but will be reported as pushToTalk or toggle based only on the current setting.

## 2. Goals & non-goals

### 2.1 Goals
- `trigger_source` carries the invocation surface: `ptt_hotkey | toggle_hotkey | toolbar | menu_bar | onboarding | programmatic`.
- `input_mode` continues to carry the configured `RecordingMode` (`pushToTalk | toggle`).
- Every invocation entry point in production code sets the right `TriggerSource`.
- Test default has a default `triggerSource: .programmatic` so existing tests do not need touching unless they assert on the field.

### 2.2 Non-goals
- Changing the `dictation.invoked` placement (covered by #722; ship-as-is per PR #719 council).
- Changing PostHog event names or the wider event schema.
- Backfilling old events or adding migration logic — telemetry is forward-only at this scale.
- Onboarding flow integration — the issue lists `onboarding` as a planned value, but the current `OnboardingV2View` does not trigger dictation. If/when it does, that caller will pass `.onboarding` (forward-compatible).

## 3. Design

### 3.1 New enum

In `Sources/EnviousWisprCore/DictationSessionConfig.swift` (or sibling file in the same module):

```swift
public enum TriggerSource: String, Sendable, CaseIterable {
  case pttHotkey = "ptt_hotkey"
  case toggleHotkey = "toggle_hotkey"
  case toolbar = "toolbar"
  case menuBar = "menu_bar"
  case onboarding = "onboarding"
  case programmatic = "programmatic"
}
```

Snake-case raw values match PostHog convention.

### 3.2 DictationSessionConfig delta

Add field:
```swift
public let triggerSource: TriggerSource
```

Extend `init(...)` to accept it. Update the doc-comment block (lines 3-8) to mention this field.

### 3.3 AppState changes

- `makeDictationSessionConfig(triggerSource: TriggerSource)` — drops the implicit no-arg form. Callers must specify.
- `AppState.toggleRecording(source: TriggerSource = .programmatic)` — default arg keeps test fixtures green; production callers specify explicitly.

Caller routing:
| Caller | Site | Source |
|---|---|---|
| PTT hotkey (key down) | `AppState.swift:516-605` `onStartRecording` callback | `.pttHotkey` |
| Toggle hotkey (Carbon hotkey) | `AppState.swift:512-515` `onToggleRecording` callback | `.toggleHotkey` |
| Window toolbar button | `MainWindowView.swift:81` and `:313` | `.toolbar` |
| Menu bar item | `AppDelegate.swift:499-502` `@objc toggleRecording` | `.menuBar` |
| Tests | `DictationSessionConfig+TestDefault.swift` and direct `pipeline.startRecording` test sites | `.programmatic` (default) |

### 3.4 Pipeline emitter delta

`TranscriptionPipeline.swift:537` and `WhisperKitPipeline.swift:499` change:

```swift
// before
triggerSource: config.inputMode.rawValue,
inputMode: config.inputMode.rawValue,

// after
triggerSource: config.triggerSource.rawValue,
inputMode: config.inputMode.rawValue,
```

### 3.5 Test fixture default

`Tests/EnviousWisprTests/Pipeline/DictationSessionConfig+TestDefault.swift` gets `triggerSource: TriggerSource = .programmatic` as a default parameter, mirroring the `inputMode` parameter pattern already in place.

## 3a. Metric Definition + Earliest Failure Point

**Metric definition.** "trigger_source semantics" = the string emitted in the `trigger_source` property of every PostHog `dictation.invoked` event equals the invoking caller's classification, NOT the configured recording mode. Verified by `DictationInvokedTelemetryTests` (new + existing assertions) and `DictationInvokedPipelineWiringTests` (string-locks on pipeline source).

**Earliest failure point.** Build-time (Swift type system enforces the enum value at every caller). Test-time catches the wiring mistake (pipeline emitter passing the wrong field). No CI gate needed beyond `swift test`.

## 3b. Ownership justification

N/A — no new coordinator/manager. The new field lives on the existing `DictationSessionConfig` (the canonical per-recording snapshot). `AppState` retains the routing decision (which surface invoked, which session-config to build), consistent with its existing role. No god-object growth: `AppState` collaborator count unchanged (no new owned types).

## 4. Contract deltas

- **New type `TriggerSource` in `EnviousWisprCore`.** Public, `Sendable`, `String`-raw, `CaseIterable`.
- **New field `DictationSessionConfig.triggerSource: TriggerSource`.** Non-optional, set at construction.
- **Pipeline → telemetry contract.** `dictationInvoked.trigger_source` now reflects the caller's `TriggerSource`, not the configured `RecordingMode`.
- **`AppState.makeDictationSessionConfig`** signature gains a required `triggerSource:` parameter. No production callers exist outside AppState.
- **`AppState.toggleRecording`** gains an optional `source: TriggerSource = .programmatic` parameter. Production callers pass explicitly; tests rely on the default.

**Legacy data compatibility.** No persisted state. `DictationSessionConfig` is per-recording, not Codable. PostHog event schema gains semantic meaning on the existing field; older clients on the same release continue to emit `trigger_source == input_mode` until upgraded. Forward-only; no migration.

## 5. E2E state & lifecycle audit

| Path | Behavior under this change |
|---|---|
| Live / new item (primary path) | PTT press → `.pttHotkey`; menu-bar click → `.menuBar`; toolbar click → `.toolbar`; toggle hotkey → `.toggleHotkey`. Each emits a `dictation.invoked` event with a distinct `trigger_source`. |
| Saved / reloaded item | N/A. `DictationSessionConfig` is per-session, not persisted. |
| Retry or re-run (same item, same step) | A second invocation creates a fresh `DictationSessionConfig` with its own caller-specified `triggerSource`. No cross-session bleed. |
| Background / async completion arriving after state changed | The `dictation.invoked` event fires once at `state == .recording` per PR #719. The post-fix value depends solely on the immutable `config.triggerSource` captured at `makeDictationSessionConfig` time. No race with mode-changes mid-recording. |
| User manual override / edit path | N/A. |

**Upstream sources.** Every callers' entry into recording: PTT, toggle hotkey, menu, toolbar, future onboarding, test harness.

**UI side effects.** None. Telemetry is shipped to PostHog; nothing in the app reads `triggerSource` for rendering.

**Persistence.** None.

**App-kill scenario.** N/A.

**Concurrency guard.** `DictationSessionConfig` is `Sendable` and constructed at start; immutable thereafter. No race.

## 6. Downstream consumer matrix

| Contract delta | Consumer | Current behavior | Required behavior | Code change? | Verified by |
|---|---|---|---|---|---|
| New `TriggerSource` enum | None outside DictationSessionConfig and its setters | N/A | N/A | Yes (new type) | Build (compiler enforces) |
| `DictationSessionConfig.triggerSource` field | `TranscriptionPipeline.dictationInvoked` emission (line 537) | reads `config.inputMode.rawValue` for both args | reads `config.triggerSource.rawValue` for `triggerSource` arg | Yes | `DictationInvokedPipelineWiringTests` updated string-lock |
| `DictationSessionConfig.triggerSource` field | `WhisperKitPipeline.dictationInvoked` emission (line 499) | same as above | same as above | Yes | same |
| `AppState.makeDictationSessionConfig(triggerSource:)` | `AppState.swift:591` (PTT) and `:892` (toggle) | call with no args | call with `triggerSource:` explicit | Yes | grep + unit test |
| `AppState.toggleRecording(source:)` | `AppDelegate.toggleRecording` (menu), `MainWindowView` (toolbar), `HotkeyService.onToggleRecording` callback | call with no args | call with `source:` explicit | Yes | grep |
| `DictationSessionConfig+TestDefault.triggerSource` | All pipeline test sites | N/A | default `.programmatic` | Yes (test default) | tests still compile/pass |

Discovery method:
```
grep -rn "makeDictationSessionConfig\|DictationSessionConfig(" Sources/ Tests/ --include="*.swift"
grep -rn "appState.toggleRecording\|\.toggleRecording(config" Sources/ Tests/ --include="*.swift"
grep -rn "triggerSource\|trigger_source" Sources/ Tests/ --include="*.swift"
```

## 7. Failure-mode × caller table

| Failure mode | Origin | Caller | Expected UX | Expected persisted state | Expected metadata stamp | Expected retry |
|---|---|---|---|---|---|---|
| Caller misclassifies invocation surface (e.g. menu callback passes `.toolbar`) | Code bug in AppState | itself | None — telemetry only; pipeline behavior unchanged | N/A | event still emits; `trigger_source` reflects the bug | Code fix |

No new error cases. Existing `dictation.invoked` failure modes (telemetry network down, PostHog disabled) unchanged.

## 8. Caller-visible signals audit

`TriggerSource` value affects only:
- The `trigger_source` property in `dictation.invoked` PostHog events.

No presence/absence semantics — the field is non-optional, always set, always emitted.

Grep:
```
grep -rn "triggerSource\|trigger_source" Sources/ Tests/ --include="*.swift"
```
Confirms current consumers are limited to the two pipeline emit sites and the telemetry service. No UI binding, no persistence, no other observers.

## 9. Fallback source-of-truth audit

No fallback branches introduced. The new field is required at construction; the compiler refuses to build an incomplete `DictationSessionConfig`.

## 10. Code reality check

```
$ grep -n "triggerSource\|trigger_source" Sources/EnviousWisprPipeline/TranscriptionPipeline.swift Sources/EnviousWisprPipeline/WhisperKitPipeline.swift Sources/EnviousWisprServices/TelemetryService.swift
Sources/EnviousWisprPipeline/WhisperKitPipeline.swift:499:        triggerSource: config.inputMode.rawValue,
Sources/EnviousWisprPipeline/TranscriptionPipeline.swift:537:        triggerSource: config.inputMode.rawValue,
Sources/EnviousWisprServices/TelemetryService.swift:195:  public func dictationInvoked(triggerSource: String, inputMode: String, targetApp: String?) {
Sources/EnviousWisprServices/TelemetryService.swift:196:    var props: [String: Any] = ["trigger_source": triggerSource, "input_mode": inputMode]
Sources/EnviousWisprServices/TelemetryService.swift:199:      var stringProps = ["trigger_source": triggerSource, "input_mode": inputMode]
```

```
$ grep -n "makeDictationSessionConfig" Sources/EnviousWispr/App/AppState.swift
591:        try await active.handle(event: .toggleRecording(makeDictationSessionConfig()))
892:    try? await active.handle(event: .toggleRecording(makeDictationSessionConfig()))
898:  private func makeDictationSessionConfig() -> DictationSessionConfig {
```

```
$ grep -n "DictationSessionConfig(" Sources/EnviousWispr/App/AppState.swift Tests/EnviousWisprTests/Pipeline/DictationSessionConfig+TestDefault.swift
Sources/EnviousWispr/App/AppState.swift:929:    return DictationSessionConfig(
Tests/EnviousWisprTests/Pipeline/DictationSessionConfig+TestDefault.swift:25:    DictationSessionConfig(
```

```
$ grep -n "appState.toggleRecording\b" Sources/EnviousWispr/Views/ Sources/EnviousWispr/App/ -r --include="*.swift"
Sources/EnviousWispr/App/AppDelegate.swift:501:      await appState.toggleRecording()
Sources/EnviousWispr/Views/Main/MainWindowView.swift:81:              Task { await appState.toggleRecording() }
Sources/EnviousWispr/Views/Main/MainWindowView.swift:313:        await appState.toggleRecording()
```

Module-import claims: none changed. `TriggerSource` lives in `EnviousWisprCore`, already imported by `EnviousWispr` (AppState), `EnviousWisprPipeline`, and tests.

Process-init claims: none.

String-literal claims: enum raw values are snake-case (`ptt_hotkey`, `toggle_hotkey`, `menu_bar`, etc.) matching the existing PostHog `dictation.invoked` snake-case property convention.

### File list

| File | Change | LOC delta |
|---|---|---|
| `Sources/EnviousWisprCore/DictationSessionConfig.swift` | Add `TriggerSource` enum and `triggerSource` field + initializer parameter | ~20 |
| `Sources/EnviousWispr/App/AppState.swift` | `makeDictationSessionConfig` takes `triggerSource:`; `toggleRecording` takes `source:`; two call sites pass explicit values | ~10 |
| `Sources/EnviousWispr/App/AppDelegate.swift` | `@objc toggleRecording` passes `.menuBar` | ~1 |
| `Sources/EnviousWispr/Views/Main/MainWindowView.swift` | Two toolbar call sites pass `.toolbar` | ~2 |
| `Sources/EnviousWisprPipeline/TranscriptionPipeline.swift` | `triggerSource: config.triggerSource.rawValue` | ~1 |
| `Sources/EnviousWisprPipeline/WhisperKitPipeline.swift` | same as above | ~1 |
| `Tests/EnviousWisprTests/Pipeline/DictationSessionConfig+TestDefault.swift` | Add `triggerSource: TriggerSource = .programmatic` parameter | ~3 |
| `Tests/EnviousWisprTests/Pipeline/DictationInvokedPipelineWiringTests.swift` | Update string-lock to expect `config.triggerSource.rawValue` | ~4 |
| `Tests/EnviousWisprTests/Services/DictationInvokedTelemetryTests.swift` | Add per-source distinct emission assertions | ~30 |

Total: ~70 LOC, 9 files. Still SMALL.

## 11. Testing

- New unit tests in `DictationInvokedTelemetryTests`: assert each `TriggerSource` value produces a distinct `trigger_source` property; assert `input_mode` remains `config.inputMode.rawValue` independent of `triggerSource`.
- Updated `DictationInvokedPipelineWiringTests` string-lock: pipeline source must contain `triggerSource: config.triggerSource.rawValue` (was `config.inputMode.rawValue`).
- `scripts/swift-test.sh` must pass.

### 11.1 Live UAT spec

N/A — telemetry-only. Live UAT: N. Skip-note: "Overnight autonomous run; per `phase3-validation.md` Code-lane optional Live UAT, telemetry-only changes verified by unit tests."

### 11.2 Other test obligations

- `scripts/swift-test.sh` green.
- No release-build divergence expected (pure structural change).

## 12. Blast radius & rollback

- Modules touched: `EnviousWisprCore` (new enum + field), `EnviousWisprPipeline` (one-line per emitter), `EnviousWispr` (AppState routing + 3 view callers), tests.
- Modules NOT touched: audio capture, ASR, paste, custom-words, polish, persistence, settings UI rendering.
- Rollback: revert this single commit. No persisted state, no migration.

## 13. Ship criteria

- [ ] `swift build -c release` exits 0.
- [ ] `scripts/swift-test.sh` passes (existing + new tests).
- [ ] No mid-recording behavior change verified by HeartPathIntegrationTests still green.
- [ ] Codex code-diff review clean.
- [ ] Council coverage approval.
- [ ] Codex grounded review on plan: PROCEED.
- [ ] Zero em/en-dashes in new code or docs.

## 14. Open questions (resolved post-council + grounded review)

1. **Onboarding wiring deferred.** Per Codex grounded review: `OnboardingV2View.swift:1128-1135` and `HotkeyRecorderView.swift:177-186` "recording" methods are hotkey-capture UI, not dictation. No production caller from onboarding today. Enum value `.onboarding` reserved for when real onboarding dictation arrives.
2. **`toggleRecording(source:)` has NO default.** Per council (both providers strong): drop the default to force every production caller to specify. Test fixtures get `.programmatic` via `DictationSessionConfig.testDefault()` default param. Zero test impact (grep confirmed no tests call `appState.toggleRecording()` directly; only `pipeline.startRecording(config: ...)` paths).
3. **`.programmatic` semantics clarified** (per OpenAI council): doc-comment on the enum states this is the reserve value for internal / test / future automation, NOT "unknown."
4. **Apple Shortcuts / AppleScript / URL schemes** (per Gemini council): none exist today. If/when they ship, they get their own enum value (e.g., `.shortcuts`). Documented in §2.2 non-goals.
5. **PostHog dashboard impact** (per Gemini council): existing saved insights/funnels keyed on `trigger_source` were de-facto grouping by `input_mode`. After this PR lands, those will start showing the correct semantic split. Flagged for founder dashboard review in PR body, not a code change.
6. **AppState line ceiling** (per Codex grounded review): AppState.swift was at 1024/1050; post-fix around 1028. Safe.

## 15. Related

- Source: Codex review on PR #719 (`dictation.invoked` event introduction).
- Sibling open issue: #722 (placement decision — intent vs successful-recording). Independent fix; #722 may close as works-as-designed (PR #719 council already approved current placement).