# External Feedback Digest

**Compiled by:** ChatterBox
**Date:** 2026-03-06
**Sources:** GPT-4.1 (architecture, state machine, UX consultations), Gemini 2.5 Flash (architecture + UX parity follow-up), plus prior session history (whisperkit-architecture-debate, whisperkit-tuning-research, whisperkit-ux-parity)

---

## Topic 1: Two-Highway Architecture Validation

### GPT-4.1 Assessment
GPT-4.1 validated the two-highway approach as sound, with four key risk areas:

1. **State Divergence & UI Consistency** — If both highways could be "active" simultaneously, the UI becomes incoherent. Enforce single-active-backend at all times.

2. **Resource Contention on Audio Input** — AudioCaptureManager must enforce single-ownership semantics. Never let both backends read from the mic concurrently.

3. **Drift in Audio State** — Switching backends mid-session can leave stale buffers, orphaned threads, or memory leaks. Explicit drain/teardown is mandatory before switching.

4. **Merge-Point Data Mismatch** — The LLM polish stage might receive transcripts in different formats, with different segmentation or timing metadata. A shared, backend-agnostic Transcript struct is essential.

### Gemini 2.5 Flash (partial response before 503)
Flagged resource duplication/contention as the top risk, aligning with GPT-4.1.

### Cross-Reference with Oracle
GPT-4.1's risks align perfectly with Oracle's findings. The Oracle's Guardrail G4 (shared infrastructure must be backend-agnostic) and G5 (overlay via intent, not state) directly address risks #1 and #4.

---

## Topic 2: State Machine Design for Batch Pipeline

### GPT-4.1 Recommended States
Nine states for the WhisperKit pipeline:

1. **Idle** (model possibly unloaded)
2. **ModelLoading** (loading CoreML models)
3. **ModelWarming** (specializing models on hardware)
4. **Ready** (model warm, awaiting record command)
5. **Recording** (capturing audio via AVAudioEngine)
6. **Transcribing** (CoreML batch decode)
7. **Polishing** (optional LLM polish)
8. **Delivering** (clipboard + paste)
9. **Error** (any failure, reset to Idle)

### Key Design Principles
- **Cancellation at every state** with explicit cleanup semantics per state
- **Idle timeout only fires in Idle or Ready** — never during active pipeline
- **ModelLoading and ModelWarming are separate** from Transcribing (directly addresses Oracle's Failure 1)
- **Ready state** acts as a warm checkpoint — prevents model reload on consecutive dictations

### Cross-Reference with Oracle
This design directly solves every anti-pattern in the Oracle's catalog:
- AP1 (overloaded states): ModelLoading, ModelWarming, Transcribing are all separate
- AP2 (boolean flags): All phases are explicit states
- G6 (model load must not block PTT): ModelLoading is a first-class state with cancel support

---

## Topic 3: UX for Mixed Streaming/Batch Experience

### GPT-4.1 Recommendations

**During Recording:**
- Parakeet: Show live text streaming + waveform
- WhisperKit: Show "Recording... Speak now." with animated waveform/mic, NO blank text area

**After Recording Stops:**
- Parakeet: Text appears instantly
- WhisperKit: Immediately transition to "Transcribing..." with spinner/progress

**Progress Indicator:** Start with indeterminate spinner. Add estimated time if transcription exceeds 3 seconds.

**Anti-Patterns to Avoid:**
1. Don't show an empty text area for batch mode (feels broken)
2. Don't reuse streaming UI patterns where they don't fit
3. Don't hide which engine is active — be transparent
4. Both engines must start/stop with the same hotkey behavior
5. No ambiguous "dead" states — always show active feedback

### Cross-Reference with Oracle
The UX recommendations directly map to Oracle's guardrails:
- G5 (overlay via intent): Backend-specific overlay content through a shared intent enum
- G10 (batch ASR visibly distinct): "Transcribing..." as a separate overlay state

---

## Topic 4: Backend Switching Protocol

### GPT-4.1 Recommended Sequence
1. User requests backend switch (in Settings)
2. UI disables recording controls
3. Current backend receives `.stopRecordingAndFinalize()` or equivalent
4. Wait for state machine to reach `.complete` or `.cancelled` (with timeout)
5. Release audio input
6. Initialize new backend, update UI, re-enable controls

**Key Rule:** Never allow both backends to be "active" or "recording" at once. Suggested a `TranscriptionCoordinator` singleton to enforce global exclusivity.

### Cross-Reference with Oracle
Oracle's Guardrail G4 already anticipates this — shared infrastructure is backend-agnostic, so switching backends is a coordinator-level concern, not an infrastructure concern.

---

## Topic 5: Interface Contracts at Merge Point

### GPT-4.1 Contract Requirements for TranscriptPolisher
The LLM polish stage must accept a backend-agnostic input with:
- Canonicalized text (String)
- Language code (critical for WhisperKit multilingual)
- Confidence metadata (optional)
- Timestamps (optional)

The TranscriptPolisher protocol should be **stateless or idempotent** per call. Must handle both streaming Parakeet output (may be incremental) and batch WhisperKit output (complete transcript).

Error contracts must define behavior for:
- Incomplete inputs
- Unsupported languages
- LLM timeout/failure

---

## Topic 6: Event-Driven Pipeline Design (Follow-Up Consultation)

### Gemini 2.5 Flash — Concrete Implementation Pattern

In a follow-up consultation about the Architect's specific plan, Gemini proposed an **event-driven state machine** that eliminates boolean flags entirely:

```swift
enum PipelineEvent {
    case pttDown
    case pttUp
    case modelFinishedLoading
    case asrFinishedTranscription
}

func handle(event: PipelineEvent) {
    switch (state, event) {
    case (.idle, .pttDown):
        state = .loadingModel
    case (.loadingModel, .modelFinishedLoading):
        state = .recording
    case (.loadingModel, .pttUp):
        state = .idle  // Cancel during model load
    case (.recording, .pttUp):
        state = .transcribing
    default:
        break  // Ignore invalid combinations
    }
}
```

**Key insight:** State transitions are atomic and driven by a single entry point. It is impossible to create a race condition because the `(state, event)` tuple fully determines the next state. No boolean flags needed.

### Gemini 2.5 Flash — OverlayState as Computed Property

Gemini also proposed that the overlay state should be a **computed property** on the pipeline, not a callback:

```swift
public var overlayState: OverlayState {
    switch state {
    case .idle: return .hidden
    case .loadingModel: return .loading(message: "Loading model...")
    case .recording: return .listening(timerValue: currentRecordingDuration)
    case .transcribing: return .processing(message: "Transcribing...")
    case .polishing: return .processing(message: "Polishing...")
    case .complete: return .hidden
    }
}
```

This means the UI observes `pipeline.overlayState` and contains zero logic about pipeline internals. The pipeline owns the mapping from internal state to public-facing UI intent.

### GPT-4.1 Follow-Up Confirmation

GPT-4.1 confirmed all three positions:
1. `.loadingModel` is mandatory, not optional
2. Shared AudioCaptureManager with CaptureMode is safer than separate instances
3. `DictationPipeline` protocol is worth defining even with only 2 backends

---

## Topic 7: Prior Session Insights (Pre-Highway)

### From whisperkit-tuning-research (Gemini)
- Recommended `distil-large-v3` as best English model variant — **flagged by Oracle as unverified in WhisperKit 0.12 ModelVariant enum**
- Established the "tune first, speed up later" principle — batch transcription quality must be validated before adding streaming complexity
- Recommended configurable `CaptureMode` enum on AudioCaptureManager rather than separate instances
- Build order: modularity audit -> decode defaults -> streaming (in that order)

### From whisperkit-architecture-debate (GPT-4o + Gemini)
- Both models unanimously chose separate pipelines over patching
- Both chose Checkpoint 2 (download + decode defaults) as the revert target
- GPT-4o: "The pipeline split is going to be exactly as hard in 2 weeks as it is today, but the patches will have calcified"
- Gemini: "Each ASR system demands a unique approach. Crafting distinct state machines will minimize the risk of state management bugs"

### From whisperkit-ux-parity (Gemini)
- Deep analysis of why `stopRequested` flag reuse is dangerous
- Identified that adding `.loadingModel` to the SHARED PipelineState requires 8+ file changes — this is exactly why separate pipelines (with their own state enums) are the right approach
- "Reusing the stopRequested flag is exactly the kind of 'clever' solution that leads to bugs later. Its meaning becomes conditional on the state of the machine when it was set."
