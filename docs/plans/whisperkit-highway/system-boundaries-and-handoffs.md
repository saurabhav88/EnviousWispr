# WhisperKit Highway — System Boundaries and Handoffs

> Author: Architect agent
> Date: 2026-03-06
> Revised: Fixed AudioCaptureManager (shared, not separate), updated routing, added event-driven pattern
> Basis: Source code audit + Oracle Lesson 9 correction

---

## The Two Highways

```
Parakeet Highway:
  Hotkey → AudioCaptureManager (shared) → onBufferCaptured → ParakeetBackend.feedAudio()
         → StreamingAsrManager (FluidAudio)
         → finalizeStreaming() → ASRResult
         → runTextProcessing() → LLMPolishStep
         → TranscriptPolisher.polish() ← CONVERGENCE POINT
         → Transcript → Store + Clipboard

WhisperKit Highway:
  Hotkey → AudioCaptureManager (shared) → [batch accumulation only, no forwarding]
         → WhisperKitBackend.transcribe(audioSamples:)
         → [Phase 3: AudioStreamTranscriber feeds from onBufferCaptured]
         → ASRResult
         → runTextProcessing() → LLMPolishStep
         → TranscriptPolisher.polish() ← CONVERGENCE POINT
         → Transcript → Store + Clipboard
```

**Both highways share one `AudioCaptureManager` instance.** The difference is buffer routing:
- Parakeet: `onBufferCaptured` fires per buffer → `feedAudio()` to streaming ASR
- WhisperKit (Phase 0-2): `onBufferCaptured` is nil — buffers accumulate in `capturedSamples` only
- WhisperKit (Phase 3+): `onBufferCaptured` feeds `WhisperKitStreamingCoordinator`

The ONLY convergence node is `TranscriptPolisher.polish()` and the downstream store/clipboard path.

---

## WhisperKit Swimlane: Start Point

**Start trigger:** `HotkeyService` fires a `PipelineEvent` that `AppState` routes to the active pipeline's `handle(event:)` method.

**Routing:** `AppState.activePipeline: any DictationPipeline` returns `WhisperKitPipeline` when `ASRManager.activeBackendType == .whisperKit`.

**Event-driven entry (architectural decision — see below):**
```swift
appState.activePipeline.handle(event: .toggleRecording)
appState.activePipeline.handle(event: .preWarm)
appState.activePipeline.handle(event: .cancelRecording)
```

**First WhisperKit-owned component:** `WhisperKitPipeline.handle(event: .toggleRecording)` (Phase 1)

**Audio capture start:**
- `WhisperKitPipeline` calls `audioCapture.startCapture()` on the shared `AudioCaptureManager`
- Does NOT wire `onBufferCaptured` in Phases 0-2 (batch only)
- Wires `onBufferCaptured` → `WhisperKitStreamingCoordinator` in Phase 3
- PTT pre-warm: `audioCapture.preWarm()` called on `.preWarm` event (triggers BT codec switch)

**What enters the WhisperKit swimlane:**
- Raw `[Float]` audio samples at 16kHz mono (returned by `audioCapture.stopCapture()`)
- User-selected `TranscriptionOptions` (language, timestamps)
- `WhisperKitBackend` instance (model already loaded)

---

## WhisperKit Swimlane: End Point

**End of WhisperKit-exclusive processing:** `WhisperKitBackend.transcribe(audioSamples:)` returns `ASRResult`

**What the WhisperKit swimlane produces:**
```swift
ASRResult {
    let text: String            // trimmed, skipSpecialTokens=true
    let language: String?       // ISO 639-1 or nil
    let duration: TimeInterval  // audio duration in seconds
    let processingTime: TimeInterval
    let backendType: ASRBackendType  // .whisperKit
}
```

**What happens to it:** `ASRResult.text` is extracted and passed to `runTextProcessing(asrText:language:)`.

---

## Event-Driven Pipeline Interface

Both pipelines communicate with the outside world via a `PipelineEvent` enum. This replaces direct method calls scattered across `AppState` and `HotkeyService`, and prevents the boolean flag proliferation documented in Oracle's failure history.

```swift
enum PipelineEvent {
    case preWarm           // PTT key-down — pre-warm audio + model
    case toggleRecording   // PTT key-up toggle
    case requestStop       // PTT release in streaming/toggle mode
    case cancelRecording   // ESC or explicit cancel
    case reset             // Clear to idle
}
```

```swift
@MainActor
protocol DictationPipeline: AnyObject, Observable {
    var overlayIntent: OverlayIntent { get }
    func handle(event: PipelineEvent) async
}
```

**Why this matters (Oracle Anti-Pattern 2):** Direct method calls (`toggleRecording()`, `requestStop()`, `preWarmAudioInput()`) each need separate routing logic in `AppState` and `HotkeyService`. An event enum routes to a single `handle(event:)` entry point — the pipeline handles dispatch internally based on its current state. This eliminates the need for external callers to reason about pipeline state before calling a method.

**AppState routing (implementation):**
```swift
// HotkeyService fires events — AppState routes to active pipeline
func dispatch(_ event: PipelineEvent) async {
    await activePipeline.handle(event: event)
}
```

---

## Polish LLM Merge Point (The Only Convergence)

Both highways converge at the **text processing pipeline** after ASR completes.

**Merge contract (source-verified from LLMPolishStep.swift, LLMProtocol.swift):**

Input:
```swift
TextProcessingContext {
    var text: String              // ASR transcript — the primary input
    var originalASRText: String   // Unchanged copy of raw ASR output
    var language: String?         // ISO 639-1 language code (or nil)
    var polishedText: String?     // nil at input, set by LLMPolishStep
    var llmProvider: String?      // nil at input, set by LLMPolishStep
    var llmModel: String?         // nil at input, set by LLMPolishStep
}
```

Processing chain (identical for both highways):
```
WordCorrectionStep → FillerRemovalStep → LLMPolishStep
```

Output:
```swift
TextProcessingContext.text        // final text (polished if enabled, raw if not)
TextProcessingContext.polishedText // polished text or nil
TextProcessingContext.llmProvider  // provider name or nil
TextProcessingContext.llmModel     // model name or nil
```

**The merge contract requires only:**
1. A non-empty `String` of raw ASR text
2. An optional `String?` language code

There is no WhisperKit-specific metadata required at the merge point. Both highways produce the same `TextProcessingContext` shape.

**After merge:** Both highways produce a `Transcript` value type:
```swift
Transcript {
    text: String              // raw ASR text
    polishedText: String?     // nil or LLM result
    language: String?
    duration: TimeInterval
    processingTime: TimeInterval
    backendType: ASRBackendType   // .whisperKit or .parakeet (provenance preserved)
    llmProvider: String?
    llmModel: String?
    createdAt: Date
}
```

---

## What Is Explicitly Out of Scope

The following are NOT part of the WhisperKit highway and must not be built:

1. **Separate `AudioCaptureManager` instance** — WhisperKit highway uses the SHARED instance. No `WhisperKitAudioCapture` wrapper class. (Oracle Lesson 9, D1)
2. **Parakeet streaming infrastructure** — `StreamingAsrManager`, `feedAudio()` in streaming mode, `streamingASRActive` flag — none of these exist in the WhisperKit highway
3. **`SilenceDetector` shared instance** — WhisperKit highway creates its own `SilenceDetector` for auto-stop VAD monitoring. Silero VAD is used for real-time auto-stop on both highways (D13)
4. **Shared `TranscriptionPipeline` state** — `isStopping`, `stopRequested`, `targetApp` are per-pipeline
5. **LLM polish settings shared instance** — Each pipeline holds its own `LLMPolishStep` configured from the same `SettingsManager` (D12)
6. **Transcript history ownership** — `TranscriptStore` is shared infrastructure, append-only, UUID-keyed
7. **Backend-switching during active recording** — Gated by `state.isActive` check before `switchBackend()`

---

## Interface Contracts Between Components

### HotkeyService → AppState → Active Pipeline

```swift
// HotkeyService emits events
onPTTKeyDown: { await appState.dispatch(.preWarm) }
onPTTKeyUp:   { await appState.dispatch(.toggleRecording) }
onESC:        { await appState.dispatch(.cancelRecording) }

// AppState routes to active pipeline
func dispatch(_ event: PipelineEvent) async {
    await activePipeline.handle(event: event)
}
```

### AudioCaptureManager → WhisperKitPipeline (batch mode)

```swift
// No onBufferCaptured wiring in Phases 0-2
// Buffers accumulate in audioCapture.capturedSamples
let samples: [Float] = audioCapture.stopCapture()  // 16kHz mono Float32
```

### AudioCaptureManager → WhisperKitPipeline (Phase 3 streaming mode)

```swift
// onBufferCaptured feeds the streaming coordinator
audioCapture.onBufferCaptured = { [weak self] buffer in
    nonisolated(unsafe) let safeBuffer = buffer  // AVAudioPCMBuffer not Sendable
    Task { @MainActor in
        try? await self?.streamingCoordinator.feed(safeBuffer)
    }
}
```

### WhisperKitBackend → TextProcessingContext

```swift
let asrResult = try await whisperKitBackend.transcribe(audioSamples: samples, options: options)
// Creates: TextProcessingContext(text: asrResult.text, originalASRText: asrResult.text, language: asrResult.language)
```

### TextProcessingContext → TranscriptStore

```swift
let transcript = Transcript(
    text: context.text,
    polishedText: context.polishedText,
    language: result.language,
    duration: result.duration,
    processingTime: result.processingTime,
    backendType: result.backendType,  // always .whisperKit
    llmProvider: context.llmProvider,
    llmModel: context.llmModel
)
try transcriptStore.save(transcript)
```

---

## Shared Infrastructure

| Component | Ownership | Access Pattern |
|-----------|-----------|----------------|
| `AudioCaptureManager` | App-level (shared) | One active pipeline at a time; mode (batch/streaming) set at recording start |
| `SettingsManager` | App-level | Both pipelines read settings; no writes during recording |
| `TranscriptStore` | App-level | Both pipelines write transcripts; UUID-keyed, safe concurrent appends |
| `KeychainManager` | App-level | Read-only for API keys during polish |
| `MenuBarIconAnimator` | App-level | Driven by `activePipeline.overlayIntent` via `AppState` |
| `RecordingOverlayPanel` | App-level | Driven by `activePipeline.overlayIntent`; never sees `PipelineState` directly |
| `PasteService` | App-level | Called at end of each pipeline with no shared state |
| `AppLogger.shared` | App-level | Concurrent logging safe (actor) |

---

## Model Variant and Performance Contract

WhisperKit model selection directly determines the UX contract for the `.transcribing` phase duration:

| Variant | Size | Typical RTF (M1 Pro) | Batch duration (30s audio) | Recommended for |
|---------|------|---------------------|---------------------------|-----------------|
| `tiny.en` | 39MB | 0.08 | ~2.4s | Testing only |
| `base.en` | 74MB | 0.3–0.5 | ~9–15s | Fast machines |
| **`small.en`** | **244MB** | **0.5–0.8** | **~15–24s** | **Default** |
| `medium.en` | 769MB | 2–3 | ~60–90s | Accuracy priority |
| `large-v3` | 2.9GB | 5–10 | ~2.5–5 min | Not recommended for dictation |

**Default model: `small.en`.** The `large-v3` default in `WhisperKitSetupService.modelVariant` must be changed before any user-facing release.

**UX warning required in Settings UI for `large-v3`:** "Warning: large-v3 may take 2-5 minutes to transcribe a 30-second recording on this device."

**UX warning required in Settings UI for `medium.en`:** "medium may take 60-90 seconds to transcribe a 30-second recording."

The `.transcribing` overlay ("Transcribing...") will be visible for the full batch duration. This is expected and intentional (G10) — users must see something is happening, not a frozen app.
