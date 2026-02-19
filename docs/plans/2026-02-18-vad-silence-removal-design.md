# VAD Silence Removal Design

**Date:** 2026-02-18
**Status:** Approved

## Problem

Audio sent to the ASR backend includes all silence segments (leading, trailing, inter-utterance gaps). This causes:
- Slower transcription — more audio to process
- AI hallucinations — ASR models fabricate words during silent stretches
- Worse transcript quality — phantom text the user never said

Competitors (superwhisper, Handy.computer) strip silence via Silero VAD before transcription.

## Current State

- `SilenceDetector` (actor) already uses FluidAudio's Silero VAD (`VadManager`) during recording
- Used **only** for auto-stop: detects silence-after-speech → triggers `stopAndTranscribe()`
- VAD only runs when `vadAutoStop` is enabled
- Full `capturedSamples` (including silence) is always sent to ASR

## Design

### Always-on silence removal

Silence removal is always active — no user toggle. The VAD runs during every recording session, not just when auto-stop is on. Before transcription, silence segments are stripped from the audio.

### Two modes

1. **Post-recording filter (default):** Track speech segment boundaries during recording. After recording stops, use boundaries to extract only voiced audio from `capturedSamples`.

2. **Real-time dual-buffer (opt-in):** Additionally accumulate voiced-only samples in real-time. When recording stops, use this buffer directly — skipping the post-filter step.

### SilenceDetector changes

New types and properties:

```swift
struct SpeechSegment: Sendable {
    let startSample: Int
    let endSample: Int
}

// On SilenceDetector actor:
private(set) var speechSegments: [SpeechSegment] = []
private var currentSpeechStart: Int? = nil
private var processedSampleCount: Int = 0

// Dual-buffer mode:
private(set) var voicedSamples: [Float] = []
var dualBufferMode: Bool = false
```

`processChunk()` changes:
- On `speechStart` event: record `processedSampleCount` as segment start
- On `speechEnd` event: close segment with current count as end
- In dual-buffer mode: also append voiced chunks to `voicedSamples`
- Increment `processedSampleCount` by chunk size after each chunk

New method:

```swift
func filterSamples(from allSamples: [Float], padding: Int = 1600) -> [Float] {
    guard !speechSegments.isEmpty else { return allSamples }
    var result: [Float] = []
    for segment in speechSegments {
        let start = max(0, segment.startSample - padding)
        let end = min(allSamples.count, segment.endSample + padding)
        result.append(contentsOf: allSamples[start..<end])
    }
    return result
}
```

Padding: 1600 samples = 100ms at 16kHz, preserving word onsets/offsets.

`reset()` changes: clear `speechSegments`, `voicedSamples`, `currentSpeechStart`, `processedSampleCount`.

### TranscriptionPipeline changes

1. **Always start VAD monitoring:** Remove the `if vadAutoStop` guard around `startVADMonitoring()` in `startRecording()`. VAD always runs.

2. **Auto-stop remains gated:** The auto-stop behavior (calling `stopAndTranscribe()` on silence-after-speech) stays behind the `vadAutoStop` flag.

3. **Filter before transcription:** In `stopAndTranscribe()`, after getting raw samples from `audioCapture.stopCapture()`:

```swift
let samples = audioCapture.stopCapture()
let filtered: [Float]
if vadDualBuffer, let detector = silenceDetector {
    let voiced = await detector.voicedSamples
    filtered = voiced.isEmpty ? samples : voiced
} else if let detector = silenceDetector {
    filtered = await detector.filterSamples(from: samples)
} else {
    filtered = samples
}
// transcribe filtered samples
```

4. **New property:** `var vadDualBuffer: Bool = false`

### AppState changes

New persisted property:

```swift
var vadDualBuffer: Bool {
    didSet {
        UserDefaults.standard.set(vadDualBuffer, forKey: "vadDualBuffer")
        pipeline.vadDualBuffer = vadDualBuffer
    }
}
```

Default: `false`. Loaded from UserDefaults in `init()`.

### Settings UI changes

In `GeneralSettingsView`, the existing "Voice Activity Detection" section gains one toggle:

```swift
Section("Voice Activity Detection") {
    Toggle("Auto-stop on silence", isOn: $state.vadAutoStop)

    if appState.vadAutoStop {
        // existing silence timeout slider
    }

    Toggle("Real-time silence filter", isOn: $state.vadDualBuffer)
    if appState.vadDualBuffer {
        Text("Experimental: Filters silence in real-time during recording. Uses more memory. Disable if you notice audio artifacts.")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}
```

### Data flow

```
Recording starts
  → SilenceDetector.prepare() (always)
  → monitorVAD() starts (always)
  → Audio chunks → processChunk()
    → Speech segments tracked (start/end sample indices)
    → [if dual-buffer] voiced chunks accumulated separately
    → [if auto-stop + silence-after-speech] → stopAndTranscribe()

Recording stops
  → [if dual-buffer] use silenceDetector.voicedSamples
  → [else] use silenceDetector.filterSamples(from: capturedSamples)
  → filtered samples → ASR backend → result
```

### Edge cases

- **No speech detected:** If `speechSegments` is empty, pass all samples through (fallback to raw audio).
- **Speech at recording end:** If recording stops mid-speech (no `speechEnd` event), close the open segment at the final sample count.
- **Very short recordings:** If total voiced audio < 0.3s, pass raw audio to avoid empty transcripts.
- **Dual-buffer memory:** `voicedSamples` grows proportionally to speech duration. For a 5-minute recording with 50% speech, this adds ~2.4MB (vs ~4.8MB for full audio). Acceptable.

### Files to modify

| File | Change |
|------|--------|
| `Sources/EnviousWispr/Audio/SilenceDetector.swift` | Add segment tracking, dual-buffer, `filterSamples()` |
| `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` | Always run VAD, filter before transcription |
| `Sources/EnviousWispr/App/AppState.swift` | Add `vadDualBuffer` property |
| `Sources/EnviousWispr/Views/Settings/SettingsView.swift` | Add dual-buffer toggle |
