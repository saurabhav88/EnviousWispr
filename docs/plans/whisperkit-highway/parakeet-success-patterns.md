# Parakeet Success Patterns — What Works and Why

**Compiled by:** Oracle
**Date:** 2026-03-06
**Purpose:** Document what makes Parakeet's pipeline feel "perfect" so the Architect can replicate these patterns (adapted for batch mode) in the WhisperKit highway.

---

## 1. State Machine: Simple, Linear, Unambiguous

**File:** `Pipeline/TranscriptionPipeline.swift` (758 lines), `Models/AppSettings.swift:17-45`

The `PipelineState` enum has exactly 6 cases:
```swift
enum PipelineState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case polishing
    case complete
    case error(String)
}
```

### Why it works for Parakeet:

1. **No model-loading state needed.** Parakeet pre-loads via `FluidAudio.AsrModels.downloadAndLoad(version: .v3)` at app launch. By the time the user presses PTT, `asrManager.isModelLoaded` is always `true`. The guard at `TranscriptionPipeline.swift:133` (`if !asrManager.isModelLoaded`) is never hit.

2. **Streaming hides the ASR phase.** Parakeet's `StreamingAsrManager` processes audio *during* recording. When recording stops, `finalizeStreaming()` takes milliseconds (just the last chunk). The `.transcribing` state at line 338 is effectively instantaneous — the user sees the overlay transition from recording to polishing without a visible ASR gap.

3. **Linear transitions only.** The state machine is a strict linear progression: `idle -> recording -> transcribing -> polishing -> complete`. No branching, no loops, no conditional transitions. Any state can go to `.error(String)`.

4. **Each state has exactly one meaning.** `.recording` = mic is capturing. `.transcribing` = ASR is running. `.polishing` = LLM is running. No overloading.

### Key pattern for WhisperKit:
WhisperKit needs `.loadingModel` and a visible `.transcribing` phase. Its state machine will be longer but should maintain the same linear, unambiguous property.

---

## 2. Overlay/UX Flow: Three States, Seamless Transitions

**File:** `Views/Overlay/RecordingOverlayPanel.swift`, `App/AppState.swift:128-151`

### The overlay handler in AppState:
```swift
pipeline.onStateChange = { [weak self] newState in
    switch newState {
    case .recording:
        self.hotkeyService.registerCancelHotkey()
        self.recordingOverlay.show(audioLevelProvider: { self.audioCapture.audioLevel ?? 0 })
    case .transcribing:
        self.hotkeyService.unregisterCancelHotkey()
        // Recording overlay stays visible — transitions to polishing
    case .polishing:
        self.hotkeyService.unregisterCancelHotkey()
        self.recordingOverlay.showPolishing()
    case .error, .idle:
        self.recordingOverlay.hide()
    case .complete:
        self.recordingOverlay.hide()
        self.loadTranscripts()
    }
}
```

### Why it works:

1. **Three visual states only:** Recording lips (with audio-reactive bars + timer) -> Polishing spinner (spectrum wheel + "Polishing...") -> Hidden. The `.transcribing` state is a no-op for the overlay because streaming finalization is too fast to show.

2. **Generation counter prevents ghost overlays.** `RecordingOverlayPanel` uses `generation: UInt64` that increments on every `show()`/`hide()`. Deferred `DispatchWorkItem` closures capture the token at dispatch time and bail if a newer operation superseded them. This eliminates all "async outlives state" races during rapid PTT tap sequences.

3. **`DispatchQueue.main.async` for run-loop deferral.** Panel creation is deferred to the next run loop cycle to avoid re-entrant NSHostingView creation during menu dismiss animations. This is critical — `Task { @MainActor }` does NOT guarantee deferral and caused crashes.

4. **`transitionToPolishing()` handles the recording->polishing transition in-place.** Closes the recording panel, flushes CA transactions, increments generation, then creates the polishing panel on the next run loop. Clean visual transition with no flicker.

5. **`CATransaction.flush()` before `close()` prevents use-after-free.** The recording overlay has running animations (audio level polling at 50ms, rainbow gradient pulsing). Flushing pending CA transactions before closing ensures the final animation frame commits while the view graph is still alive.

### Key pattern for WhisperKit:
WhisperKit needs a 4th visual state: "Loading model..." (or "Transcribing...") between recording and polishing. The `OverlayIntent` approach from the architecture decision (`docs/whisperkit-architecture-decision.md:62-69`) maps cleanly:
```swift
enum OverlayIntent {
    case hidden
    case recording(audioLevelProvider: () -> Float)
    case processing(label: String)  // "Loading model...", "Transcribing...", "Polishing..."
}
```

---

## 3. Audio Capture: Two-Phase Start + Streaming Forwarding

**File:** `Audio/AudioCaptureManager.swift` (700 lines)

### The two-phase recording start:

1. **Phase 1: `startEnginePhase()`** — resolves input device (smart BT selection), enables voice processing, registers config-change observer, starts engine. Triggers any Bluetooth A2DP->SCO codec switch.

2. **Format stabilization wait:** `waitForFormatStabilization(maxWait: 1.5, pollInterval: 0.2)` — polls input format until two consecutive reads match. BT codec switch settles in 200ms-1s.

3. **Phase 2: `beginCapturePhase()`** — creates `AVAudioConverter` (input format -> 16kHz mono Float32), installs tap on input node with 4096 frame buffer, starts `AsyncStream<AVAudioPCMBuffer>`.

### Streaming forwarding to Parakeet:

The pipeline wires `audioCapture.onBufferCaptured` to feed each converted buffer to `asrManager.feedAudio()`:
```swift
audioCapture.onBufferCaptured = { [weak self] buffer in
    nonisolated(unsafe) let safeBuffer = buffer
    Task { @MainActor in
        guard self.streamingASRActive, self.state == .recording else { return }
        try? await self.asrManager.feedAudio(safeBuffer)
    }
}
```

### `TapStoppedFlag` — atomic guard against heap corruption:

A `nonisolated` `OSAllocatedUnfairLock<Bool>` flag checked at the top of every tap handler invocation. Set on the main thread BEFORE `removeTap(onBus:)`. Prevents the real-time audio thread from creating `Task { @MainActor }` allocations during teardown, which would corrupt malloc's free lists.

### Pre-warm on PTT key-down:

`preWarm()` starts the engine phase on key-down, triggering the BT codec switch before the key-up (recording start). By the time the user releases PTT, the codec switch has settled.

### Key pattern for WhisperKit:
WhisperKit doesn't need streaming forwarding — it collects samples in `capturedSamples: [Float]` and passes them to `transcribe(audioSamples:)` after recording stops. The `AudioCaptureManager` already supports this natively — that's how `stopCapture() -> [Float]` works. No modifications needed to AudioCaptureManager.

---

## 4. Error Handling: Fail Fast, State Always Consistent

**File:** `Pipeline/TranscriptionPipeline.swift`

### Patterns that keep state consistent:

1. **`isStopping` reentrancy guard** (line 56, 253-255): Prevents concurrent `stopAndTranscribe()` calls (e.g., VAD auto-stop racing PTT release). Uses `defer { isStopping = false }` for guaranteed cleanup.

2. **`defer` for streaming cleanup** (line 151): `defer { if !streamingSetupSucceeded { deactivateStreamingForwarding() } }` ensures buffer forwarding is torn down if any subsequent step in `startRecording()` throws.

3. **Device disconnect handler** (line 79-93): `audioCapture.onEngineInterrupted` immediately cancels VAD, cancels streaming ASR, deactivates forwarding, clears target app, and transitions to `.error("Audio device disconnected")`. No state leaks.

4. **Streaming finalize with timeout** (line 721-743): Uses `withThrowingTaskGroup` to race finalization against a 10-second deadline. Whichever finishes first wins; loser is cancelled. On timeout, falls back to batch transcription.

5. **Short recording discard** (line 260-277): Recordings shorter than `minimumRecordingDuration` are silently discarded with full cleanup (cancel VAD, cancel streaming, deactivate forwarding, stop capture, clear state).

6. **Error → state = .error(message):** Every `catch` block transitions to `.error()` with a descriptive message. No silent failures, no corrupted intermediate states.

### Key pattern for WhisperKit:
The `WhisperKitPipeline` should replicate the `defer` cleanup pattern and the reentrancy guard. The device disconnect handler should wire identically. The streaming timeout pattern isn't needed (WhisperKit is batch-only), but the batch transcription `catch` block must set `.error()` the same way.

---

## 5. The Polish Handoff: The Exact Merge Point

**File:** `Pipeline/TranscriptionPipeline.swift:340-396`, `Pipeline/TextProcessingStep.swift`, `Pipeline/Steps/LLMPolishStep.swift`

### The handoff sequence:

1. ASR produces text: `let asrText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)`
2. Empty check: if `asrText.isEmpty`, transition to `.error("No speech detected")` and return
3. Run text processing chain: `context = try await runTextProcessing(asrText: asrText, language: result.language)`
4. The chain iterates over `textProcessingSteps: [any TextProcessingStep]` in order:
   - `WordCorrectionStep` — applies custom word corrections
   - `FillerRemovalStep` — removes filler words (um, uh, etc.)
   - `LLMPolishStep` — sends to LLM for grammar/style polish

### `LLMPolishStep.onWillProcess` callback:

```swift
llmPolishStep.onWillProcess = { [weak self] in
    self?.state = .polishing
}
```

This callback fires at the start of `LLMPolishStep.process()`, BEFORE the actual LLM call. It transitions the pipeline state to `.polishing`, which triggers the overlay to show the "Polishing..." spinner. This is the cleanest separation point — the pipeline doesn't know when LLM work starts; the step tells it.

### `TextProcessingContext` carries everything:

```swift
struct TextProcessingContext {
    var text: String             // Current text (mutable)
    var polishedText: String?    // Optional polished version
    let originalASRText: String  // Read-only original
    let language: String?        // From ASR result
    var llmProvider: String?     // Set by LLMPolishStep
    var llmModel: String?        // Set by LLMPolishStep
}
```

### Key pattern for WhisperKit:
The entire text processing chain (`runTextProcessing()`) is backend-agnostic. It takes `asrText: String` and `language: String?` — both of which WhisperKit produces identically. This IS the merge point. The WhisperKit pipeline can call the exact same `runTextProcessing()` method (or share the step chain) once it has the ASR result. No adaptation needed.

**The contract is:**
- Input: `String` (trimmed ASR text) + `String?` (language code)
- Output: `TextProcessingContext` with `.text`, `.polishedText`, `.llmProvider`, `.llmModel`
- Side effect: `onWillProcess` fires → pipeline transitions to `.polishing`

---

## 6. VAD Integration: Silero + SmoothedVAD + FluidAudio

**File:** `Audio/SilenceDetector.swift`, `Pipeline/TranscriptionPipeline.swift:648-711`

### How it works:

1. **SilenceDetector** is an `actor` wrapping FluidAudio's `VadManager` (Silero model)
2. Processes 4096-sample chunks (256ms at 16kHz) — must match Silero's expected input size
3. Raw VAD probability is smoothed with **EMA** (exponential moving average, alpha=0.3)
4. Three-phase state machine: `idle -> speech -> hangover(chunksRemaining) -> idle`
   - Onset: smoothed probability > `onsetThreshold` for `onsetConfirmationChunks` consecutive chunks
   - Offset: smoothed probability < `offsetThreshold` triggers hangover countdown
   - Hangover: keeps "speech" active for N more chunks to bridge brief pauses
5. `SmoothedVADConfig.fromSensitivity()` maps user slider (0.0-1.0) to onset/offset thresholds

### VAD monitoring loop in pipeline:

```swift
private func monitorVAD() async {
    while state == .recording && !Task.isCancelled {
        while processedSampleCount + chunkSize <= currentCount {
            let chunk = Array(audioCapture.capturedSamples[processedSampleCount..<endIdx])
            let shouldStop = await detector.processChunk(chunk)
            if shouldStop && vadAutoStop && state == .recording {
                Task { [weak self] in await self?.stopAndTranscribe() }
                return
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
}
```

### Critical details:
- VAD auto-stop spawns `stopAndTranscribe()` in a *new* Task to prevent `CancellationError` from propagating into transcription if `vadMonitorTask` is cancelled concurrently
- `detector.reset()` called before each session — `VadStreamState` persists across chunks and must be cleared
- After recording stops, `detector.finalizeSegments()` + `detector.filterSamples()` removes silence from the collected audio before passing to ASR

### Key pattern for WhisperKit:
VAD serves two purposes:
1. **Auto-stop** — works identically for WhisperKit (stop recording when user stops talking)
2. **Silence filtering** — filters captured samples before batch ASR. WhisperKit actually benefits MORE from this because it processes all audio at once (silence wastes compute in batch mode)

WhisperKit also has its own `EnergyVAD` and `chunkingStrategy: .vad` option. The pipeline's external Silero VAD complements rather than replaces WhisperKit's internal VAD — Silero handles auto-stop and pre-filtering, WhisperKit's chunker handles internal segment splitting for long audio.

---

## 7. Performance Feel: Why Parakeet Feels "Instant"

### The latency budget (from source code analysis):

| Phase | Typical Duration | User Perception |
|-------|-----------------|-----------------|
| PTT key-down → engine start | 0ms (pre-warmed) | Invisible |
| BT codec switch | 0ms (pre-warmed settles it) | Invisible |
| Recording → streaming ASR | Continuous, overlapped | User sees lips, hears themselves |
| PTT release → streaming finalize | 10-50ms | Invisible (overlay stays as recording) |
| VAD silence filter | <5ms | Invisible |
| LLM connection pre-warm | Overlapped with ASR | Invisible |
| LLM polish | 500ms-3s | Visible: "Polishing..." spinner |
| Paste | 50-200ms | Invisible |

### Specific optimizations that create the "instant" feel:

1. **Pre-warm on key-down** (`preWarmAudioInput()` at `AppState.swift:172`): Engine starts on PTT press, not release. The 0.5-2s BT codec switch is hidden behind the user's natural "think about what to say" pause.

2. **Streaming ASR overlaps recording** (`ParakeetBackend.supportsStreaming = true`): By the time the user stops talking, 95%+ of the audio has already been transcribed. `finalizeStreaming()` only processes the last chunk — milliseconds.

3. **LLM connection pre-warm** (`LLMNetworkSession.shared.preWarmIfConfigured()` at line 293): TLS + HTTP/2 handshake starts as soon as recording stops, BEFORE ASR finishes. By the time the LLM request fires, the connection is already established.

4. **SSE streaming for polish** (`llmPolishStep.onToken = { _ in }` at line 97): Gemini uses `streamGenerateContent?alt=sse` instead of batch `generateContent`. First tokens arrive faster even though total time is similar.

5. **`capturedSamples.reserveCapacity(16000 * 30)`** at `AudioCaptureManager.swift:139`: Pre-allocates ~30s of sample buffer to avoid mid-recording reallocations that could cause audio glitches.

6. **Batch fallback with timeout** (`finalizeStreamingWithTimeout` at line 721-743): If streaming finalize takes >10s, falls back to batch transcription on VAD-filtered audio. User never waits indefinitely.

### Key patterns for WhisperKit:

WhisperKit cannot achieve parity on ASR overlap (batch mode means ASR happens AFTER recording). But it CAN replicate:
- **Pre-warm** — engine start on key-down (already shared via AudioCaptureManager)
- **LLM pre-warm** — start TLS handshake while batch ASR is running
- **VAD silence filtering** — reduce the audio WhisperKit must process (directly reduces batch ASR time)
- **Show distinct "Transcribing..." phase** — user sees progress, not a frozen UI
- **Model pre-loading** — keep model in memory (WhisperKitSetupService already handles this; idle timer unloads are the edge case that causes problems)

The irreducible latency difference: Parakeet's user-visible processing time is ~500ms-3s (just polish). WhisperKit's is ~1-5s (batch ASR) + ~500ms-3s (polish) = ~1.5-8s total. The architecture should be honest about this gap and communicate it to the user.

---

## Summary: Patterns to Replicate vs. Patterns to Adapt

### Replicate exactly (backend-agnostic):
- `AudioCaptureManager` two-phase start + pre-warm
- `TapStoppedFlag` atomic guard
- `TextProcessingStep` chain with `onWillProcess` callback
- `TextProcessingContext` as the merge-point contract
- `SilenceDetector` for auto-stop + silence filtering
- `isStopping` reentrancy guard
- `defer` blocks for cleanup on all exit paths
- `RecordingOverlayPanel` generation counter
- `DispatchQueue.main.async` for panel creation (not `Task { @MainActor }`)
- `CATransaction.flush()` before panel close
- `LLMNetworkSession.preWarmIfConfigured()` during ASR

### Adapt for batch mode:
- State machine: add `.loadingModel` and make `.transcribing` visually distinct
- Overlay: add `processing("Loading model...")` and `processing("Transcribing...")` intents
- Audio routing: use `capturedSamples` collection (already supported) instead of `onBufferCaptured` streaming
- Model lifecycle: handle cold-start gracefully (PTT during model-unloaded state)
- Cancellation: `cancelStartRequest()` for PTT release during model load (no streaming to cancel)

### Cannot replicate (inherent to batch):
- Overlapped ASR during recording (batch must wait for recording to finish)
- Sub-100ms ASR finalization (batch takes 1-5s)
- Invisible `.transcribing` phase (batch must show it)
