# Feature: Audio Start/Stop Feedback Sounds

**ID:** 012
**Category:** Audio & Models
**Priority:** Low
**Inspired by:** Handy — `.wav` sound files for recording start/stop, two themes (marimba, pop) + custom
**Status:** Ready for Implementation

## Problem

There is no audible confirmation when recording starts or stops. Users must look at the screen (overlay, menu bar icon) to confirm the app heard their hotkey. This is especially problematic when the app is in the background.

## Proposed Solution

Play short audio cues on recording start and stop:

- Start: system sound "Tink" (short ascending click)
- Stop: system sound "Pop" (short descending pop)
- Configurable: on/off toggle and volume slider (0–100 %)
- Preview buttons in Settings so the user can audition sounds before enabling
- Zero bundled sound files — uses macOS built-in `NSSound` named sounds

Use `NSSound` on the default output device. `NSSound` routes to the current audio output, not the microphone input, so it cannot be captured by the recording tap.

## Files to Modify

| File | Change |
| ---- | ------ |
| `Sources/EnviousWispr/Models/AppSettings.swift` | Add `soundFeedbackEnabled: Bool` and `soundFeedbackVolume: Float` to the settings surface (enum-less, just raw booleans/floats) |
| `Sources/EnviousWispr/App/AppState.swift` | Add `soundFeedbackEnabled` and `soundFeedbackVolume` persisted properties; instantiate and hold `AudioFeedbackService` |
| `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` | Inject `AudioFeedbackService`; call `playStart()` before `audioCapture.startCapture()` and `playStop()` after `audioCapture.stopCapture()` |
| `Sources/EnviousWispr/Views/Settings/SettingsView.swift` | Add "Feedback Sounds" section to `GeneralSettingsView` |

## New Files

| File | Purpose |
| ---- | ------- |
| `Sources/EnviousWispr/Services/AudioFeedbackService.swift` | `@MainActor final class` encapsulating start/stop sound playback via `NSSound` |

## New Types / Properties

### `AudioFeedbackService` (new file `Services/AudioFeedbackService.swift`)

```swift
import AppKit

/// Plays short audible cues on recording start and stop.
///
/// Uses NSSound with macOS built-in named sounds — no bundled audio files.
/// NSSound routes to the system output device, not the microphone input,
/// so sounds cannot be captured by the AVAudioEngine tap.
@MainActor
final class AudioFeedbackService {
    var isEnabled: Bool = false
    var volume: Float = 0.5    // 0.0 – 1.0

    private let startSoundName = "Tink"
    private let stopSoundName  = "Pop"

    /// Play the recording-start cue. Call BEFORE starting the audio engine.
    func playStart() {
        guard isEnabled else { return }
        play(named: startSoundName)
    }

    /// Play the recording-stop cue. Call AFTER stopping the audio engine.
    func playStop() {
        guard isEnabled else { return }
        play(named: stopSoundName)
    }

    /// Audition a named sound (for Settings preview buttons).
    func preview(start: Bool) {
        play(named: start ? startSoundName : stopSoundName)
    }

    // MARK: - Private

    private func play(named name: String) {
        guard let original = NSSound(named: name) else { return }
        // Copy so re-entrant calls overlap cleanly instead of restarting.
        guard let sound = original.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }
}
```

### `AppState` additions

```swift
let feedbackService = AudioFeedbackService()

var soundFeedbackEnabled: Bool {
    didSet {
        UserDefaults.standard.set(soundFeedbackEnabled, forKey: "soundFeedbackEnabled")
        feedbackService.isEnabled = soundFeedbackEnabled
    }
}

var soundFeedbackVolume: Float {
    didSet {
        UserDefaults.standard.set(soundFeedbackVolume, forKey: "soundFeedbackVolume")
        feedbackService.volume = soundFeedbackVolume
    }
}
```

Initialise in `AppState.init()`:

```swift
soundFeedbackEnabled = defaults.object(forKey: "soundFeedbackEnabled") as? Bool ?? false
soundFeedbackVolume  = defaults.object(forKey: "soundFeedbackVolume")  as? Float ?? 0.5
feedbackService.isEnabled = soundFeedbackEnabled
feedbackService.volume    = soundFeedbackVolume
```

Pass `feedbackService` into `TranscriptionPipeline.init()` and store it as a property.

### `TranscriptionPipeline` additions

```swift
// New init parameter and stored property
private let feedbackService: AudioFeedbackService

init(
    audioCapture: AudioCaptureManager,
    asrManager: ASRManager,
    transcriptStore: TranscriptStore,
    keychainManager: KeychainManager = KeychainManager(),
    feedbackService: AudioFeedbackService = AudioFeedbackService()
) {
    self.feedbackService = feedbackService
    // ... existing assignments
}
```

In `startRecording()`, immediately before `audioCapture.startCapture()`:

```swift
feedbackService.playStart()
```

In `stopAndTranscribe()`, immediately after `let rawSamples = audioCapture.stopCapture()`:

```swift
feedbackService.playStop()
```

## Implementation Plan

### Step 1 — Create `AudioFeedbackService`

Create `Sources/EnviousWispr/Services/AudioFeedbackService.swift` with the class shown above. No additional imports beyond `AppKit` are needed; `NSSound` is part of AppKit.

Verify that `NSSound(named: "Tink")` and `NSSound(named: "Pop")` return non-nil on macOS 14+. Both names have been stable since macOS 10.10. If either returns nil at runtime (sandboxed environment edge case), the guard in `play(named:)` silently skips playback.

### Step 2 — Add persisted settings to `AppState`

Add `soundFeedbackEnabled` and `soundFeedbackVolume` properties with `didSet` observers that write to `UserDefaults` and update `feedbackService`. Instantiate `feedbackService` as a `let` constant alongside the other services. Apply initial values from `UserDefaults` in `init()` immediately after the properties are assigned.

Update `AppState.init()` call-site for `TranscriptionPipeline` to pass `feedbackService`:

```swift
pipeline = TranscriptionPipeline(
    audioCapture: audioCapture,
    asrManager: asrManager,
    transcriptStore: transcriptStore,
    keychainManager: keychainManager,
    feedbackService: feedbackService
)
```

### Step 3 — Wire playback into `TranscriptionPipeline`

The timing constraints are:

- **Start sound**: must play before `engine.start()` so the sound fires at the user's hotkey press, not after a potential ~100 ms engine startup delay. Place `feedbackService.playStart()` as the first line of the `do { }` block in `startRecording()`, before `_ = try audioCapture.startCapture()`.
- **Stop sound**: must play after samples are captured but before the transcription work begins. Place `feedbackService.playStop()` immediately after `let rawSamples = audioCapture.stopCapture()` in `stopAndTranscribe()`.

`NSSound.play()` is non-blocking; it enqueues the sound on the output device asynchronously, so it does not hold up the pipeline.

### Step 4 — Settings UI

Inside `GeneralSettingsView`, add a `Section("Feedback Sounds")` after the existing `Section("Behavior")`:

```swift
Section("Feedback Sounds") {
    Toggle("Play sounds on start/stop", isOn: $state.soundFeedbackEnabled)

    if appState.soundFeedbackEnabled {
        HStack {
            Text("Volume")
            Slider(value: $state.soundFeedbackVolume, in: 0...1, step: 0.05)
            Text("\(Int(appState.soundFeedbackVolume * 100)) %")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 36)
        }

        HStack(spacing: 12) {
            Button("Preview Start") {
                appState.feedbackService.preview(start: true)
            }
            .controlSize(.small)

            Button("Preview Stop") {
                appState.feedbackService.preview(start: false)
            }
            .controlSize(.small)
        }

        Text("Short audio cues confirm recording state without requiring you to look at the screen.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

### Step 5 — Verify output routing

`NSSound` uses `AVAudioSession`-equivalent routing on macOS, defaulting to the system output device selected in System Settings > Sound > Output. It does not route through the default input (microphone) device. No special configuration is needed to prevent the sound from being captured by the `AVAudioEngine` tap — the tap is on the input node, while `NSSound` plays through the output.

## Testing Strategy

1. **Sound availability**: On app launch verify both `NSSound(named: "Tink")` and `NSSound(named: "Pop")` return non-nil. Add an assertion or warning log in `AudioFeedbackService.init()` in debug builds.

2. **Enabled / disabled toggle**: With sounds enabled, record and stop — both cues should be audible. Disable the toggle — neither cue should play on a subsequent record/stop cycle.

3. **Volume slider**: Set volume to 0 % — no sound should be heard. Set to 100 % — cues at full output volume. Verify intermediate values scale naturally.

4. **Preview buttons**: Click "Preview Start" and "Preview Stop" in Settings without recording. Each button should play its respective cue once at the current volume.

5. **Re-entrant playback**: Rapidly toggle recording on and off several times. Sounds should overlap cleanly rather than cutting each other off (ensured by `NSSound.copy()`).

6. **No mic bleed**: Start recording with sounds enabled. Speak for 3 seconds and stop. Inspect the transcript — the start/stop cues should not appear as transcribed words, confirming they are not captured by the mic tap.

7. **Persistence**: Change `soundFeedbackEnabled` and `soundFeedbackVolume`, quit and relaunch. Settings should survive.

## Risks & Considerations

- Must not play through the input device (would be captured by the mic) — addressed by `NSSound` routing to the output device
- Timing: play sound before starting mic capture, not after
- Sound files add to bundle size — using built-in named sounds eliminates this entirely
- Respect system volume / Do Not Disturb — `NSSound` respects the system output volume; Do Not Disturb does not suppress output sounds on macOS (only notifications), so sounds will play regardless
- `NSSound(named:)` is a synchronous AppKit call and must run on the main thread, which is already satisfied by the `@MainActor` annotation on `AudioFeedbackService`
