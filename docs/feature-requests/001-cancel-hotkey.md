# Feature: Cancel Hotkey During Recording

**ID:** 001
**Category:** Hotkeys & Input
**Priority:** High
**Inspired by:** Handy — dynamically registers a cancel hotkey only while recording
**Status:** Ready for Implementation

## Problem

There is no way to cancel a recording mid-session. Once the user starts recording, they must wait
for the full pipeline (transcribe -> polish -> paste) to complete, even if they made a mistake or
changed their mind. The only workaround is force-quitting the app.

## Proposed Solution

Add a configurable cancel hotkey (default: Escape, no modifiers) that is dynamically registered
when recording starts and unregistered the moment recording stops for any reason. Pressing cancel:

1. Immediately stops audio capture
2. Discards captured samples
3. Resets pipeline state to `.idle`
4. Hides the recording overlay
5. Does not paste or copy anything

## Files to Modify

| File | Change Type |
|------|-------------|
| `Sources/EnviousWispr/Services/HotkeyService.swift` | Add cancel monitor lifecycle, cancel callback, configurable key+modifiers, `cancelHotkeyDescription` |
| `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` | Add `cancelRecording()` method |
| `Sources/EnviousWispr/App/AppState.swift` | Persist cancel settings, wire `pipeline.onStateChange` to register/unregister cancel monitor, add `cancelRecording()` delegation |
| `Sources/EnviousWispr/Views/Settings/SettingsView.swift` | Add "Cancel Hotkey" section to `ShortcutsSettingsView` |

No new source files are needed.

## New Types / Properties

### HotkeyService (new stored properties)

```swift
// Dynamically-registered cancel monitors
private var globalCancelMonitor: Any?
private var localCancelMonitor: Any?

/// Key code for the cancel hotkey (default: Escape = 53).
var cancelKeyCode: UInt16 = 53

/// Required modifiers for cancel hotkey (default: none — bare Escape).
var cancelModifiers: NSEvent.ModifierFlags = []

/// Fired when the cancel hotkey is pressed during an active recording.
var onCancelRecording: (@MainActor () async -> Void)?
```

### TranscriptionPipeline (new method)

```swift
func cancelRecording()
```

### AppState (new persisted settings)

```swift
var cancelKeyCode: UInt16    // persisted under "cancelKeyCode" (Int)
var cancelModifiers: NSEvent.ModifierFlags  // persisted under "cancelModifiersRaw" (UInt)
```

## Implementation Plan

### Step 1 — Add `cancelRecording()` to TranscriptionPipeline

File: `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift`

Insert after the existing `reset()` method:

```swift
/// Cancel an active recording immediately without transcribing.
/// Guards on `.recording` state — safe to call from any other state.
func cancelRecording() {
    guard state == .recording else { return }

    // Stop VAD monitoring task immediately
    vadMonitorTask?.cancel()
    vadMonitorTask = nil
    silenceDetector = nil

    // Stop audio engine and explicitly discard all captured samples
    _ = audioCapture.stopCapture()

    // Clear target app reference — nothing will be pasted
    targetApp = nil

    // Transition to idle without saving any transcript
    state = .idle
}
```

Rationale: mirrors `reset()` structure but does NOT set `currentTranscript = nil` (preserving
the last successful transcript in the detail panel) and does NOT touch `autoPasteToActiveApp`
(that cleanup happens in `AppState.cancelRecording()`).

### Step 2 — Add cancel monitor lifecycle to HotkeyService

File: `Sources/EnviousWispr/Services/HotkeyService.swift`

**2a. Add new stored properties** after the existing `localFlagsMonitor` declaration:

```swift
// Cancel hotkey — dynamically registered only during recording
private var globalCancelMonitor: Any?
private var localCancelMonitor: Any?

/// Key code for the cancel hotkey. Default: Escape (53).
var cancelKeyCode: UInt16 = 53

/// Required modifiers for cancel hotkey. Default: none (bare Escape).
var cancelModifiers: NSEvent.ModifierFlags = []

/// Fired when the cancel hotkey is pressed while recording is active.
var onCancelRecording: (@MainActor () async -> Void)?
```

**2b. Update `stop()` to clean up cancel monitors** — add at the top of existing `stop()`:

```swift
func stop() {
    unregisterCancelHotkey()  // <-- ADD THIS LINE FIRST
    // ... rest unchanged
}
```

**2c. Add two new public methods** after `stop()`:

```swift
/// Register global + local cancel monitors. Call on `.recording` entry.
func registerCancelHotkey() {
    guard globalCancelMonitor == nil else { return }

    globalCancelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let code = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        Task { @MainActor in self?.handleCancelKeyDown(code: code, flags: flags) }
    }

    localCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let code = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        Task { @MainActor in self?.handleCancelKeyDown(code: code, flags: flags) }
        return event  // Pass event through — do not consume Escape globally
    }
}

/// Remove cancel monitors. Call whenever recording ends for any reason.
func unregisterCancelHotkey() {
    if let monitor = globalCancelMonitor {
        NSEvent.removeMonitor(monitor)
        globalCancelMonitor = nil
    }
    if let monitor = localCancelMonitor {
        NSEvent.removeMonitor(monitor)
        localCancelMonitor = nil
    }
}
```

**2d. Add the private handler**:

```swift
private func handleCancelKeyDown(code: UInt16, flags: NSEvent.ModifierFlags) {
    guard code == cancelKeyCode else { return }
    let required = cancelModifiers.intersection(.deviceIndependentFlagsMask)
    guard required.isEmpty || flags.contains(required) else { return }
    Task { await onCancelRecording?() }
}
```

**2e. Add `cancelHotkeyDescription`** computed property:

```swift
var cancelHotkeyDescription: String {
    let mods = modifierName(cancelModifiers)
    let key = keyCodeName(cancelKeyCode)
    return mods.isEmpty ? key : "\(mods)\(key)"
}
```

### Step 3 — Wire cancel hotkey in AppState

File: `Sources/EnviousWispr/App/AppState.swift`

**3a. Add persisted settings** with UserDefaults `didSet`:

```swift
var cancelKeyCode: UInt16 {
    didSet {
        UserDefaults.standard.set(Int(cancelKeyCode), forKey: "cancelKeyCode")
        hotkeyService.cancelKeyCode = cancelKeyCode
    }
}

var cancelModifiers: NSEvent.ModifierFlags {
    didSet {
        UserDefaults.standard.set(cancelModifiers.rawValue, forKey: "cancelModifiersRaw")
        hotkeyService.cancelModifiers = cancelModifiers
    }
}
```

**3b. Load from UserDefaults in `init()`**:

```swift
let savedCancelKeyCode = defaults.object(forKey: "cancelKeyCode") as? Int
cancelKeyCode = UInt16(savedCancelKeyCode ?? 53)  // Default: Escape

let savedCancelModRaw = defaults.object(forKey: "cancelModifiersRaw") as? UInt
cancelModifiers = NSEvent.ModifierFlags(rawValue: savedCancelModRaw ?? 0)
```

**3c. Wire cancel callback in `init()`**:

```swift
hotkeyService.onCancelRecording = { [weak self] in
    await self?.cancelRecording()
}
```

**3d. Add `cancelRecording()` method**:

```swift
func cancelRecording() async {
    guard pipelineState == .recording else { return }
    pipeline.autoPasteToActiveApp = false
    pipeline.cancelRecording()
}
```

**3e. Update `pipeline.onStateChange` closure** — register/unregister cancel hotkey:

```swift
case .recording:
    self.recordingOverlay.show(...)
    self.hotkeyService.registerCancelHotkey()   // <-- ADD
case .transcribing, .error, .idle:
    self.recordingOverlay.hide()
    self.hotkeyService.unregisterCancelHotkey() // <-- ADD
case .complete, .polishing:
    self.hotkeyService.unregisterCancelHotkey() // <-- ADD
```

### Step 4 — Add Cancel Hotkey section to ShortcutsSettingsView

File: `Sources/EnviousWispr/Views/Settings/SettingsView.swift`

```swift
Section("Cancel Hotkey") {
    HStack {
        Text("Cancel recording:")
        Spacer()
        Text(appState.hotkeyService.cancelHotkeyDescription)
            .font(.system(.body, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
    }
    Text("Press this key while recording to immediately discard audio and return to idle.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

## Data Flow

```
User presses Escape during .recording state
  -> globalCancelMonitor fires
  -> handleCancelKeyDown matches cancelKeyCode
  -> AppState.cancelRecording()
      -> pipeline.autoPasteToActiveApp = false
      -> TranscriptionPipeline.cancelRecording()
          -> vadMonitorTask.cancel()
          -> audioCapture.stopCapture() — samples discarded
          -> targetApp = nil
          -> state = .idle
  -> pipeline.onStateChange(.idle)
      -> recordingOverlay.hide()
      -> hotkeyService.unregisterCancelHotkey()
  -> Result: no Transcript, no paste, no clipboard write, overlay gone
```

## Testing Strategy

1. **Toggle mode cancel**: Ctrl+Space to start -> Escape -> overlay disappears, no transcript saved
2. **Push-to-talk cancel**: Hold Option -> Escape -> overlay disappears, release Option is no-op
3. **No interference when idle**: Escape works normally in other apps when not recording
4. **Rapid cancel-restart**: Cancel then immediately start new recording — clean state
5. **VAD auto-stop race**: Cancel is no-op when state is `.transcribing`
6. **Cancel before speaking**: No "No audio captured" error — cancel exits cleanly

## Risks & Considerations

- **Escape passthrough**: Local monitor returns `event` (not `nil`) — Escape not consumed globally
- **PTT interaction**: Cancel fires on key-down while modifier held; modifier release no-ops safely
- **Swift 6 concurrency**: Extract Sendable values from NSEvent before `Task { @MainActor in }`
