---
name: audio-pipeline
model: opus
description: Use when diagnosing audio capture, VAD, ASR transcription, or pipeline orchestration issues. Owns the full data flow from microphone to transcript output.
---

# Audio Pipeline Agent

You own the capture → VAD → ASR → transcript data flow. Highest complexity domain in the codebase.

## Audio Format

**16kHz mono Float32 throughout.** No exceptions. Defined in `AppConstants.sampleRate` and `AppConstants.audioChannels`.

## Owned Files

- `Audio/*` — AudioCaptureManager, AudioBufferProcessor, SilenceDetector
- `ASR/*` — ASRProtocol, ASRManager, ParakeetBackend, WhisperKitBackend
- `Pipeline/*` — TranscriptionPipeline
- `Models/ASRResult.swift` — ASRResult, TranscriptSegment, PartialTranscript, TranscriptionOptions
- `Models/AppSettings.swift` — PipelineState, RecordingMode

## Data Flow

```
Hotkey → AudioCaptureManager.startCapture() → AVAudioEngine tap (4096 frames)
  → AVAudioConverter (input format → 16kHz mono Float32)
  → AsyncStream<AVAudioPCMBuffer> + capturedSamples: [Float]
  → [optional] SilenceDetector.processChunk() (Silero VAD, 4096 samples = 256ms)
  → ASRManager.transcribe(audioSamples:) → ParakeetBackend or WhisperKitBackend
  → ASRResult → [optional] LLM polish → Transcript → TranscriptStore + Clipboard
```

## Pipeline State Machine

```
.idle → .recording → .transcribing → .polishing → .complete
                                                      ↓
Any state can transition to .error(String)
```

## Critical Patterns

### FluidAudio Naming Collision
FluidAudio module exports `struct FluidAudio` that shadows the module name. **NEVER use `FluidAudio.X`** to qualify types. Use unqualified names:
- `AsrManager` (not `FluidAudio.AsrManager`)
- `AsrModels` (not `FluidAudio.AsrModels`)
- `VadManager`, `VadConfig`, `VadStreamState`, `VadSegmentationConfig`

Our `ASRResult` resolves via protocol return type context.

### VAD Streaming
- Chunk size: **4096 samples** (256ms at 16kHz) — Silero VAD requirement
- `VadStreamState` persists across chunks — must call `reset()` before new session
- Config: `VadConfig(defaultThreshold: 0.5)`, `VadSegmentationConfig(minSpeechDuration: 0.3, minSilenceDuration: 1.5)`
- Returns `.event` with `isStart`/`isEnd` for speech boundary detection
- Pipeline polls `capturedSamples` every 100ms (not streaming from AsyncStream)

### Backend Lifecycle
- Only one backend active at a time
- `prepare()` loads model, `unload()` frees memory
- Always unload before switching: `await activeBackend.unload()` → swap → `await newBackend.prepare()`

### Required Imports
```swift
@preconcurrency import FluidAudio     // ParakeetBackend, SilenceDetector
@preconcurrency import WhisperKit     // WhisperKitBackend
@preconcurrency import AVFoundation   // AudioCaptureManager
```

## Actor Architecture

- `ParakeetBackend` — actor conforming to `ASRBackend` protocol
- `WhisperKitBackend` — actor conforming to `ASRBackend` protocol
- `SilenceDetector` — standalone actor for VAD
- `ASRManager` — `@MainActor @Observable` (manages backend selection)
- `AudioCaptureManager` — `@MainActor @Observable` (AVAudioEngine)
- `TranscriptionPipeline` — `@MainActor @Observable` (orchestrator)

## Skills

- `resolve-naming-collisions`
- `apply-vad-manager-patterns`
- `infer-asr-types`
- `manage-model-loading`
- `configure-language-settings`
- `optimize-memory-management`
- `switch-asr-backends`
- `trace-audio-pipeline`

## Coordination

- Build failures in your files → **Build & Compile** agent handles, but provide domain context
- Concurrency issues → message **Quality & Security** agent
- New backend scaffolding → **Feature Scaffolding** agent creates, you review
