# Feature: Model Unload Timeout

**ID:** 011
**Category:** Audio & Models
**Priority:** High
**Inspired by:** Handy — configurable idle VRAM/RAM reclamation (Never / Immediately / 2-15min / 1hr)
**Status:** Ready for Implementation

## Problem

ASR models (Parakeet v3, WhisperKit) remain loaded in memory indefinitely after use. On machines with limited RAM, this wastes resources when the user hasn't dictated in a while. Parakeet v3 can consume several hundred MB of RAM.

## Proposed Solution

Add a configurable model unload timeout:
- Never (current behavior)
- Immediately after transcription
- After 2 / 5 / 10 / 15 / 60 minutes of idle

An idle watcher runs on a background timer, checking if the last transcription was longer ago than the timeout. If so, it calls `asrManager.unloadModel()` and also `silenceDetector.unload()` to free VAD memory.

Next recording triggers a re-load (with a brief loading indicator).

## Files to Modify

| File | Change |
| ---- | ------ |
| `Sources/EnviousWispr/Models/AppSettings.swift` | Add `ModelUnloadPolicy` enum |
| `Sources/EnviousWispr/ASR/ASRManager.swift` | Add idle timer, `lastTranscriptionTime`, `unloadModel()`, `noteTranscriptionComplete()`, `cancelIdleTimer()`, `scheduleIdleTimer(policy:)` |
| `Sources/EnviousWispr/App/AppState.swift` | Add `modelUnloadPolicy` persisted property wired to `ASRManager` |
| `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` | Call `noteTranscriptionComplete()` after transcript saved; call `cancelIdleTimer()` at top of `startRecording()` |
| `Sources/EnviousWispr/App/AppDelegate.swift` | Override status text to show "Loading model..." when model is unloaded and pipeline state is `.transcribing` |
| `Sources/EnviousWispr/Views/Settings/SettingsView.swift` | Add `ModelUnloadPolicy` Picker inside `GeneralSettingsView` under a new "Memory" section |

## New Types / Properties

### `ModelUnloadPolicy` (add to `AppSettings.swift`)

```swift
/// Policy controlling when idle ASR models are unloaded from memory.
enum ModelUnloadPolicy: String, Codable, CaseIterable, Sendable {
    case never
    case immediately
    case twoMinutes
    case fiveMinutes
    case tenMinutes
    case fifteenMinutes
    case sixtyMinutes

    var displayName: String {
        switch self {
        case .never:          return "Never"
        case .immediately:    return "Immediately"
        case .twoMinutes:     return "After 2 minutes"
        case .fiveMinutes:    return "After 5 minutes"
        case .tenMinutes:     return "After 10 minutes"
        case .fifteenMinutes: return "After 15 minutes"
        case .sixtyMinutes:   return "After 1 hour"
        }
    }

    /// Returns nil for .never and .immediately (timer-less policies).
    var interval: TimeInterval? {
        switch self {
        case .never, .immediately: return nil
        case .twoMinutes:          return 120
        case .fiveMinutes:         return 300
        case .tenMinutes:          return 600
        case .fifteenMinutes:      return 900
        case .sixtyMinutes:        return 3600
        }
    }
}
```

### Additions to `ASRManager`

```swift
// New stored properties
private var idleTimer: Timer?
private var lastTranscriptionTime: Date?
private(set) var isUnloading = false   // for UI: "Unloading..." text if needed

/// Unload the active backend, freeing model RAM.
func unloadModel() async {
    guard isModelLoaded else { return }
    isUnloading = true
    await activeBackend.unload()
    isModelLoaded = false
    isUnloading = false
}

/// Called by pipeline after a transcript is saved.
/// Records the timestamp and schedules/resets the idle timer.
func noteTranscriptionComplete(policy: ModelUnloadPolicy) {
    lastTranscriptionTime = Date()
    if policy == .immediately {
        Task { await unloadModel() }
        return
    }
    scheduleIdleTimer(policy: policy)
}

/// Cancel any pending idle timer (called when recording starts).
func cancelIdleTimer() {
    idleTimer?.invalidate()
    idleTimer = nil
}

/// Schedule (or reset) the idle timer for timed policies.
private func scheduleIdleTimer(policy: ModelUnloadPolicy) {
    guard let interval = policy.interval else { return }
    cancelIdleTimer()
    // Timer fires on the main run loop — safe for @MainActor ASRManager.
    idleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
            Task { await self?.unloadModel() }
        }
    }
}
```

### `AppState` additions

```swift
var modelUnloadPolicy: ModelUnloadPolicy {
    didSet {
        UserDefaults.standard.set(modelUnloadPolicy.rawValue, forKey: "modelUnloadPolicy")
        pipeline.modelUnloadPolicy = modelUnloadPolicy
        // If policy changed to Never, cancel any pending timer.
        if modelUnloadPolicy == .never {
            asrManager.cancelIdleTimer()
        }
    }
}
```

Initialise in `AppState.init()`:

```swift
modelUnloadPolicy = ModelUnloadPolicy(
    rawValue: defaults.string(forKey: "modelUnloadPolicy") ?? ""
) ?? .never
```

## Implementation Plan

### Step 1 — Add `ModelUnloadPolicy` to `AppSettings.swift`

Append the enum after the existing `PipelineState` enum. No other file changes are needed for the type itself.

### Step 2 — Augment `ASRManager`

Add `idleTimer`, `lastTranscriptionTime`, `isUnloading` properties. Add `unloadModel()`, `noteTranscriptionComplete(policy:)`, `cancelIdleTimer()`, `scheduleIdleTimer(policy:)` methods as shown in the snippet above. The existing `loadModel()` already exists and handles re-loading; no changes needed there.

### Step 3 — Wire `TranscriptionPipeline`

Add a new stored property to `TranscriptionPipeline`:

```swift
var modelUnloadPolicy: ModelUnloadPolicy = .never
```

In `startRecording()`, add at the very top (before the model load check):

```swift
// Cancel idle timer so model stays loaded during recording.
asrManager.cancelIdleTimer()
```

In `stopAndTranscribe()`, after `try transcriptStore.save(transcript)` and before the auto-copy/paste block:

```swift
// Notify ASR manager that transcription is done; schedules unload timer if configured.
asrManager.noteTranscriptionComplete(policy: modelUnloadPolicy)
```

Wire it in `AppState.init()` after the pipeline is created:

```swift
pipeline.modelUnloadPolicy = modelUnloadPolicy
```

### Step 4 — Update `AppDelegate` status text

In `populateMenu(_:)`, change the status line to account for the model being unloaded:

```swift
let modelState: String
if !appState.asrManager.isModelLoaded && state != .recording {
    modelState = "Model unloaded"
} else {
    modelState = appState.selectedBackend == .parakeet ? "Parakeet v3" : "WhisperKit"
}
let statusMenuItem = NSMenuItem(
    title: "\(state.statusText) — \(modelState)",
    action: nil,
    keyEquivalent: ""
)
```

The pipeline's existing `state = .transcribing` during model reload (in `startRecording()`) causes the menu bar to show "Transcribing... — Loading model..." which is acceptable and already works with no additional change.

### Step 5 — Settings UI

Inside `GeneralSettingsView`, add a new `Section("Memory")` after the existing `Section("Performance")`:

```swift
Section("Memory") {
    Picker("Unload model after", selection: $state.modelUnloadPolicy) {
        ForEach(ModelUnloadPolicy.allCases, id: \.self) { policy in
            Text(policy.displayName).tag(policy)
        }
    }

    if appState.modelUnloadPolicy != .never {
        Text("The ASR model will be unloaded from RAM after the selected idle period. The next recording will reload it (~2–5 s).")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    if appState.modelUnloadPolicy == .immediately {
        Text("Model is freed after every transcription. Expect a reload delay on each recording.")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}
```

### Step 6 — UserDefaults persistence

The `AppState.init()` already loads all values from `UserDefaults.standard`. Add the new key `"modelUnloadPolicy"` to the load block using the same pattern as `vadDualBuffer`.

## Testing Strategy

1. **Unit test `ModelUnloadPolicy`**: Verify `interval` values and `displayName` strings. All cases should have non-nil displayName. `.never` and `.immediately` must return nil interval.

2. **Manual — Immediately policy**: Set policy to "Immediately". Record and stop. Wait 1 second. Verify `asrManager.isModelLoaded == false`. Record again. Confirm the "Transcribing..." loading state appears briefly before recording begins.

3. **Manual — Timed policy (2 minutes)**: Set policy to "After 2 minutes". Record and stop. Wait 2+ minutes idle. Open menu bar — confirm status shows "Model unloaded". Record again — confirm brief reload delay.

4. **Timer cancellation on new recording**: Set policy to "After 5 minutes". Record and stop. Start a new recording within 2 minutes. Verify the timer did NOT fire (model still loaded when second recording starts immediately).

5. **Never policy**: Record 5 times. Model should remain loaded throughout.

6. **Backend switch clears timer**: Switch from Parakeet to WhisperKit mid-idle. Confirm the timer (if active) is cancelled or restarted correctly since `switchBackend` calls `unload()` directly.

## Risks & Considerations

- Re-loading adds latency to the next recording (~2-5s for Parakeet v3)
- Timer must be cancelled/reset when a new recording starts
- Should show a brief "Loading model..." state in the overlay/menu bar
- UserDefaults persistence for the timeout setting
- `ASRManager` is `@MainActor` so `Timer` scheduled on `RunLoop.main` is inherently safe; `MainActor.assumeIsolated` in the timer callback is valid since the timer fires on the main thread
- The `SilenceDetector` (VAD) is a separate actor — its memory is not covered by this feature. Consider adding a `silenceDetector?.unload()` call inside `unloadModel()` or in the pipeline layer if VAD RAM becomes a concern
