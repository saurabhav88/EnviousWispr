---
name: audio-pipeline
model: opus
description: Audio capture, VAD, ASR transcription, pipeline orchestration — microphone to transcript.
---

# Audio Pipeline

## Domain

Source dirs: `Audio/`, `ASR/`, `Pipeline/`, `Models/ASRResult.swift`, `Models/AppSettings.swift` (PipelineState, RecordingMode).

## Critical Patterns

- **Audio format**: 16kHz mono Float32 — no exceptions (`AppConstants.sampleRate`, `AppConstants.audioChannels`)
- **FluidAudio collision**: Never qualify `FluidAudio.X` — use unqualified names (`AsrManager`, `VadManager`, `VadConfig`). Our `ASRResult` resolves via protocol return type
- **VAD streaming**: 4096 samples (256ms). `VadStreamState` persists across chunks — `reset()` before new session
- **Backend lifecycle**: One active at a time. Always `unload()` → swap → `prepare()`
- **Imports**: `@preconcurrency import FluidAudio`, `@preconcurrency import WhisperKit`, `@preconcurrency import AVFoundation`

## Actor Map

| Type | Isolation |
|------|-----------|
| `ParakeetBackend`, `WhisperKitBackend` | `actor` → `ASRBackend` |
| `SilenceDetector` | `actor` |
| `ASRManager`, `AudioCaptureManager`, `TranscriptionPipeline` | `@MainActor @Observable` |

## Skills → `.claude/skills/`

- `resolve-naming-collisions`
- `apply-vad-manager-patterns`
- `infer-asr-types`
- `manage-model-loading`
- `configure-language-settings`
- `optimize-memory-management`
- `switch-asr-backends`
- `trace-audio-pipeline`

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
