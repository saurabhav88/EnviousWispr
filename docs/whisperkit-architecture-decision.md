# Architecture Decision: Separate Pipeline Per Backend

**Date:** 2026-03-06
**Status:** Proposed
**Consulted:** GPT-4o, Gemini 2.5 Flash, internal analysis

## Decision

Split `TranscriptionPipeline` into backend-specific pipelines behind a shared `Pipeline` protocol. Each backend gets its own state machine, overlay behavior, and ASR orchestration. Shared infrastructure (audio capture, hotkeys, LLM polish, paste, transcripts) remains common.

## Context

EnviousWispr was built and optimized for Parakeet (streaming ASR). Adding WhisperKit (batch ASR) has required increasingly painful patches:
- `.loadingModel` state added to handle on-demand model loading
- `startRequestCancelled` flag to handle PTT release during model load
- `transitionToRecording()` method to handle overlay transitions from loading → recording
- Each patch reveals another edge case in the shared state machine

The fundamental mismatch: Parakeet streams during recording (ASR is invisible), WhisperKit batches after recording (ASR is a visible 1-5s phase). Forcing both through one state machine creates conditional branches everywhere.

## Architecture

### What Gets Split

| Component | Split? | Rationale |
|-----------|--------|-----------|
| Pipeline state machine | YES | Fundamentally different states per backend |
| ASR orchestration | YES | Streaming vs batch, model lifecycle |
| Overlay state logic | YES | Different state → overlay mappings |
| Audio buffer routing | YES | Streaming forwarding vs batch collection |

### What Stays Shared

| Component | Shared? | Rationale |
|-----------|---------|-----------|
| AudioCaptureManager | YES | Same mic, same engine, configurable mode |
| HotkeyService | YES | PTT/toggle is backend-agnostic |
| LLM polish step | YES | Same text → polish → text regardless of ASR |
| PasteService | YES | Same paste logic |
| Transcript storage | YES | Same data model |
| RecordingOverlayPanel | YES | Same NSPanel mechanics, pipelines tell it what to show |
| AppState | YES | Swaps active pipeline reference |

### Protocol Design

```swift
@MainActor
protocol DictationPipeline {
    /// Current pipeline state — each implementation defines its own enum
    /// but maps to a shared OverlayIntent for the UI layer.
    var onStateChange: ((OverlayIntent) -> Void)? { get set }
    var onComplete: ((String) -> Void)? { get set }

    func startRecording() async
    func requestStop() async
    func cancel() async
    func toggleRecording() async

    var isActive: Bool { get }
}

/// What the overlay should show — shared across all pipelines.
/// Pipelines map their internal states to this.
enum OverlayIntent: Equatable {
    case hidden
    case recording(audioLevelProvider: () -> Float)
    case processing(label: String)  // "Loading model...", "Transcribing...", "Polishing..."
}
```

### Pipeline Implementations

**ParakeetPipeline** (states: idle → recording → polishing → complete)
- Model always loaded (FluidAudio pre-loads)
- Streaming ASR during recording — invisible to user
- 2 overlay states: recording (lips) → processing ("Polishing...")

**WhisperKitPipeline** (states: idle → loadingModel → recording → transcribing → polishing → complete)
- Model loaded on demand, may need cold start
- Batch ASR after recording — visible 1-5s phase
- Up to 4 overlay states: processing ("Loading...") → recording (lips) → processing ("Transcribing...") → processing ("Polishing...")

### AudioCaptureManager Strategy

Keep shared, add capture mode configuration:
- Pipeline sets capture mode before starting: `.streamingForward` (Parakeet) or `.batchCollect` (WhisperKit)
- In streaming mode: `onBufferCaptured` fires for each buffer
- In batch mode: buffers accumulated internally, returned on stop
- Common: mic access, engine lifecycle, format stabilization, pre-warm

## Trade-offs

**Pros:**
- Each pipeline is clean, purpose-built, no conditional branches
- Parakeet's perfect flow is untouched
- Adding a third backend (e.g., cloud ASR) is straightforward
- State machines are simple and testable
- No more flag gymnastics (stopRequested, startRequestCancelled)

**Cons:**
- More code (~200-300 lines per pipeline vs 700 shared)
- Some duplication in recording start/stop boilerplate
- Must keep shared components (paste, polish) properly decoupled
- Migration effort from current monolithic pipeline

## Migration Path

1. Extract shared components into standalone services (already mostly done)
2. Define `DictationPipeline` protocol and `OverlayIntent`
3. Create `ParakeetPipeline` — extract Parakeet-specific logic from TranscriptionPipeline
4. Create `WhisperKitPipeline` — extract WhisperKit-specific logic
5. Update `AppState` to hold `any DictationPipeline`, swap on backend change
6. Update overlay to consume `OverlayIntent` instead of `PipelineState`
7. Remove old `TranscriptionPipeline` and `PipelineState` enum
8. Test both backends independently

## Buddies Consensus

**GPT-4o:** "You've hit that classic point where iteratively adding features to a single pipeline creates more complexity and fragility than it's worth. Separating the pipelines is the right call."

**Gemini 2.5 Flash:** "Each ASR system demands a unique approach. Crafting distinct state machines will minimize the risk of state management bugs. Though it involves more code upfront, the clarity starts paying dividends almost immediately."

**Both agree:** Keep AudioCaptureManager shared with configurable capture modes. Split pipeline logic. Use delegation/strategy pattern for audio routing.
