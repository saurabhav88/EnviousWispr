---
name: audio-pipeline
model: opus
description: Audio capture, VAD, ASR transcription, pipeline orchestration — microphone to transcript.
---

# Audio Pipeline

## Domain

Source dirs: `Audio/`, `ASR/`, `Pipeline/`, `Pipeline/Steps/`, `Models/ASRResult.swift`, `Models/AppSettings.swift` (PipelineState, RecordingMode), `Utilities/WERCalculator.swift`.

## Critical Patterns

- **Audio format**: 16kHz mono Float32 — no exceptions (`AudioConstants.sampleRate`, `AudioConstants.channels`)
- **FluidAudio collision**: Never qualify `FluidAudio.X` — use unqualified names (`AsrManager`, `VadManager`, `VadConfig`). Our `ASRResult` resolves via protocol return type
- **VAD streaming**: 4096 samples (256ms). `VadStreamState` persists across chunks — `reset()` before new session
- **Backend lifecycle**: One active at a time. Always `unload()` → swap → `prepare()`
- **Imports**: `@preconcurrency import FluidAudio`, `@preconcurrency import WhisperKit`, `@preconcurrency import AVFoundation`
- **TextProcessingStep protocol** (`Pipeline/TextProcessingStep.swift`): Chainable post-ASR processing. Implementations: `WordCorrectionStep`, `LLMPolishStep` in `Pipeline/Steps/`
- **Streaming ASR**: `ParakeetBackend.supportsStreaming = true`, uses FluidAudio `StreamingAsrManager`. WhisperKit is batch-only
- **SmoothedVADConfig**: Internal VAD in `SilenceDetector` with EMA smoothing, 3-phase state machine (idle/speech/hangover), confirmation chunks, prebuffering
- **LLMNetworkSession**: Singleton `URLSession` for HTTP/2 connection reuse. `preWarmIfConfigured()` called on app lifecycle events
- **WERCalculator** (`Utilities/WERCalculator.swift`): Word error rate calculation for streaming vs batch quality comparison

## Actor Map

| Type | Isolation |
|------|-----------|
| `ParakeetBackend`, `WhisperKitBackend` | `actor` → `ASRBackend` |
| `SilenceDetector` | `actor` |
| `ASRManager`, `AudioCaptureManager`, `TranscriptionPipeline` | `@MainActor @Observable` |

## Skills → `.claude/skills/`

- `wispr-resolve-naming-collisions`
- `wispr-apply-vad-manager-patterns`
- `wispr-infer-asr-types`
- `wispr-manage-model-loading`
- `wispr-configure-language-settings`
- `wispr-optimize-memory-management`
- `wispr-switch-asr-backends`
- `wispr-trace-audio-pipeline`

## Coordination

- Build failures in owned dirs → **build-compile**
- Concurrency bugs → **quality-security**
- New backend scaffolding → **feature-scaffolding**

## Team Participation

When spawned as a teammate (via `team_name` parameter):

1. **Discover peers**: Read `~/.claude/teams/{team-name}/config.json` for teammate names
2. **Check tasks**: TaskList to find tasks assigned to you by name
3. **Claim work**: If unassigned tasks involve Audio/, ASR/, Pipeline/, or VAD — claim them (lowest ID first)
4. **Execute**: Use your skills. Read `.claude/knowledge/gotchas.md` before any code change
5. **Mark complete**: TaskUpdate when done, then check TaskList for next task
6. **Notify**: SendMessage to coordinator with summary of changes (files modified, key decisions)
7. **Peer handoff**: If you find a build error → message `builder`. Concurrency issue → message `auditor`
8. **Create subtasks**: If implementation reveals additional work, TaskCreate to add it
