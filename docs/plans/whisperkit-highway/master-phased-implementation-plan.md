# WhisperKit Highway — Master Phased Implementation Plan

> Author: Architect agent
> Date: 2026-03-06
> Status: FINAL v2 — incorporates Oracle guardrails G1-G13 + Parakeet success patterns + ChatterBox/GPT-4.1 review
> Basis: Full source code audit (all 8 research areas) + Oracle historical + Parakeet pattern findings + external LLM critique

---

## Foundational Principles

1. **Two separate highway classes.** `WhisperKitPipeline` and the existing `TranscriptionPipeline` (Parakeet) are siblings conforming to a shared `DictationPipeline` protocol. No shared state machine, no backend-conditional branching. (G3)

2. **Only one convergence point: Polish LLM.** Audio capture, VAD, transcription, and state management are WhisperKit-exclusive. The Polish LLM and its downstream (store, clipboard, paste) are shared. (G4)

3. **Preserve Parakeet's perfect flow.** Every line of `TranscriptionPipeline.swift` is preserved untouched except the `DictationPipeline` protocol conformance declaration. (G9)

4. **`AudioCaptureManager` stays shared — configurable, not branched.** It does not know which backend is calling it. No `if whisperKit` branches inside it. (G4)

5. **Overlay gets intent, not state.** `WhisperKitPipeline` emits `OverlayIntent` enum values (`.hidden`, `.recording(audioLevel:)`, `.processing(label:)`). The overlay never inspects `PipelineState` directly. (G5)

6. **Never overload state cases.** `WhisperKitPipelineState` has distinct cases for every phase including `.loadingModel`. No case serves double duty. (G1)

---

## Current State (Source-Verified + Oracle-Verified)

From `WhisperKitBackend.swift`, `ASRProtocol.swift`, `ASRManager.swift`, `TranscriptionPipeline.swift`, plus Oracle's historical analysis:

**What exists and works (two kept commits):**
- `WhisperKitBackend` actor: batch transcription, hardcoded Neural Engine compute options, dictation-optimized decode defaults. (G11)
- `WhisperKitSetupService`: correct model path at `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`, download with progress tracking. (G7, G11)
- `TranscriptionPipeline`: Parakeet-first, streaming-optimized. Works perfectly for Parakeet. (G9)

**What is broken (the problem Oracle confirmed):**
- WhisperKit runs through `TranscriptionPipeline` which was built for Parakeet's streaming model
- `.transcribing` is overloaded for both model loading and ASR (G1 violation — confirmed Failure 1)
- `stopRequested` race when PTT released during model load (G2 violation — confirmed Failure 2)
- Overlay does not show "Transcribing..." for the WhisperKit batch phase (G10 violation — confirmed Failure 3)
- No `DictationPipeline` protocol exists yet — routing is impossible without it

---

## Architecture First: `DictationPipeline` Protocol

Before any pipeline phase, establish the shared protocol that both highways conform to. This is the structural prerequisite for routing.

```swift
@MainActor
protocol DictationPipeline: AnyObject, Observable {
    // State (Observable property — drives overlay + menu bar)
    var overlayIntent: OverlayIntent { get }

    // Event-driven control — single entry point (Oracle Anti-Pattern 3 prevention)
    func handle(event: PipelineEvent) async
}

enum PipelineEvent {
    case preWarm           // PTT key-down: pre-warm audio + model
    case toggleRecording   // PTT key-up: start or stop
    case requestStop       // Explicit stop (toggle-mode key release)
    case cancelRecording   // ESC / explicit cancel
    case reset             // Clear to idle
}

enum OverlayIntent: Equatable {
    case hidden
    case recording(audioLevel: Float)
    case processing(label: String)   // "Loading model...", "Transcribing...", "Polishing..."
}
```

`AppState` holds an `activePipeline: any DictationPipeline` that routes all hotkey events. `MenuBarIconAnimator` and `RecordingOverlayPanel` observe `activePipeline.overlayIntent` — never the underlying `PipelineState`. The event-driven `handle(event:)` single entry point prevents the `if backend == .whisperKit` branches in `AppState` and `HotkeyService` that Oracle identified as Anti-Pattern 3.

---

## Backend Switching Drain Protocol

**Named concern (ChatterBox Item 3):** Backend switching during app lifetime (Parakeet ↔ WhisperKit via Settings) must follow an explicit drain sequence. It is not an afterthought.

**Drain sequence (enforced by AppState on `@MainActor`):**
1. Disable hotkey routing — `AppState` stops forwarding events to `activePipeline`
2. Request stop on current pipeline: `activePipeline.handle(event: .requestStop)` if recording, `.reset` if idle
3. Wait for current pipeline state to reach `.idle`, `.ready`, `.complete`, or `.error` — 5-second timeout
4. On timeout: `activePipeline.handle(event: .cancelRecording)` — force reset
5. Assert `audioCapture.isCapturing == false` (debug only)
6. Atomically switch `activePipeline` reference on `@MainActor`
7. Re-enable hotkey routing

**Single-active-backend invariant:** At no point during the switch can both pipelines be in a non-idle state. The `@MainActor` isolation of `AppState.activePipeline` makes the switch atomic — no concurrent access is possible.

**Backend switch during active recording:** Surface a "Stop recording before switching" alert. Do not auto-stop mid-recording. The user must finish first.

**Zombie backend risk (ChatterBox new risk):** A backend that fails to reach a terminal state within the timeout must be force-reset. Any shared resources it holds (`AudioCaptureManager`, `PasteService`) must be verified released before the new pipeline touches them. Log zombie events under `"Pipeline"` category.

---

## State Machine: `WhisperKitPipelineState`

This enum is purpose-built for WhisperKit's flow and must never be reused with Parakeet:

```swift
enum WhisperKitPipelineState {
    case idle                   // Model unloaded or not yet loaded
    case loadingModel           // On-demand model load during PTT — G1, G6
    case ready                  // Model warm, awaiting record command — D16
    case recording              // Microphone active
    case transcribing           // Batch ASR in progress — G10: visible phase
    case polishing              // LLM polish in progress
    case complete
    case error(String)
}
```

Every case has exactly one meaning. No flags substitute for missing states. (G1, G2)

**The `.ready` state (D16):** Model is loaded and warm, pipeline is idle. Without this state, every PTT press after idle timeout triggers a cold-start model load. With `.ready`, consecutive dictations have zero model load latency. Idle timeout transitions `.ready → .idle` (model unloaded), not `.recording → .idle` directly. The `ModelUnloadPolicy` timer fires from `.ready`, not from active states.

---

## Phased Plan

### Phase 0: Foundation Protocol and Smoke Gate

**Objective:** Establish `DictationPipeline` protocol + `OverlayIntent` enum. Extract `ParakeetPipeline` from existing `TranscriptionPipeline` as a protocol conformance declaration only. Verify WhisperKit batch works today.

**What gets built:**
- `DictationPipeline` protocol at `Sources/EnviousWispr/Pipeline/DictationPipeline.swift`
- `OverlayIntent` enum in the same file
- `TranscriptionPipeline` gains `DictationPipeline` conformance with `overlayIntent` computed property (maps existing `PipelineState` to `OverlayIntent`)
- `AppState` routing: `activePipeline: any DictationPipeline` backed by `TranscriptionPipeline` for now
- `RecordingOverlayPanel` updated to observe `activePipeline.overlayIntent` instead of `pipeline.state` directly
- Smoke test: select WhisperKit in Settings → Speech Engine → record → verify transcript

**What does NOT get built:**
- No `WhisperKitPipeline` yet
- No routing logic for WhisperKit
- No state machine changes to `TranscriptionPipeline`

**Guardrails addressed:** G3 (protocol groundwork), G5 (OverlayIntent introduced), G9 (TranscriptionPipeline unchanged except conformance)

**Dependencies:** None.

**Risks:**
- `TranscriptionPipeline`'s `PipelineState` → `OverlayIntent` mapping must be lossless for Parakeet. The overlay currently observes `PipelineState` in `AppDelegate`. The mapping must produce identical behavior.
- `RecordingOverlayPanel` changes touch the overlay generation counter — use the same `DispatchQueue.main.async` pattern, not `Task { @MainActor }` (gotchas.md).

**Observability:** None new — Parakeet path behavior is identical.

**UX:** Zero visible change for users on either backend.

**Test strategy:**
- Wispr Eyes: Parakeet recording flow — VERIFIED with zero regression
- `swift build -c release` green
- `swift build --build-tests` green

**Exit criteria:**
- `DictationPipeline` protocol exists and `TranscriptionPipeline` conforms
- Overlay behavior is identical to pre-Phase 0 for Parakeet
- Parakeet end-to-end: VERIFIED
- **Compilation isolation gate (G13 early check):** `TranscriptionPipeline.swift` must compile cleanly with zero imports from any WhisperKit-specific file. This gates entry to Phase 1.

**Phase ordering note (ChatterBox Item 5 / G9):** Phase 0 extracts `ParakeetPipeline` as a zero-diff conformance declaration. Phase 1 builds `WhisperKitPipeline` separately. This sequencing is mandatory — never modify Parakeet's behavior while adding WhisperKit.

**Rollback:** Revert `TranscriptionPipeline` conformance declaration (1-line change). `DictationPipeline.swift` is additive — delete the file.

---

### Phase 1: WhisperKitPipeline — Independent State Machine (Batch)

**Objective:** Create `WhisperKitPipeline` implementing `DictationPipeline`. Full batch transcription flow with proper `WhisperKitPipelineState` including `.loadingModel` as a first-class state.

**What gets built:**
- `WhisperKitPipeline` class at `Sources/EnviousWispr/Pipeline/WhisperKitPipeline.swift`
  - `@MainActor @Observable` conforming to `DictationPipeline`
  - State machine: `idle → loadingModel → recording → transcribing → polishing → complete` (G1, G6, G10)
  - Uses `AudioCaptureManager` shared instance — batch capture mode only (no `onBufferCaptured` wiring) (G4)
  - `WhisperKitPipelineState` enum — see above
  - `overlayIntent` computed property: maps state to `OverlayIntent` correctly:
    - `.idle`, `.ready`, `.complete`: → `.hidden`
    - `.loadingModel`: → `.processing(label: "Loading model...")`
    - `.recording`: → `.recording(audioLevel: audioCapture.audioLevel)`
    - `.transcribing`: → `.processing(label: "Transcribing...")` (G10)
    - `.polishing`: → `.processing(label: "Polishing...")`
    - `.error`: → `.hidden`
  - `startRecording()` flow:
    1. If model not loaded (state == .idle): `state = .loadingModel` → await `whisperKitBackend.prepare()` → (user can cancel here cleanly) → `state = .ready`
    2. If model already loaded (state == .ready): proceed immediately — zero latency
    3. Cancel `ModelUnloadPolicy` idle timer on entry (model is needed now)
    4. Capture `targetApp` and `targetElement` for paste
    5. `state = .recording` → `audioCapture.startCapture()` (or `beginCapturePhase()` if pre-warmed)
    6. Start VAD monitor if `vadAutoStop` enabled
  - `stopAndTranscribe()` flow:
    1. Stop capture: `let rawSamples = audioCapture.stopCapture()`
    2. Start LLM network pre-warm immediately (fire-and-forget): `LLMNetworkSession.shared.preWarmIfConfigured(...)` — overlaps TLS/HTTP2 handshake with batch ASR (pattern from Parakeet, line 293)
    3. VAD-filter samples: `SilenceDetector.finalizeSegments()` + `filterSamples(from:)` — same as Parakeet
    4. **Synchronously** `state = .transcribing` before any async gap — overlay must not have dead air (ChatterBox Item 8)
    5. `await whisperKitBackend.transcribe(audioSamples:)` (G10) — returns `ASRResult` with `.language` field
    6. Text processing: `context = try await runTextProcessing(asrText: asrResult.text, language: asrResult.language)` — language flows through to LLM polish (ChatterBox Item 7)
    7. `LLMPolishStep.onWillProcess` fires here → `state = .polishing` (same `onWillProcess` callback pattern from Parakeet)
    8. `state = .complete` → save transcript, clipboard, paste
    9. `state = .ready` (not `.idle`) — model stays loaded; start `ModelUnloadPolicy` idle timer
  - PTT cancel during `.loadingModel`: `handle(event: .cancelRecording)` cancels the load task → `state = .idle` — no `stopRequested` flag needed (G2, G6)
  - `isStopping` reentrancy guard only (G2 exception: reentrancy guard is acceptable)
  - `defer` cleanup pattern: `defer { if !captureStarted { audioCapture.onBufferCaptured = nil } }` on all early-exit paths in `startRecording()` — replicates Parakeet's `defer { if !streamingSetupSucceeded { deactivateStreamingForwarding() } }` pattern
- `AppState` routing: `activePipeline` switches based on `asrManager.activeBackendType`
  - `.parakeet` → `TranscriptionPipeline`
  - `.whisperKit` → `WhisperKitPipeline`
- `HotkeyService.onToggleRecording` calls `appState.activePipeline.toggleRecording()`

**What does NOT get built:**
- No streaming wiring (deferred to Phase 3)
- No WhisperKit-native VAD (deferred to Phase 2)
- No partial transcript display (deferred to Phase 3)

**Guardrails addressed:** G1 (WhisperKitPipelineState), G2 (no flags for states), G3 (separate pipeline class), G5 (OverlayIntent), G6 (.loadingModel state), G9 (TranscriptionPipeline untouched), G10 (.transcribing overlay), G13 (independently testable)

**Key implementation notes:**

The `AudioCaptureManager` is shared. `WhisperKitPipeline` uses it in batch mode:
- Do NOT wire `onBufferCaptured` — no streaming callbacks
- `startCapture()` → accumulates `capturedSamples` → `stopCapture()` returns `[Float]`
- PTT pre-warm: `audioCapture.preWarm()` on key-down (same BT codec switch benefit)

Model load during PTT flow:
```
[key-down fires]
→ preWarmAudioInput(): audioCapture.preWarm() + if !isModelLoaded: await whisperKitBackend.prepare()
[user speaks]
[key-up fires]
→ requestStop() → stopAndTranscribe()
```
By pre-warming both audio AND model on key-down, the `.loadingModel` state is ideally invisible to the user on subsequent recordings after the first cold start.

**Risks:**
- Shared `AudioCaptureManager` between two pipelines: only one pipeline can be capturing at a time. Gate on `audioCapture.isCapturing` being false before starting. Assert in debug: `assert(!audioCapture.isCapturing)`.
- `LLMPolishStep` shared vs per-pipeline: `WhisperKitPipeline` creates its own `LLMPolishStep` instance, configured from `SettingsManager` observation. (Oracle finding: no shared state between pipelines.)
- First cold start: model load takes 2-5s. User must see `.loadingModel` overlay ("Loading model..."), not a frozen app.

**Observability:**
- Log `"WhisperKit pipeline: state → X"` under `"Pipeline"` category at each transition
- Log model load timing: `"WhisperKit model loaded in Xs"` under `"PipelineTiming"`
- Log batch transcription timing: `"WhisperKit batch ASR: Xs (N samples)"` under `"PipelineTiming"`

**UX:**
- First cold start: "Loading model..." overlay appears, then transitions to recording lips when model is ready
- After first load: pre-warm on key-down makes model load invisible (model stays loaded per `ModelUnloadPolicy`)
- Batch transcription: "Transcribing..." overlay for 1-5s — users understand something is happening (G10)

**Test strategy:**
- Wispr Eyes: WhisperKit cold start → "Loading model..." appears → transitions to recording → transcript appears
- Wispr Eyes: PTT cancel during model load → state returns to idle cleanly, no race
- Wispr Eyes: back-to-back recordings — no model reload (stays loaded per policy)
- Parakeet regression: full Wispr Eyes verification — VERIFIED

**Exit criteria:**
- Full WhisperKit flow: PTT → (model load if needed) → record → transcribe → polish → clipboard
- `.loadingModel` overlay visible on cold start
- `.transcribing` overlay visible during batch ASR phase
- PTT cancel during model load: clean idle state, no crash
- Parakeet path: zero regression
- `swift build -c release` green
- Wispr Eyes: VERIFIED for both pipelines

**Rollback:**
- Remove `WhisperKitPipeline.swift` (additive)
- Revert `AppState` routing (trivial — switch back to `TranscriptionPipeline` for all backends)
- `DictationPipeline.swift` remains (Phase 0 artifact, harmless)

---

### Phase 2: WhisperKit-Native VAD Integration

**Objective:** Improve WhisperKit output quality by adding EnergyVAD post-processing and `chunkingStrategy: .vad` for long recordings. Eliminate hallucination on silence.

**What gets built:**
- In `WhisperKitPipeline.stopAndTranscribe()`: post-capture EnergyVAD pass to filter silence before batch transcription
  - After `audioCapture.stopCapture()` returns `[Float]`, apply energy filtering
  - Same minimum sample count logic as existing `TranscriptionPipeline` (1 second minimum, silence padding)
- `WhisperKitBackend.makeDecodeOptions()` updated with conditional `chunkingStrategy`:
  - `samples.count < 16000 * 30`: `.none` (short recordings, direct decode)
  - `samples.count >= 16000 * 30`: `.vad` (30+ seconds, chunk by VAD to prevent hallucination)
- VAD auto-stop (user-facing feature): `WhisperKitPipeline` starts a `SilenceDetector` monitor loop during `.recording` phase — identical to `TranscriptionPipeline.startVADMonitoring()`. Silero VAD remains the real-time auto-stop mechanism.

**What does NOT get built:**
- No changes to Parakeet highway
- No streaming VAD

**Guardrails addressed:** G8 (hardcoded decode, VAD is quality, not tuning knob), G12 (tune before stream)

**Key note:**
`SilenceDetector` (Silero VAD) is used for real-time auto-stop monitoring. EnergyVAD is applied post-capture for quality. Two separate concerns, same recording session. `SilenceDetector.reset()` must be called before each new recording session (gotchas.md: VadStreamState persists across chunks).

**Risks:**
- `chunkingStrategy: .vad` may alter transcription of boundary words between chunks. Test with 45-second recordings with natural speech pauses.
- Energy threshold `0.02` may be too aggressive in quiet environments. Log filtered sample count for tuning.

**Observability:**
- Log `"WhisperKit VAD: removed Xs silence (Y% voiced)"` under `"VAD"`
- Log `"WhisperKit: chunkingStrategy=.vad (Xs audio)"` when triggered

**Test strategy:**
- 45-second recording with 10 seconds of silence: verify no hallucinated repetitions
- 5-second short recording: verify no over-filtering
- `swift build -c release` green

**Exit criteria:**
- Long recordings (>30s) produce clean output with no repetition hallucinations
- Short recordings (<10s) are unaffected by chunkingStrategy change
- Wispr Eyes: VERIFIED

**Rollback:** Remove EnergyVAD call from `stopAndTranscribe()`. Revert `chunkingStrategy` to `.none` in `makeDecodeOptions()`. Both are 1-3 line changes.

---

### Phase 3: Streaming via AudioStreamTranscriber

**Objective:** Add streaming transcription to `WhisperKitPipeline` using WhisperKit's `AudioStreamTranscriber`. Provides live partial transcripts and reduces perceived latency.

**Prerequisite (G12):** Phases 0-2 complete. Batch transcription quality verified across short, medium, and long recordings.

**What gets built:**
- `WhisperKitStreamingCoordinator` actor at `Sources/EnviousWispr/ASR/WhisperKitStreamingCoordinator.swift`
  - Wraps `AudioStreamTranscriber`
  - `start()`, `feed(_ buffer: AVAudioPCMBuffer)`, `finalize() -> String`, `cancel()`
  - `isStreaming` guard: at most one call to `finalize()` or `cancel()` per session (gotchas.md: Streaming ASR Must End Exactly Once)
  - Reports `confirmedSegments` + `unconfirmedSegments` via callback for live UI
- `WhisperKitPipeline` gains streaming mode alongside batch fallback:
  - `startRecording()`: creates `WhisperKitStreamingCoordinator`, begins feeding buffers via `audioCapture.onBufferCaptured`
  - `stopAndTranscribe()`: calls `finalize()` with 10-second timeout (same `withThrowingTaskGroup` race pattern as `TranscriptionPipeline.finalizeStreamingWithTimeout`)
  - Timeout or streaming error: falls back to batch on already-captured `capturedSamples`
- `WhisperKitBackend.supportsStreaming` returns `true` after coordinator is wired
- Buffer forwarding: `nonisolated(unsafe) let safeBuffer = buffer` pattern required (gotchas.md: AVAudioPCMBuffer not Sendable)
- `partialTranscript: String` published by `WhisperKitPipeline` for overlay display

**What does NOT get built:**
- No word-by-word live display (WhisperKit chunks ~1s, not per-word)
- Partial transcript overlay update is in this phase (see OverlayIntent below)

**Guardrails addressed:** G12 (batch verified before streaming), G2 (no flags — `isStreaming` is an actor state, not a shadow flag)

**Key prerequisite:** Read `.build/checkouts/WhisperKit/Sources/WhisperKit/Core/AudioStreamTranscriber.swift` before writing a single line. Do not assume API from documentation. (Confirmed risk R3 from original plan.)

**OverlayIntent update:**
```swift
case recording(audioLevel: Float, partialText: String?)
```
`RecordingOverlayPanel` shows `partialText` (confirmed segments, last 60 chars) when non-nil, at reduced opacity for unconfirmed.

**Risks:**
- `AudioStreamTranscriber` may not accept buffers in the same format as `feedAudio(_ buffer:)` in `ASRBackend` protocol. Verify sample rate and channel format expectations.
- ~1s chunk latency means first confirmed segment appears after ~2s of speech. Set user expectations in documentation.
- Device disconnect during streaming: `onEngineInterrupted` callback must call `coordinator.cancel()` before teardown. Use `defer` pattern.

**Observability:**
- Log `"WhisperKit streaming: started"`, `"confirmed N segments (Xchars)"`, `"finalized"`, `"cancelled"`, `"timeout → batch fallback"` under `"Pipeline"`

**Test strategy:**
- 3s recording with streaming: verify result matches batch within ±5% WER
- 60s recording with streaming: verify batch fallback not triggered
- Disconnect device during streaming: verify clean cancellation, no double-finalize
- Wispr Eyes: partial text appears in overlay within 2s of recording start

**Exit criteria:**
- Streaming produces transcripts equivalent to batch
- Timeout fallback triggers correctly
- Device disconnect: clean state
- Partial text visible in overlay
- Wispr Eyes: VERIFIED

**Rollback:** Set `WhisperKitBackend.supportsStreaming = false`. Pipeline falls back to batch. `WhisperKitStreamingCoordinator` is inert when not called.

---

### Phase 4: Polish Convergence Hardening

**Objective:** Verify and harden the handoff from WhisperKit highway to the shared Polish LLM layer. Ensure all providers work, metadata propagates correctly, and error handling is consistent.

**What gets built:**
- End-to-end test coverage: WhisperKit → transcribe → polish via each of the 5 LLM providers (OpenAI, Gemini, Ollama, Apple Intelligence, none)
- `Transcript.backendType` correctly set to `.whisperKit` in all code paths
- `lastPolishError` surface in UI (same as `TranscriptionPipeline.lastPolishError`)
- Model unload policy wired to `WhisperKitPipeline.noteTranscriptionComplete(policy:)` via `ASRManager` — fires idle timer, transitions `.complete → .ready`
- **Language contract at LLM merge point (ChatterBox Item 7):** `TextProcessingContext.language` is populated from `ASRResult.language` (WhisperKit returns the detected/forced language code). `LLMPolishStep` must use this to inject language context into its polish prompt: `"Polish the following {language} transcript..."`. This is a contract change at the shared merge point — both Parakeet (English-only, passes `"en"`) and WhisperKit (passes actual language code) feed into the same step. Scoped into this phase, not optional.

**What does NOT get built:**
- No new LLM connectors
- No new settings

**Exit criteria:**
- All 5 LLM providers produce polished transcripts via WhisperKit highway
- History view shows correct backend and LLM provider metadata for WhisperKit recordings
- `swift build -c release` green
- Wispr Eyes: VERIFIED

---

## Parakeet Patterns Adopted (from Oracle parakeet-success-patterns.md)

The following patterns from `TranscriptionPipeline` are replicated exactly in `WhisperKitPipeline`:

| Pattern | Source in TranscriptionPipeline | How WhisperKit adopts it |
|---------|--------------------------------|--------------------------|
| `isStopping` reentrancy guard | line 56, 253-255 | Same pattern; `defer { isStopping = false }` |
| `defer` for cleanup on all exit paths | line 151 | `defer { if !captureStarted { cleanup() } }` in `startRecording()` |
| `onEngineInterrupted` device disconnect handler | line 79-93 | Identical wiring: cancel VAD, clear state, `state = .error(...)` |
| LLM pre-warm during ASR | line 293 | `LLMNetworkSession.shared.preWarmIfConfigured(...)` fires at start of `stopAndTranscribe()` |
| `LLMPolishStep.onWillProcess` callback | line 73-75 | `llmPolishStep.onWillProcess = { [weak self] in self?.state = .polishing }` |
| `SilenceDetector` auto-stop loop | lines 648-711 | Identical `monitorVAD()` loop; `stopAndTranscribe()` spawned in new Task |
| `SilenceDetector.reset()` before each session | VAD monitor setup | Called at start of each `startRecording()` call |
| `CATransaction.flush()` before panel close | RecordingOverlayPanel | Handled by `RecordingOverlayPanel` — no change needed |
| `DispatchQueue.main.async` for panel creation | RecordingOverlayPanel | Handled by `RecordingOverlayPanel` — no change needed |
| Short recording discard | line 260-277 | Same minimum duration check before `stopAndTranscribe()` |
| Empty ASR result → `.error(...)` | line 370-376 | Same guard: `guard !asrText.isEmpty else { state = .error(...) }` |

The following patterns are adapted for batch mode (cannot replicate exactly):

| Pattern | Parakeet behavior | WhisperKit adaptation |
|---------|------------------|----------------------|
| Streaming ASR overlaps recording | `onBufferCaptured` → `feedAudio()` during capture | No overlap; batch ASR runs after recording stops |
| Invisible `.transcribing` phase | Finalize takes <100ms; user never sees it | Visible `.transcribing` overlay (1-5s); must show "Transcribing..." (G10) |
| Model always loaded | FluidAudio loads on launch | On-demand load; `.loadingModel` state on cold start (G6) |
| `stopRequested` flag for PTT-during-start | Boolean flag | Replaced by `.loadingModel` explicit state + `cancelRecording()` handler (G1, G2) |

---

## Model Variant Default and UX Warnings

**Default model: `small.en`** — Change `WhisperKitSetupService.modelVariant` default from `"large-v3"` to `"small.en"`.

**Required UX warnings in Settings → Speech Engine:**

```
small.en (Recommended) — Typical: 15-24s to transcribe a 30s recording
medium.en — Typical: 60-90s to transcribe a 30s recording. Slower but more accurate.
large-v3 ⚠️ — Typical: 2-5 minutes to transcribe a 30s recording. Not recommended for
              real-time dictation. Use for post-processing long recordings where
              maximum accuracy matters more than speed.
```

The `.transcribing` overlay duration is directly tied to the chosen model. Users who understand the tradeoff can choose `large-v3`; the default should never expose casual users to a 5-minute wait for a 30-second dictation.

---

## Language Selection (EN / DE / TA)

WhisperKit's value proposition is multilingual support. The project targets **three languages**: English, German, Tamil.

### Supported Languages

| Language | ISO 639-1 | Model Variant | Notes |
|----------|-----------|---------------|-------|
| English | `en` | `small.en` (English-optimized) | Default. Best accuracy + speed for English. |
| German | `de` | `small` (multilingual) | Requires multilingual model. |
| Tamil | `ta` | `small` (multilingual) | Requires multilingual model. Lower resource language — auto-detect may underperform. |

**NOT supported initially:** WhisperKit supports 99 languages, but the Settings UI exposes only EN/DE/TA. Expanding later is trivial.

### UX: Manual Selection, Not Auto-Detect

**Decision: Manual language selection** via a picker in Settings → Speech Engine (WhisperKit section).

**Rationale:**
- Auto-detect hurts accuracy for underrepresented languages (Tamil)
- Auto-detect adds latency (language identification pass before transcription)
- Users know what language they're about to speak
- WhisperKit's `language` parameter in `DecodingOptions` accepts an ISO 639-1 code; passing `nil` triggers auto-detect which is unreliable for short utterances

**Default:** English (`en`). User can switch to German or Tamil in Settings.

### Model Variant Auto-Switching

When the user selects a language, the model variant must switch automatically:

```
if language == "en" {
    modelVariant = "small.en"    // English-optimized, faster
} else {
    modelVariant = "small"       // Multilingual, supports DE + TA
}
```

This triggers a model re-download and reload if switching between `.en` and multilingual variants. The UX must:
1. Show a progress indicator during model download (first time only)
2. Show `.loadingModel` overlay state during model reload
3. Persist the choice so switching is a one-time cost

### LLM Polish Language Awareness (ties to ew-9bd)

`LLMPolishStep` currently ignores `context.language`. For German and Tamil:
- Polish prompts must include language context: `"Polish the following {language} transcript..."`
- For Tamil, the LLM may have weaker polish capabilities — consider lighter-touch prompt
- Scoped into Phase 4 (Polish Convergence Hardening) as mandatory

### Phase Integration

| Phase | Language Work |
|-------|-------------|
| Phase 1 | Language picker in Settings UI, `DecodingOptions.language` wired |
| Phase 1 | Model variant auto-switching logic |
| Phase 2 | Verify VAD + quality across all 3 languages |
| Phase 3 | Verify streaming works with multilingual model |
| Phase 4 | LLM polish language awareness (ew-9bd fix) |

---

## Definition of Done (Full Highway)

1. `swift build -c release` exits 0
2. `swift build --build-tests` exits 0
3. `.app` bundle rebuilt + relaunched via `wispr-rebuild-and-relaunch`
4. Wispr Eyes: VERIFIED for all phases
5. Parakeet highway: zero regression (G9)
6. Oracle guardrails G1-G13: all satisfied
7. Long recording (>30s): no hallucinated repetitions (Phase 2)
8. First cold start: `.loadingModel` overlay visible (Phase 1, G6)
9. Batch ASR phase: `"Transcribing..."` overlay visible (Phase 1, G10)
10. PTT cancel during model load: clean idle, no race (Phase 1, G6)
11. Streaming + batch fallback both functional (Phase 3, G12)
12. All 6 LLM providers: polish completes correctly via WhisperKit highway (Phase 4)

---

## Oracle Guardrail Compliance Matrix

| Guardrail | Phase | How Addressed |
|-----------|-------|---------------|
| G1: No overloaded state cases | 1 | `WhisperKitPipelineState` has distinct `.loadingModel`, `.ready`, `.recording`, `.transcribing`, `.polishing` |
| G2: No boolean flag shadow state machines | 1 | PTT cancel during load handled by explicit `.loadingModel` state, not `stopRequested` flag |
| G3: Each backend gets its own pipeline class | 0-1 | `DictationPipeline` protocol; `WhisperKitPipeline` is new class; `TranscriptionPipeline` unchanged |
| G4: Shared infrastructure is backend-agnostic | 0-4 | `AudioCaptureManager`, overlay, paste, store — no `if whisperKit` branches added |
| G5: Overlay via OverlayIntent not PipelineState | 0 | `OverlayIntent` enum introduced in Phase 0; overlay observes only intent |
| G6: Model load does not block PTT cleanly | 1 | `.loadingModel` state; pre-warm on key-down; cancel during load → clean idle |
| G7: Model path ~/Documents/huggingface/ | Already fixed | `WhisperKitSetupService.swift:50` already correct |
| G8: Hardcode decode defaults | Already done | `WhisperKitBackend.makeDecodeOptions()` already hardcoded |
| G9: Preserve Parakeet's perfect flow | 0-4 | `TranscriptionPipeline` untouched except 1-line protocol conformance |
| G10: Batch ASR phase visibly distinct | 1 | `.transcribing` → `OverlayIntent.processing(label: "Transcribing...")` |
| G11: Build on the two kept commits | All | Plan starts from `9057484` + `7aa2caa` — no rework of decode defaults or setup service |
| G12: Tune before stream | 2-3 | Phase 2 (VAD + quality) must complete before Phase 3 (streaming) |
| G13: Test each pipeline in isolation | 0-1 | Each pipeline end-to-end testable without the other; Wispr Eyes verifies independently |
