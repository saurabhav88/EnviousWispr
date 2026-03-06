# Architect Research Notes — WhisperKit Highway

> Last updated: 2026-03-06
> Purpose: Persistent dump of findings from source code audit. Survives context compression.

---

## Source Files Read (8 Research Areas)

### 1. WhisperKit Engine Lifecycle
**File:** `Sources/EnviousWispr/ASR/WhisperKitBackend.swift`
- `actor WhisperKitBackend: ASRBackend` — fully isolated actor
- `prepare()`: checks `WhisperKitSetupService.getLocalModelPath()` first, falls back to `WhisperKit.download()`
- `WhisperKitConfig`: model name + modelFolder + computeOptions (hardcoded dictation options) + download: false
- Compute: melCompute=.cpuAndGPU, encoder=.cpuAndNeuralEngine, decoder=.cpuAndNeuralEngine, prefill=.cpuOnly
- `makeDecodeOptions()`: temperature=0.0, fallbackCount=3, compressionRatio=2.4, logProb=-1.0, noSpeech=0.6, skipSpecialTokens=true, suppressBlank=true, usePrefillPrompt=true, usePrefillCache=true
- `unload()`: whisperKit=nil, isReady=false
- `supportsStreaming`: NOT implemented, defaults to false (protocol default)
- NO temperature fallback retry implemented (just passes fallbackCount to WhisperKit internally)

**File:** `Sources/EnviousWispr/ASR/WhisperKitSetupService.swift`
- `@MainActor @Observable final class`
- Model path: `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/` (FIXED from wrong ~/Library/Caches path)
- States: .checking, .notDownloaded, .downloading(progress:, status:), .ready, .error(String)
- `isModelCached(variant:)` → `getLocalModelPath(variant:)` — static nonisolated methods
- `downloadModel()` uses detached Task + AsyncStream for progress relay (Swift 6 safe)
- Default modelVariant: "large-v3" — **MUST CHANGE TO "small.en"**

### 2. Recording Pipeline
**File:** `Sources/EnviousWispr/Audio/AudioCaptureManager.swift`
- `@MainActor @Observable final class` — shared instance between both highways
- Two-phase start: `startEnginePhase()` (engine + VP) then `beginCapturePhase()` (tap + capture)
- `capturedSamples: [Float]` accumulates 16kHz mono Float32
- `onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?` — nil for WhisperKit batch (Phases 0-2)
- `TapStoppedFlag`: `OSAllocatedUnfairLock<Bool>` — set BEFORE removeTap to prevent heap corruption
- `preWarm()`: starts engine phase only, waits for format stabilization
- `stopCapture() -> [Float]`: tears down tap, stops engine, returns capturedSamples
- `emergencyTeardown()`: calls `onPartialSamples?(partialSamples)` before clearing
- `onEngineInterrupted`: called after emergencyTeardown — pipeline wires this to cancel in-progress work
- Max recording: 600s / 10min cap
- Buffer size: 4096 frames

### 3. Transcription Pipeline (Parakeet's)
**File:** `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` (758 lines)
- `@MainActor @Observable final class`
- State enum `PipelineState`: .idle, .recording, .transcribing, .polishing, .complete, .error(String)
- `.transcribing` is OVERLOADED — used for model loading (line 134) AND actual ASR (line 338) — this is the bug
- 5 boolean flags: stopRequested, isStopping, streamingASRActive, isPreWarmed, (startRequestCancelled was added/reverted)
- `textProcessingSteps`: [wordCorrectionStep, fillerRemovalStep, llmPolishStep]
- `llmPolishStep.onWillProcess` → sets `state = .polishing` (callback fires inside LLMPolishStep.process())
- LLM pre-warm: `LLMNetworkSession.shared.preWarmIfConfigured()` at start of stopAndTranscribe() — overlaps TLS with ASR
- Streaming finalize: `withThrowingTaskGroup` races 10s timeout vs finalization
- `defer { isStopping = false }` reentrancy guard
- `defer { if !streamingSetupSucceeded { deactivateStreamingForwarding() } }` cleanup on all exit paths
- Short recording discard: < TimingConstants.minimumRecordingDuration

### 4. Polish LLM Merge Contract
**File:** `Sources/EnviousWispr/Pipeline/Steps/LLMPolishStep.swift`
**File:** `Sources/EnviousWispr/LLM/LLMProtocol.swift`
- Input: `TextProcessingContext { text, originalASRText, language?, polishedText?, llmProvider?, llmModel? }`
- Chain: WordCorrectionStep → FillerRemovalStep → LLMPolishStep
- `LLMPolishStep.onWillProcess` fires BEFORE the LLM call → pipeline transitions to .polishing
- `LLMPolishStep.onToken` = SSE streaming callback (no-op `{ _ in }` in Parakeet)
- Output: context with .polishedText, .llmProvider, .llmModel populated
- Merge contract requires only: non-empty String (ASR text) + String? (language)
- WhisperKit produces identical inputs — NO adaptation needed at merge point

### 5. Current State Machine (Parakeet's TranscriptionPipeline)
- Linear: idle → recording → transcribing → polishing → complete, any → error(String)
- `.transcribing` overloaded (model load at L134, ASR at L338) — bug that fails WhisperKit
- `onStateChange` callback → AppState → RecordingOverlayPanel + MenuBarIconAnimator
- Parakeet `.transcribing` is effectively invisible (streaming finalize = milliseconds)
- WhisperKit `.transcribing` must be VISIBLE ("Transcribing..." overlay, 1-5s)

### 6. UX Overlay
**File:** `Sources/EnviousWispr/Views/Overlay/RecordingOverlayPanel.swift`
- `@MainActor final class RecordingOverlayPanel`
- `generation: UInt64` counter for token-gating async show/hide
- `DispatchQueue.main.async` (NOT Task { @MainActor }) for panel creation — run-loop deferral required
- `CATransaction.flush()` BEFORE `close()` — prevents use-after-free in CA animations
- 3 visual states: recording (RainbowLipsIcon + timer), polishing (SpectrumWheelIcon + "Polishing..."), hidden
- `transitionToPolishing()`: closes recording panel → flush CA → create polishing panel next run-loop
- Key: overlay has NO knowledge of which backend is running — must stay that way (G5)

### 7. Observability
- `AppLogger.shared` actor — `log(_ message:, level:, category:)`
- Categories: "Pipeline", "PipelineTiming", "Audio", "VAD", "ASR", "LLM"
- `PipelineTiming` category tracks: model load, batch ASR duration, polish duration, paste duration
- WhisperKit highway should log batch ASR duration under "PipelineTiming"

### 8. Testing
- `wispr-run-smoke-test`: compile gate (no launch)
- `wispr-rebuild-and-relaunch`: mandatory after any code change
- `wispr-eyes "verify X"`: agent-native UI verification via AX APIs
- Definition of Done: swift build -c release exits 0 + build-tests exits 0 + rebuild + wispr-eyes VERIFIED

---

## Key Architecture Decisions (Final)

### DictationPipeline Protocol
```swift
@MainActor
protocol DictationPipeline: AnyObject, Observable {
    var overlayIntent: OverlayIntent { get }
    func handle(event: PipelineEvent) async
}

enum PipelineEvent { case preWarm, toggleRecording, requestStop, cancelRecording, reset }
enum OverlayIntent: Equatable {
    case hidden
    case recording(audioLevel: Float)
    case processing(label: String)  // "Loading model...", "Transcribing...", "Polishing..."
}
```

### WhisperKitPipelineState (8 states — includes ChatterBox .ready)
```swift
enum WhisperKitPipelineState {
    case idle             // Model unloaded
    case loadingModel     // G1: explicit state, not overloaded .transcribing
    case ready            // D16: model warm, awaiting PTT — ModelUnloadPolicy timer fires here → .idle
    case recording
    case transcribing     // G10: visible 1-5s batch ASR phase
    case polishing
    case complete
    case error(String)
}
```

### overlayIntent computed property mapping
- .idle, .ready, .complete → .hidden
- .loadingModel → .processing("Loading model...")
- .recording → .recording(audioLevel: audioCapture.audioLevel)
- .transcribing → .processing("Transcribing...")
- .polishing → .processing("Polishing...")
- .error → .hidden

### ChatterBox additions (2026-03-06, after external critique)
- .ready state: MANDATORY — without it, every PTT after idle timeout cold-loads model
- Backend switching drain protocol: stop → wait terminal state (5s timeout) → force-reset → switch → re-enable
- Language contract at LLM merge: ASRResult.language flows into TextProcessingContext.language → LLMPolishStep uses it
- Synchronous state transition to .transcribing before any async gap — no dead air (ChatterBox Item 8)
- After complete → .ready (model stays loaded), start ModelUnloadPolicy idle timer
- R9 (thread safety): all shared services @MainActor-isolated — structural safety
- R10 (zombie backend): drain timeout 5s, force-reset, log zombie events (D17)

### AudioCaptureManager: SHARED (not separate)
- Both highways use the same instance (Oracle Lesson 9, D1)
- WhisperKit batch: onBufferCaptured = nil (phases 0-2)
- WhisperKit streaming (phase 3): onBufferCaptured feeds WhisperKitStreamingCoordinator
- nonisolated(unsafe) let safeBuffer = buffer pattern required for AVAudioPCMBuffer

### Default Model: small.en (NOT large-v3)
- large-v3 RTF 5-10 = 2.5-5 min for 30s audio — unusable
- small.en RTF 0.5-0.8 = 15-24s for 30s audio — acceptable
- Change WhisperKitSetupService.modelVariant default

---

## File Targets Per Phase

### Phase 0
- NEW: `Sources/EnviousWispr/Pipeline/DictationPipeline.swift`
- MODIFY: `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` (add conformance)
- MODIFY: `Sources/EnviousWispr/App/AppState.swift` (activePipeline routing)
- MODIFY: `Sources/EnviousWispr/Views/Overlay/RecordingOverlayPanel.swift` (observe overlayIntent)

### Phase 1
- NEW: `Sources/EnviousWispr/Pipeline/WhisperKitPipeline.swift`
- MODIFY: `Sources/EnviousWispr/App/AppState.swift` (add whiskerKitPipeline, route .whisperKit)
- MODIFY: `Sources/EnviousWispr/Services/SettingsManager.swift` (model variant default: small.en)

### Phase 2
- MODIFY: `Sources/EnviousWispr/Pipeline/WhisperKitPipeline.swift` (EnergyVAD post-processing)
- MODIFY: `Sources/EnviousWispr/ASR/WhisperKitBackend.swift` (chunkingStrategy conditional)

### Phase 3
- NEW: `Sources/EnviousWispr/ASR/WhisperKitStreamingCoordinator.swift`
- MODIFY: `Sources/EnviousWispr/Pipeline/WhisperKitPipeline.swift` (streaming wiring)
- MODIFY: `Sources/EnviousWispr/Views/Overlay/RecordingOverlayPanel.swift` (partialText display)

### Phase 4
- MODIFY: `Sources/EnviousWispr/Pipeline/WhisperKitPipeline.swift` (polish metadata, unload policy)

---

## Parakeet Patterns to Replicate Exactly

From Oracle parakeet-success-patterns.md:

1. `isStopping` reentrancy guard with `defer { isStopping = false }`
2. `defer { if !captureStarted { cleanup() } }` on all exit paths in startRecording()
3. `onEngineInterrupted` wiring: cancel VAD, clear state, state = .error("Audio device disconnected")
4. `LLMNetworkSession.shared.preWarmIfConfigured()` at start of stopAndTranscribe() — overlaps TLS with ASR
5. `llmPolishStep.onWillProcess = { [weak self] in self?.state = .polishing }` — state driven by step callback
6. `SilenceDetector` monitor loop: spawn stopAndTranscribe in new Task (not current task, prevents CancellationError)
7. `SilenceDetector.reset()` before each recording session
8. `capturedSamples.reserveCapacity(16000 * 30)` at recording start
9. Short recording discard (< minimumRecordingDuration) with full cleanup
10. Empty ASR result → state = .error("No speech detected")
11. VAD fallback: if filtered samples < minimumSamples but raw >= minimumSamples, use raw

## Parakeet Patterns NOT Replicable (Batch Limitation)

1. Streaming ASR overlapping recording — batch must wait
2. Invisible .transcribing phase — must show "Transcribing..." for 1-5s
3. Model always pre-loaded — WhisperKit needs .loadingModel on cold start
4. stopRequested flag for PTT-during-start — replaced by explicit .loadingModel state

---

## Oracle Guardrails Quick Reference

| # | Rule | Enforced By |
|---|------|-------------|
| G1 | No overloaded state cases | WhisperKitPipelineState distinct cases |
| G2 | No boolean flag shadow states | isStopping only exception |
| G3 | Each backend → own pipeline class | DictationPipeline protocol |
| G4 | Shared infra backend-agnostic | AudioCaptureManager no if-whisperKit |
| G5 | Overlay via OverlayIntent not PipelineState | overlayIntent computed property |
| G6 | Model load doesn't block PTT cleanly | .loadingModel state + cancelRecording handler |
| G7 | Model path ~/Documents/huggingface/ | Already fixed in WhisperKitSetupService:50 |
| G8 | Hardcode decode defaults | Already done in WhisperKitBackend.makeDecodeOptions() |
| G9 | Preserve Parakeet's perfect flow | TranscriptionPipeline: 1-line conformance only |
| G10 | Batch ASR phase visibly distinct | .transcribing → .processing("Transcribing...") |
| G11 | Build on two kept commits | 9057484 (modularity) + 7aa2caa (defaults) |
| G12 | Tune before stream | Phase 2 (VAD) gates Phase 3 (streaming) |
| G13 | Test each pipeline in isolation | Wispr Eyes verifies each independently |
