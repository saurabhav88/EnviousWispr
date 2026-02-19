# Feature: Always-On Microphone Mode

**ID:** 014
**Category:** Audio & Models
**Priority:** Low
**Inspired by:** Handy — stream stays open continuously, OS-level mute when idle
**Status:** Ready for Implementation

## Problem

Currently, `AVAudioEngine` is started when recording begins and stopped when recording ends. This adds a brief startup latency (~100-200ms) and can occasionally cause audio glitches on the first few frames.

## Proposed Solution

Add an optional "Always-On" microphone mode:

1. `AVAudioEngine` stays running continuously after first use
2. Audio tap is always installed but samples are discarded when not recording
3. When recording starts, simply flip a flag to start accumulating samples
4. Eliminates engine startup latency entirely

A reference-type `DiscardFlag` box is shared between the `@MainActor` controller and the audio tap closure (which runs on a real-time audio thread). The tap checks the flag at the top of every callback; when `true` it returns immediately without accumulating samples or updating the UI level meter.

OS-level mute via `AudioObjectSetPropertyData` is explicitly **not implemented** — it would suppress the macOS orange microphone indicator in a misleading way and may cause unexpected behavior on some hardware.

## Files to Modify

| File | Change |
| ---- | ------ |
| `Sources/EnviousWispr/Audio/AudioCaptureManager.swift` | Add `DiscardFlag` type; split engine lifecycle into `startEngine()` / `teardownEngine()`; make `startCapture()` / `stopCapture()` lightweight flag flips when engine is already running; add `alwaysOn: Bool` property |
| `Sources/EnviousWispr/App/AppState.swift` | Add `alwaysOnMicrophone: Bool` persisted property; forward to `audioCapture.alwaysOn` |
| `Sources/EnviousWispr/Views/Settings/SettingsView.swift` | Add "Always-On Microphone" toggle with orange privacy warning to `GeneralSettingsView` |

## New Types / Properties

### `DiscardFlag` (add inside `AudioCaptureManager.swift`, above the class declaration)

```swift
/// Thread-safe flag box shared between @MainActor controller and the audio tap.
///
/// The tap runs on a real-time audio thread; it must not call any Swift
/// concurrency primitives. A plain UnsafeAtomic or class-with-lock would be
/// ideal, but for simplicity we use a final class with @unchecked Sendable
/// and an atomic Bool backed by OSAtomicCompareAndSwap. In practice, a single
/// Bool read on an Intel/ARM core is naturally atomic for aligned loads, making
/// this safe for a single-writer (MainActor) / single-reader (audio thread) pattern.
final class DiscardFlag: @unchecked Sendable {
    private var _value: Bool
    init(_ initial: Bool = true) { _value = initial }

    var value: Bool {
        get { _value }
        set { _value = newValue }
    }
}
```

### Restructured `AudioCaptureManager`

The key structural change is separating the engine's *existence* from the *accumulation* of samples:

```swift
@MainActor
@Observable
final class AudioCaptureManager {
    private(set) var isCapturing = false
    private(set) var audioLevel: Float = 0.0
    private(set) var capturedSamples: [Float] = []

    /// When true, the engine stays running between recordings.
    var alwaysOn: Bool = false

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// Shared with the tap closure. When true, the tap discards all audio.
    private var discardFlag = DiscardFlag(true)   // starts discarding

    /// Whether the engine + tap are currently installed and running.
    private var engineRunning = false

    nonisolated static let targetSampleRate: Double = 16000
    nonisolated static let targetChannels: AVAudioChannelCount = 1

    // MARK: - Public API (unchanged signatures)

    func startCapture() throws -> AsyncStream<AVAudioPCMBuffer> {
        guard !isCapturing else { return AsyncStream { $0.finish() } }
        capturedSamples = []
        audioLevel = 0.0

        if alwaysOn && engineRunning {
            // Engine already running — flip flag only.
            discardFlag.value = false
            isCapturing = true
            // Return a new stream backed by the existing continuation.
            let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
                self.bufferContinuation = continuation
            }
            return stream
        }

        // Full engine start (first use, or alwaysOn disabled).
        return try startEngine()
    }

    func stopCapture() -> [Float] {
        isCapturing = false
        discardFlag.value = true
        bufferContinuation?.finish()
        bufferContinuation = nil
        audioLevel = 0.0

        if alwaysOn && engineRunning {
            // Leave engine running; just stop accumulating.
            return capturedSamples
        }

        // Full teardown when alwaysOn is disabled.
        teardownEngine()
        return capturedSamples
    }

    /// Fully stop the engine (called on alwaysOn disable or app quit).
    func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        engineRunning = false
        discardFlag.value = true
    }
}
```

### `startEngine()` private method (replaces the body of the old `startCapture`)

```swift
private func startEngine() throws -> AsyncStream<AVAudioPCMBuffer> {
    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)

    guard let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Self.targetSampleRate,
        channels: Self.targetChannels,
        interleaved: false
    ) else { throw AudioError.formatCreationFailed }

    guard let audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
        throw AudioError.formatCreationFailed
    }
    self.converter = audioConverter

    let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
        self.bufferContinuation = continuation
    }

    let flag = self.discardFlag          // capture the shared box by reference
    flag.value = false                   // start accumulating immediately

    let onSamples: @Sendable (Float, [Float]) -> Void = { [weak self] level, samples in
        Task { @MainActor in
            self?.audioLevel = level
            self?.capturedSamples.append(contentsOf: samples)
        }
    }

    let tapContinuation = self.bufferContinuation
    let bufferSize: AVAudioFrameCount = 4096
    let tapHandler = Self.makeTapHandler(
        audioConverter: audioConverter,
        targetFormat: targetFormat,
        inputFormat: inputFormat,
        continuation: tapContinuation,
        onSamples: onSamples,
        discardFlag: flag
    )
    inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat, block: tapHandler)

    try engine.start()
    engineRunning = true
    isCapturing = true
    return stream
}
```

### Updated `makeTapHandler` signature

Add `discardFlag: DiscardFlag` as the last parameter, and insert an early-return guard at the top of the tap closure:

```swift
nonisolated private static func makeTapHandler(
    audioConverter: AVAudioConverter,
    targetFormat: AVAudioFormat,
    inputFormat: AVAudioFormat,
    continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?,
    onSamples: @escaping @Sendable (Float, [Float]) -> Void,
    discardFlag: DiscardFlag
) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
    return { buffer, _ in
        // Fast path: discard audio when not recording.
        guard !discardFlag.value else { return }

        // ... existing conversion and sample extraction logic unchanged ...
    }
}
```

### `AppState` additions

```swift
var alwaysOnMicrophone: Bool {
    didSet {
        UserDefaults.standard.set(alwaysOnMicrophone, forKey: "alwaysOnMicrophone")
        audioCapture.alwaysOn = alwaysOnMicrophone
        // If the user disables always-on while the engine is idle, tear it down.
        if !alwaysOnMicrophone && !audioCapture.isCapturing {
            audioCapture.teardownEngine()
        }
    }
}
```

Initialise in `AppState.init()`:

```swift
alwaysOnMicrophone = defaults.object(forKey: "alwaysOnMicrophone") as? Bool ?? false
audioCapture.alwaysOn = alwaysOnMicrophone
```

## Implementation Plan

### Step 1 — Add `DiscardFlag` to `AudioCaptureManager.swift`

Insert the `DiscardFlag` class declaration at the top of the file, before `AudioCaptureManager`. It must be `@unchecked Sendable` because the audio tap reads `_value` from a non-Swift-concurrency thread. The single-writer-from-MainActor / single-reader-from-audio-thread access pattern is safe on all Apple platforms for a Bool-sized aligned store/load.

### Step 2 — Refactor `AudioCaptureManager`

Add stored properties: `alwaysOn`, `discardFlag`, `engineRunning`. Extract the engine startup logic from `startCapture()` into a private `startEngine()` method. Extract the engine teardown logic from `stopCapture()` into a private `teardownEngine()` method (also expose it as `internal` so `AppState` can call it when disabling always-on).

Rewrite `startCapture()` and `stopCapture()` as described above. Update `makeTapHandler` to accept and check `discardFlag`.

The `capturedSamples` array must be reset to `[]` at the start of each `startCapture()` call regardless of engine state, since each recording session should start clean.

### Step 3 — Add `AppState.alwaysOnMicrophone`

Add the property with `didSet` as shown. The engine is **not** pre-started at launch even when `alwaysOnMicrophone == true` — it starts on the first recording and then stays running. Pre-starting would require microphone permission to be already granted at launch, which is not guaranteed.

### Step 4 — Settings UI

Inside `GeneralSettingsView`, add to the existing `Section("Recording")` or as a new standalone section, after the recording mode picker:

```swift
Section("Always-On Microphone") {
    Toggle("Keep microphone active between recordings", isOn: $state.alwaysOnMicrophone)

    if appState.alwaysOnMicrophone {
        Label(
            "The microphone stream stays open continuously after the first recording. Audio is silently discarded when not recording, but macOS will show the orange mic indicator at all times.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)

        Text("Eliminates the ~100-200 ms engine startup delay. Increases battery drain on laptops.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

### Step 5 — App termination cleanup

In `AppDelegate`, add a `applicationWillTerminate(_:)` callback that tears down the engine:

```swift
func applicationWillTerminate(_ notification: Notification) {
    appState.audioCapture.teardownEngine()
}
```

This ensures the macOS microphone indicator clears promptly when the app quits, rather than waiting for the process to be fully reaped.

### Step 6 — Handle always-on toggle at runtime

When the user disables `alwaysOnMicrophone` while idle (engine running, not recording), `AppState.alwaysOnMicrophone.didSet` calls `audioCapture.teardownEngine()`. When the user enables it mid-session, the engine will stay running after the next `stopCapture()` call — no explicit action needed.

## Testing Strategy

1. **Baseline — always-on disabled**: Record and stop twice. Verify behavior is identical to the pre-feature version: engine starts at `startCapture()`, stops at `stopCapture()`.

2. **Engine stays running**: Enable always-on. Record and stop. Verify `audioCapture.engineRunning == true` after `stopCapture()`. The macOS mic indicator (orange dot in menu bar / camera indicator strip on newer hardware) should remain visible.

3. **Discard between recordings**: Enable always-on. Record and stop. Wait 5 seconds. Record again and stop. Verify that `capturedSamples` for the second recording contains only audio from the second recording — no audio from the idle period between recordings.

4. **Latency reduction**: Compare time from hotkey press to first captured sample with always-on disabled vs enabled. The enabled case should eliminate the ~100-200 ms cold-start lag (measurable by logging `Date()` at the top of `startCapture()` vs first `onSamples` callback).

5. **Disable while idle**: Enable always-on. Record and stop (engine now running). Disable always-on in Settings. Verify `audioCapture.engineRunning == false` and the mic indicator disappears.

6. **Disable while recording**: Enable always-on. Start recording. Disable always-on mid-recording (unusual but valid). The current recording should complete normally using the flag-based path; the next `stopCapture()` should perform a full teardown.

7. **App termination**: Enable always-on. Record and stop (engine running). Quit the app. Verify the mic indicator disappears promptly (within ~1 s).

8. **Persistence**: Toggle the setting, quit, relaunch. The stored value should be restored.

9. **No captured audio during discard**: With always-on enabled, idle for 10 seconds, then start recording and immediately stop. Inspect the captured samples — the idle audio must not be present. This validates `discardFlag` works correctly.

10. **Transcript quality**: Run 3 back-to-back dictations with always-on enabled. Verify transcript quality is equivalent to the non-always-on path (no glitched first frames, no duplicated audio).

## Risks & Considerations

- Privacy: always-on mic may concern users (even if samples are discarded) — addressed by the orange warning label in Settings and the explicit opt-in toggle
- macOS shows orange mic indicator when AVAudioEngine is running — this is accurate and expected; the plan does not suppress it
- Battery impact on laptops — the idle tap burns minimal CPU (the `guard !discardFlag.value` early return costs less than 1 μs per callback), but the audio hardware stays active; this is called out in the Settings caption
- Should be opt-in, clearly labeled with privacy implications — enforced by the always-off default and orange warning text
- `DiscardFlag` uses `@unchecked Sendable` to cross the actor boundary — this is the same pattern as the existing `onSamples` callback. The access pattern (single writer on MainActor, single reader on audio thread) is safe on ARM64 and x86_64 for aligned Bool stores
- The `bufferContinuation` swap in the always-on `startCapture()` fast path creates a new `AsyncStream` each recording session. Consumers (the VAD monitor in `TranscriptionPipeline`) already create a new task per recording, so the new stream reference is always used correctly
