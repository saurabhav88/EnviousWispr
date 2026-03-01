# Feature: Bluetooth Audio Resilience — AirPods Recording Without Breaking Playback

**ID:** 021
**Category:** Audio & Models
**Priority:** High
**Inspired by:** AirPods users reporting that starting a recording while audio is playing kills the recording
**Status:** Ready for Implementation

## Problem

When recording starts with AirPods connected, the Bluetooth stack switches from the A2DP (stereo audio) codec to SCO (voice) codec. This switch fires an `AVAudioEngineConfigurationChange` notification. Our code treats this notification as a device disconnect and calls `emergencyTeardown()`, which kills the recording session entirely.

Consequences for the user:

- Recording silently fails when AirPods are connected and other audio is playing
- The audio engine enters a corrupted state that persists until app restart
- Noise suppression toggle breaks the engine in a separate but related way
- The 0.5–2 second Bluetooth codec negotiation lag is fully visible to the user as dead silence

Root cause: a codec switch is not the same as a device disconnect. `kAudioDevicePropertyDeviceIsAlive` returns `true` during an A2DP→SCO switch. The engine needs graceful recovery, not teardown.

## Competitive Context

No macOS dictation app (Handy, Superwhisper, Wispr Flow, MacWhisper) solves simultaneous A2DP + mic recording. All recommend using the built-in microphone instead. This is a Bluetooth Classic protocol limitation — A2DP and SCO cannot coexist on the same device. Solving this problem (even partially, via smart device selection and pre-warming) is a meaningful differentiator for AirPods users, who are a large fraction of Mac users.

Future: Apple is shipping a `bluetoothHighQualityRecording` API in macOS 26 Tahoe that may address the codec coexistence problem at the OS level. Adopt on day one.

## Proposed Solution

Five targeted changes that work together to make Bluetooth audio resilient:

1. Replace panic teardown with graceful recovery on codec switch
2. Two-phase recording start that separates engine start from capture start
3. Correct noise suppression lifecycle (default off, full rebuild on toggle)
4. Pre-warm audio input on PTT key-down to hide Bluetooth lag
5. Smart input device selection that prefers built-in mic when Bluetooth output is active

## Files to Modify

- `Sources/EnviousWispr/Audio/AudioCaptureManager.swift` — changes 1, 2, 3, 4, 5
- `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` — changes 2, 4
- `Sources/EnviousWispr/Services/HotkeyService.swift` — change 4
- `Sources/EnviousWispr/Audio/AudioDeviceManager.swift` — change 5
- `Sources/EnviousWispr/App/SettingsManager.swift` — changes 3, 5
- `Sources/EnviousWispr/Views/Settings/AudioSettingsView.swift` — change 5

## Implementation Plan

### Change 1: Replace Panic Teardown with Graceful Recovery

`AVAudioEngineConfigurationChange` currently routes to `emergencyTeardown()`. Instead, check whether the device is actually dead before deciding what to do.

**Files:** `AudioCaptureManager.swift`

**Logic:**

```swift
// AudioCaptureManager.swift

// BEFORE — fires on both codec switch and true disconnect:
NotificationCenter.default.addObserver(
    forName: .AVAudioEngineConfigurationChange,
    object: engine,
    queue: .main
) { [weak self] _ in
    self?.emergencyTeardown()  // WRONG — kills recording on codec switch
}

// AFTER — distinguish codec switch from true disconnect:
NotificationCenter.default.addObserver(
    forName: .AVAudioEngineConfigurationChange,
    object: engine,
    queue: nil
) { [weak self] _ in
    Task { await self?.handleEngineConfigurationChange() }
}

private func handleEngineConfigurationChange() async {
    guard let deviceID = currentInputDeviceID else {
        await emergencyTeardown()
        return
    }

    // Check kAudioDevicePropertyDeviceIsAlive via CoreAudio
    var isAlive: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &isAlive)

    if isAlive == 0 {
        // True disconnect — tear down as before
        await emergencyTeardown()
        return
    }

    // Codec switch — attempt graceful recovery
    await recoverFromCodecSwitch()
}

private func recoverFromCodecSwitch() async {
    // 1. Remove the existing tap so the engine can be stopped cleanly
    removeTap()

    // 2. Stop the engine (it may already be stopped after the config change)
    engine.stop()

    // 3. Poll for format stabilization — the SCO format settles within 200ms–1s
    let stabilized = await waitForFormatStabilization(
        deviceID: currentInputDeviceID,
        maxWait: 1.5,
        pollInterval: 0.2
    )
    guard stabilized else {
        // Format never settled — treat as unrecoverable
        await emergencyTeardown()
        return
    }

    // 4. Reinstall tap with the new format and restart the engine
    do {
        try installTap()
        try engine.start()
        // capturedSamples is preserved — recording continues transparently
    } catch {
        await emergencyTeardown()
    }
}

/// Poll the input node's output format until it stabilizes (two consecutive equal formats).
private func waitForFormatStabilization(
    deviceID: AudioDeviceID?,
    maxWait: TimeInterval,
    pollInterval: TimeInterval
) async -> Bool {
    var lastFormat: AVAudioFormat? = nil
    let deadline = Date().addingTimeInterval(maxWait)
    while Date() < deadline {
        let format = engine.inputNode.outputFormat(forBus: 0)
        if format == lastFormat { return true }
        lastFormat = format
        try? await Task.sleep(for: .seconds(pollInterval))
    }
    return false
}
```

**Key invariant:** `capturedSamples` is preserved across recovery. The in-flight recording buffer is not cleared. The user loses at most one poll interval of audio (200ms), which is inaudible in practice.

### Change 2: Two-Phase Recording Start

The codec switch fires when the engine first opens the audio input. By separating engine start (phase 1) from tap installation and capture (phase 2), we ensure the tap is installed only after the format has settled.

**Files:** `AudioCaptureManager.swift`, `TranscriptionPipeline.swift`

**Logic:**

```swift
// AudioCaptureManager.swift

/// Phase 1: Start the engine to trigger any codec switch.
/// Returns after the engine is running; does NOT install a tap or begin capture.
func startEnginePhase() async throws {
    guard !engine.isRunning else { return }
    try engine.start()
    // Allow the codec switch notification time to fire and settle
    try await Task.sleep(for: .seconds(0.25))
}

/// Phase 2: Install the tap and begin capture.
/// Call only after startEnginePhase() and waitForFormatStabilization().
func beginCapturePhase() throws {
    try installTap()
    isCapturing = true
}

// TranscriptionPipeline.swift — updated startRecording():
func startRecording() async throws {
    // Phase 1: start engine, trigger codec switch
    try await audioCaptureManager.startEnginePhase()

    // Wait for format to stabilize (Bluetooth) or pass immediately (built-in mic)
    let stabilized = await audioCaptureManager.waitForFormatStabilization(
        deviceID: audioCaptureManager.currentInputDeviceID,
        maxWait: 1.5,
        pollInterval: 0.2
    )

    // If buffers are empty after timeout (engine started but no audio flowing),
    // rebuild the engine once and retry
    if !stabilized {
        try await audioCaptureManager.rebuildEngine()
        try await audioCaptureManager.startEnginePhase()
    }

    // Phase 2: install tap and start capture
    try audioCaptureManager.beginCapturePhase()
}
```

### Change 3: Noise Suppression Lifecycle

Runtime toggling of voice processing on a running `AVAudioEngine` is unreliable and causes the engine to silently enter a bad state. The correct approach is to apply the setting at engine build time and require a full rebuild when it changes.

**Files:** `AudioCaptureManager.swift`, `SettingsManager.swift`

**Default change:** Noise suppression defaults to `false`. Parakeet and Whisper handle background noise well at the model level. The SCO codec's built-in noise cancellation makes enabling Voice Processing redundant for Bluetooth mics.

```swift
// SettingsManager.swift
@AppStorage("noiseSuppression") var noiseSuppression: Bool = false  // was: true

// AudioCaptureManager.swift

/// Build (or rebuild) the AVAudioEngine with the correct voice-processing configuration.
/// Must be called before startEnginePhase(). Any existing engine is torn down first.
func buildEngine(noiseSuppression: Bool) throws {
    if engine.isRunning { engine.stop() }
    removeTap()
    engine = AVAudioEngine()

    if noiseSuppression {
        // Enable voice processing (built-in AEC + NS)
        try engine.inputNode.setVoiceProcessingEnabled(true)

        // Disable ducking — we do NOT want the engine lowering other apps' volume
        let duckingConfig = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false,
            duckingLevel: .min
        )
        try engine.inputNode.setVoiceProcessingOtherAudioDuckingConfiguration(duckingConfig)
    }
    // (No else branch needed — voice processing is off by default on a new engine)
}

// When the user toggles noise suppression in Settings:
// AppState.swift or SettingsManager.swift observer:
func onNoiseSuppressionChanged(_ newValue: Bool) async {
    // Full rebuild — no runtime toggling
    if pipeline.isRecording { await pipeline.cancelRecording() }
    try? await audioCaptureManager.buildEngine(noiseSuppression: newValue)
}
```

### Change 4: Pre-warm Audio Input on PTT Key-Down

The Bluetooth codec negotiation takes 0.5–2 seconds. By opening the audio input on key-down (before the user expects recording to start), we hide this latency behind the natural time between pressing the hotkey and starting to speak.

**Files:** `HotkeyService.swift`, `AudioCaptureManager.swift`, `TranscriptionPipeline.swift`

```swift
// HotkeyService.swift — add key-down handler alongside existing key-up handler

// Existing: key-up fires stopRecording / toggleRecording
// New: key-down fires preWarm

// The Carbon event handler already distinguishes kEventHotKeyPressed (down)
// and kEventHotKeyReleased (up). Add pre-warm to the pressed case:

case kEventHotKeyPressed:
    Task { @MainActor in
        await pipeline.preWarmAudioInput()
    }

case kEventHotKeyReleased:
    // existing start-recording logic
```

```swift
// AudioCaptureManager.swift

/// Open the audio input to trigger any Bluetooth codec switch.
/// Safe to call multiple times — no-op if the engine is already running.
/// Does NOT install a tap or begin capture.
func preWarm() async {
    guard !engine.isRunning else { return }
    try? engine.start()
    // Allow the codec switch and format stabilization to complete
    let _ = await waitForFormatStabilization(
        deviceID: currentInputDeviceID,
        maxWait: 1.5,
        pollInterval: 0.2
    )
}

// TranscriptionPipeline.swift

func preWarmAudioInput() async {
    guard !isRecording, !isPreviewing else { return }
    await audioCaptureManager.preWarm()
    isPreWarmed = true
}

// In startRecording(), skip phase 1 if already pre-warmed:
func startRecording() async throws {
    if !isPreWarmed {
        try await audioCaptureManager.startEnginePhase()
        // ... stabilization wait ...
    }
    isPreWarmed = false
    try audioCaptureManager.beginCapturePhase()
}
```

**PTT flow with pre-warm:**

```
T=0ms   Key-down → preWarmAudioInput() → engine starts, codec switch fires
T=500ms Bluetooth codec negotiation completes (hidden from user)
T=800ms User finishes pressing key and starts speaking
T=800ms Key-up → startRecording() → beginCapturePhase() → tap installed immediately
T=800ms VAD begins; first speech frames captured
```

Compare to before: codec switch fired at T=800ms, adding 500ms of dead silence at the start of every Bluetooth recording.

### Change 5: Smart Input Device Selection

When the user's output device is Bluetooth, route microphone input to the built-in mic automatically. A2DP and SCO cannot coexist — using SCO for input degrades both playback (switches from A2DP stereo to SCO mono) and microphone quality. The built-in mic provides higher quality and avoids the codec conflict entirely.

**Files:** `AudioDeviceManager.swift`, `AudioCaptureManager.swift`, `SettingsManager.swift`, `AudioSettingsView.swift`

```swift
// AudioDeviceManager.swift

/// Returns true if the given device uses Bluetooth transport.
func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
    var transport: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport)
    return transport == kAudioDeviceTransportTypeBluetooth
        || transport == kAudioDeviceTransportTypeBluetoothLE
}

/// Returns the AudioDeviceID of the built-in microphone, if one exists.
func builtInMicrophoneDeviceID() -> AudioDeviceID? {
    // Enumerate all input devices; return the first with transport type Built-In
    return allInputDevices().first { deviceID in
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport)
        return transport == kAudioDeviceTransportTypeBuiltIn
    }
}

/// Recommended input device given current output device and media-playing state.
/// Returns nil to mean "use whatever is currently selected."
func recommendedInputDevice(outputDeviceID: AudioDeviceID, mediaIsPlaying: Bool) -> AudioDeviceID? {
    guard isBluetoothDevice(outputDeviceID), mediaIsPlaying else { return nil }
    return builtInMicrophoneDeviceID()
}
```

```swift
// SettingsManager.swift
/// User override — nil means "auto" (follow smart selection logic).
@AppStorage("preferredInputDeviceID") var preferredInputDeviceIDOverride: String? = nil
```

```swift
// AudioCaptureManager.swift — in startEnginePhase() or buildEngine():
let outputDeviceID = audioDeviceManager.defaultOutputDeviceID()
let mediaIsPlaying = /* check via AVAudioSession or system audio activity */

let recommended = audioDeviceManager.recommendedInputDevice(
    outputDeviceID: outputDeviceID,
    mediaIsPlaying: mediaIsPlaying
)

if let override = settingsManager.preferredInputDeviceIDOverride {
    // User has explicitly chosen a device — respect it
    try setInputDevice(AudioDeviceID(override) ?? recommended ?? defaultInputDeviceID())
} else if let recommended {
    // Auto-selection: use built-in mic
    try setInputDevice(recommended)
    notifyUserOfAutoSelection()  // show the UX note below
}
```

```swift
// AudioSettingsView.swift — add explanation note and override picker

Section("Microphone") {
    Picker("Input Device", selection: $settingsManager.preferredInputDeviceIDOverride) {
        Text("Auto").tag(Optional<String>.none)
        ForEach(audioDeviceManager.allInputDevices(), id: \.self) { deviceID in
            Text(audioDeviceManager.deviceName(deviceID)).tag(Optional(String(deviceID)))
        }
    }

    // Show contextual note when auto-selection is active and Bluetooth output is detected
    if settingsManager.preferredInputDeviceIDOverride == nil,
       audioDeviceManager.isBluetoothDevice(audioDeviceManager.defaultOutputDeviceID()) {
        Text(
            "Built-in microphone selected automatically. " +
            "Bluetooth headphones cannot record and play audio simultaneously " +
            "— using the built-in mic avoids degrading your audio playback."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
```

## Testing Strategy

1. **Codec switch recovery (Change 1):** Connect AirPods. Play audio from Safari or Music. Start recording. Verify the recording completes successfully. Verify `capturedSamples` contains audio (not empty). Verify transcription is produced.

2. **True disconnect teardown (Change 1):** Start recording with AirPods. Physically disconnect AirPods (remove from ears / toggle Bluetooth off). Verify `emergencyTeardown()` is called and the UI returns to idle gracefully.

3. **Two-phase start latency (Change 2):** Start recording with AirPods and measure time from `startRecording()` call to first non-zero sample in `capturedSamples`. Verify no audio is lost from the first 500ms of speech.

4. **Noise suppression default (Change 3):** Fresh install. Verify `noiseSuppression == false` in UserDefaults. Verify `engine.inputNode.isVoiceProcessingEnabled == false`.

5. **Noise suppression rebuild (Change 3):** Toggle noise suppression ON in settings while idle. Verify `buildEngine(noiseSuppression: true)` is called. Verify `isVoiceProcessingEnabled == true` after rebuild. Toggle OFF. Verify engine is rebuilt again with voice processing disabled.

6. **Pre-warm timing (Change 4):** Hold PTT key down. Verify engine starts within 50ms. Release key and verify recording begins without the codec switch delay. Measure time-to-first-captured-sample — should be under 100ms from key-up.

7. **Smart device selection — auto (Change 5):** Connect Bluetooth headphones. Play audio. Trigger recording. Verify the selected input device is the built-in microphone (not the Bluetooth device). Verify the UX note appears in AudioSettingsView.

8. **Smart device selection — user override (Change 5):** Set preferred input device to "AirPods Microphone" explicitly. Connect AirPods and play audio. Start recording. Verify the Bluetooth mic is used (not auto-switched to built-in).

9. **No Bluetooth device — no auto-switch (Change 5):** Connect a wired USB microphone. Verify smart device selection does not interfere. Verify the USB mic is used for recording.

10. **Ducking disabled (Change 3):** Enable noise suppression. Start recording with Bluetooth headphones while audio is playing. Verify the background audio volume does not decrease during recording (ducking is suppressed).

## Risks & Edge Cases

- **Multiple codec switch notifications:** The `AVAudioEngineConfigurationChange` notification may fire more than once during a single Bluetooth negotiation. The recovery path must be idempotent — guard against re-entrant calls with an `isRecovering` flag.

- **Engine rebuild failure:** If `installTap()` or `engine.start()` fails during recovery, fall through to `emergencyTeardown()`. Never leave the engine in a running-but-tapless state.

- **Pre-warm race with immediate keyup:** If the user taps the PTT key very quickly (down+up in < 50ms), the pre-warm may still be in progress when `startRecording()` is called. `beginCapturePhase()` must check that the engine is actually running before installing the tap.

- **Format stabilization timeout:** If `waitForFormatStabilization` times out (1.5 seconds), the single rebuild+retry must not loop. Gate the retry with a flag.

- **No built-in mic (Mac Pro with no internal mic):** `builtInMicrophoneDeviceID()` may return `nil`. Smart selection must fall back gracefully to the default input device and suppress the UX note.

- **mediaIsPlaying detection:** Detecting whether the system is playing audio is not trivially available on macOS without hooking into a per-app audio session. A conservative approach: check if the default output device's I/O cycle is active via `kAudioDevicePropertyDeviceIsRunningSomewhere`. False negatives are acceptable — in the worst case, smart selection does not kick in.

- **macOS 26 Tahoe `bluetoothHighQualityRecording`:** When this API ships, the codec coexistence problem is solved at the OS level. Wrap the pre-warm and smart selection logic in an availability check and bypass it on macOS 26+ when the new API is active.

- **Regression on built-in mic users:** All five changes must be gated on Bluetooth device detection. Users with built-in mics or wired USB mics must experience no change in behavior.

## Future Work

- Adopt `bluetoothHighQualityRecording` on macOS 26 Tahoe on day one — this API removes the A2DP/SCO coexistence limitation and makes the codec switch workaround unnecessary
- Surface a one-time notification to AirPods users on first recording explaining the device selection behavior
- Add a "Bluetooth mode" indicator in the menu bar icon or status overlay while SCO is active
