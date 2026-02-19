# VAD Silence Removal Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Strip silence from recorded audio before sending to the ASR backend, improving transcription speed and preventing hallucinations.

**Architecture:** Extend the existing `SilenceDetector` actor to track speech segment boundaries during recording. After recording stops, use those boundaries to extract only voiced audio. An opt-in dual-buffer mode accumulates voiced samples in real-time as an alternative. The VAD always runs during recording (not just when auto-stop is enabled).

**Tech Stack:** Swift 6, FluidAudio (Silero VAD), SwiftUI, UserDefaults

**Design doc:** `docs/plans/2026-02-18-vad-silence-removal-design.md`

**Environment:** macOS Command Line Tools only. No XCTest. Build with `swift build`. Use `@skills/run-smoke-test` for runtime verification.

---

### Task 1: Add speech segment tracking to SilenceDetector

**Files:**
- Modify: `Sources/EnviousWispr/Audio/SilenceDetector.swift`

**Step 1: Add SpeechSegment type and tracking properties**

Add above the `SilenceDetector` actor definition:

```swift
/// A contiguous region of detected speech, measured in sample indices.
struct SpeechSegment: Sendable {
    let startSample: Int
    let endSample: Int
}
```

Add these properties inside the `SilenceDetector` actor, after `isReady`:

```swift
private(set) var speechSegments: [SpeechSegment] = []
private var currentSpeechStart: Int? = nil
private var processedSampleCount: Int = 0
```

**Step 2: Update reset() to clear new state**

Replace the existing `reset()` method:

```swift
func reset() {
    streamState = .initial()
    speechDetected = false
    speechSegments = []
    currentSpeechStart = nil
    processedSampleCount = 0
}
```

**Step 3: Update processChunk() to track segment boundaries**

Replace the existing `processChunk()` method:

```swift
/// Process a chunk of 4096 audio samples (16kHz mono).
/// Returns `true` if silence after speech is detected (auto-stop should trigger).
func processChunk(_ samples: [Float]) async -> Bool {
    guard let vad = vadManager else { return false }

    let segConfig = VadSegmentationConfig(
        minSpeechDuration: 0.3,
        minSilenceDuration: silenceTimeout,
        speechPadding: 0.1
    )

    guard let result = try? await vad.processStreamingChunk(
        samples,
        state: streamState,
        config: segConfig
    ) else {
        processedSampleCount += samples.count
        return false
    }

    streamState = result.state

    var shouldAutoStop = false

    if let event = result.event {
        if event.isStart {
            speechDetected = true
            currentSpeechStart = processedSampleCount
        }
        if event.isEnd && speechDetected {
            // Close the speech segment
            if let start = currentSpeechStart {
                speechSegments.append(SpeechSegment(
                    startSample: start,
                    endSample: processedSampleCount + samples.count
                ))
                currentSpeechStart = nil
            }
            shouldAutoStop = true
        }
    }

    processedSampleCount += samples.count

    return shouldAutoStop
}
```

**Step 4: Add finalizeSegments() for speech at recording end**

Add after `processChunk()`:

```swift
/// Close any open speech segment (user stopped recording mid-speech).
func finalizeSegments(totalSampleCount: Int) {
    if let start = currentSpeechStart {
        speechSegments.append(SpeechSegment(
            startSample: start,
            endSample: totalSampleCount
        ))
        currentSpeechStart = nil
    }
}
```

**Step 5: Add filterSamples() method**

Add after `finalizeSegments()`:

```swift
/// Extract only voiced audio from the full sample buffer using tracked speech segments.
/// Padding of 1600 samples (100ms at 16kHz) preserves word onsets/offsets.
func filterSamples(from allSamples: [Float], padding: Int = 1600) -> [Float] {
    guard !speechSegments.isEmpty else { return allSamples }

    // If total voiced audio is too short (<0.3s = 4800 samples), return raw audio
    let totalVoiced = speechSegments.reduce(0) { $0 + ($1.endSample - $1.startSample) }
    guard totalVoiced >= 4800 else { return allSamples }

    var result: [Float] = []
    for segment in speechSegments {
        let start = max(0, segment.startSample - padding)
        let end = min(allSamples.count, segment.endSample + padding)
        guard start < end else { continue }
        result.append(contentsOf: allSamples[start..<end])
    }
    return result.isEmpty ? allSamples : result
}
```

**Step 6: Update unload() to clear new state**

Replace existing `unload()`:

```swift
func unload() {
    vadManager = nil
    isReady = false
    reset()
}
```

**Step 7: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build Succeeded

**Step 8: Commit**

```bash
git add Sources/EnviousWispr/Audio/SilenceDetector.swift
git commit -m "feat(audio): add speech segment tracking and silence filtering to SilenceDetector"
```

---

### Task 2: Add dual-buffer mode to SilenceDetector

**Files:**
- Modify: `Sources/EnviousWispr/Audio/SilenceDetector.swift`

**Step 1: Add dual-buffer properties**

Add after the `processedSampleCount` property:

```swift
// Dual-buffer mode: accumulate voiced samples in real-time
private(set) var voicedSamples: [Float] = []
var dualBufferMode: Bool = false
```

**Step 2: Update reset() to clear voicedSamples**

Add `voicedSamples = []` inside `reset()`, after `processedSampleCount = 0`.

**Step 3: Update processChunk() for dual-buffer accumulation**

In `processChunk()`, add dual-buffer logic. After the `if let event = result.event` block and before `processedSampleCount += samples.count`, add:

```swift
// Dual-buffer: accumulate voiced chunks when speech is active
if dualBufferMode && (currentSpeechStart != nil || speechDetected && !shouldAutoStop) {
    voicedSamples.append(contentsOf: samples)
}
```

Note: This appends the current chunk when we're inside a speech region. The `currentSpeechStart != nil` check means speech has started but not ended.

**Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build Succeeded

**Step 5: Commit**

```bash
git add Sources/EnviousWispr/Audio/SilenceDetector.swift
git commit -m "feat(audio): add dual-buffer mode for real-time silence filtering"
```

---

### Task 3: Make VAD always run and filter before transcription

**Files:**
- Modify: `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift`

**Step 1: Add vadDualBuffer property**

Add after `var vadSilenceTimeout: Double = 1.5` (line 27):

```swift
var vadDualBuffer: Bool = false
```

**Step 2: Always start VAD monitoring**

In `startRecording()`, replace lines 82-85:

```swift
            // Start VAD monitoring if enabled
            if vadAutoStop {
                startVADMonitoring()
            }
```

With:

```swift
            // Always start VAD monitoring for silence removal
            startVADMonitoring()
```

**Step 3: Gate auto-stop in monitorVAD()**

In `monitorVAD()`, the auto-stop behavior should only trigger when `vadAutoStop` is true. Replace the block at lines 245-249:

```swift
                let shouldStop = await detector.processChunk(chunk)

                if shouldStop && state == .recording {
                    await stopAndTranscribe()
                    return
                }
```

With:

```swift
                let shouldStop = await detector.processChunk(chunk)

                if shouldStop && vadAutoStop && state == .recording {
                    await stopAndTranscribe()
                    return
                }
```

**Step 4: Configure dual-buffer mode in monitorVAD()**

In `monitorVAD()`, after `await detector.reset()` (line 224), add:

```swift
        await detector.setDualBufferMode(vadDualBuffer)
```

Wait — `dualBufferMode` is a `var` on the actor, not a method. Since we're calling from outside the actor, we need a setter method. Go back to `SilenceDetector.swift` and add this method after the `dualBufferMode` property:

Actually, since `dualBufferMode` is not `private`, we can set it directly via `detector.dualBufferMode = vadDualBuffer` from within an `await` context. But since SilenceDetector is an actor, property assignment requires being inside the actor's isolation. We need a setter method.

Add to `SilenceDetector.swift`:

```swift
func setDualBufferMode(_ enabled: Bool) {
    dualBufferMode = enabled
}
```

Then in `monitorVAD()`, after `await detector.reset()`:

```swift
        await detector.setDualBufferMode(vadDualBuffer)
```

**Step 5: Filter samples before transcription**

In `stopAndTranscribe()`, replace lines 99-103:

```swift
        let samples = audioCapture.stopCapture()
        guard !samples.isEmpty else {
            state = .error("No audio captured")
            return
        }
```

With:

```swift
        let rawSamples = audioCapture.stopCapture()
        guard !rawSamples.isEmpty else {
            state = .error("No audio captured")
            return
        }

        // Filter silence using VAD speech segments
        let samples: [Float]
        if let detector = silenceDetector {
            await detector.finalizeSegments(totalSampleCount: rawSamples.count)
            if vadDualBuffer {
                let voiced = await detector.voicedSamples
                samples = voiced.isEmpty ? rawSamples : voiced
            } else {
                samples = await detector.filterSamples(from: rawSamples)
            }
        } else {
            samples = rawSamples
        }
```

**Step 6: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build Succeeded

**Step 7: Commit**

```bash
git add Sources/EnviousWispr/Audio/SilenceDetector.swift Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift
git commit -m "feat(pipeline): always run VAD and filter silence before transcription"
```

---

### Task 4: Add vadDualBuffer setting to AppState

**Files:**
- Modify: `Sources/EnviousWispr/App/AppState.swift`

**Step 1: Add vadDualBuffer property**

Add after the `vadSilenceTimeout` property (after line 97):

```swift
var vadDualBuffer: Bool {
    didSet {
        UserDefaults.standard.set(vadDualBuffer, forKey: "vadDualBuffer")
        pipeline.vadDualBuffer = vadDualBuffer
    }
}
```

**Step 2: Load from UserDefaults in init()**

Add after `vadSilenceTimeout = defaults.object(...)` line (after line 128):

```swift
vadDualBuffer = defaults.object(forKey: "vadDualBuffer") as? Bool ?? false
```

**Step 3: Sync to pipeline in init()**

Add after `pipeline.vadSilenceTimeout = vadSilenceTimeout` (after line 140):

```swift
pipeline.vadDualBuffer = vadDualBuffer
```

**Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build Succeeded

**Step 5: Commit**

```bash
git add Sources/EnviousWispr/App/AppState.swift
git commit -m "feat(settings): add vadDualBuffer persisted setting to AppState"
```

---

### Task 5: Add dual-buffer toggle to Settings UI

**Files:**
- Modify: `Sources/EnviousWispr/Views/Settings/SettingsView.swift`

**Step 1: Add toggle to Voice Activity Detection section**

In `GeneralSettingsView`, in the "Voice Activity Detection" section (after line 93, after the closing brace of `if appState.vadAutoStop`), add:

```swift
                Toggle("Real-time silence filter", isOn: $state.vadDualBuffer)
                if appState.vadDualBuffer {
                    Text("Experimental: Filters silence in real-time during recording. Uses more memory. Disable if you notice audio artifacts.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
```

**Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build Succeeded

**Step 3: Commit**

```bash
git add Sources/EnviousWispr/Views/Settings/SettingsView.swift
git commit -m "feat(ui): add real-time silence filter toggle to settings"
```

---

### Task 6: Verify build and smoke test

**Step 1: Clean build**

Run: `swift build 2>&1 | tail -10`
Expected: Build Succeeded

**Step 2: Run smoke test**

Use `@skills/run-smoke-test` to verify the app launches without crashing.

**Step 3: Final commit (if any fixups needed)**

If any fixes were required, commit them:

```bash
git add -A
git commit -m "fix(audio): address build issues from silence removal feature"
```
