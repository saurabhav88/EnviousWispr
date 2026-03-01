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

## Error Handling

| Failure Mode | Detection | Recovery |
|---|---|---|
| Audio device disconnected mid-recording | `AVAudioEngineConfigurationChange` + `kAudioDevicePropertyDeviceIsAlive` check | Alive = `recoverFromCodecSwitch()` (in-place reconfigure). Dead = `emergencyTeardown()` (full reset) |
| Backend `transcribe()` throws | Catch in `TranscriptionPipeline.stopAndTranscribe()` | Transition to `.error(message)` state, log at `.info`, surface to user via overlay |
| Streaming finalize/cancel called twice | `isStreaming` guard flag in backend | Second call is a no-op. Log warning, do not throw |
| `engine.start()` throws after `installTap()` | Catch block in `AudioCaptureManager.startCapture()` | Remove orphaned tap (`inputNode.removeTap(onBus: 0)`) before rethrowing |
| Model not loaded when transcription requested | `isReady` check on backend | Return early with `.error("Model not loaded")`, prompt user to select a model in Settings |

## Testing Requirements

All changes in Audio/, ASR/, Pipeline/ must satisfy the Definition of Done from `.claude/knowledge/conventions.md`:

1. `swift build -c release` exits 0
2. `swift build --build-tests` exits 0
3. .app bundle rebuilt + relaunched (`wispr-rebuild-and-relaunch`)
4. Smart UAT tests pass (`wispr-run-smart-uat`)
5. All UAT execution uses `run_in_background: true`

## Gotchas

Relevant items from `.claude/knowledge/gotchas.md` -- read the full file for details:

- **FluidAudio Naming Collision** -- never qualify `FluidAudio.X`, use unqualified names
- **Audio Format** -- 16kHz mono Float32 throughout, no exceptions
- **VAD Chunk Size** -- 4096 samples (256ms at 16kHz), `VadStreamState.reset()` before new session
- **ASR Backend Lifecycle** -- one active at a time, always `unload()` then `prepare()`
- **Streaming ASR Must End Exactly Once** -- `finalizeStreaming()`/`cancelStreaming()` exactly once per session, use `defer` + `Bool` flag
- **nonisolated(unsafe) for AVAudioPCMBuffer** -- required when crossing actor boundaries, comment why safe
- **AVAudioEngine Device Disconnect** -- check `kAudioDevicePropertyDeviceIsAlive` before deciding teardown vs recovery
- **Noise Suppression Requires Engine Rebuild** -- never toggle Voice Processing I/O on a live engine
- **PTT Pre-warm Fires Alongside Recording** -- parallel Tasks, `isPreWarmed` check avoids double setup
- **installTap Before engine.start()** -- remove tap in error path to avoid orphaned taps

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

### When Blocked by a Peer

1. Is the blocker a build failure? → SendMessage to `builder` with exact error and file path
2. Is the blocker a concurrency/Sendable issue? → SendMessage to `auditor` with the compiler diagnostic
3. Is the blocker a missing scaffold (new backend/connector)? → SendMessage to scaffolding peer
4. No response after your message? → TaskCreate a new unblocking task, assign to the blocked peer, notify coordinator
5. Blocker is outside any peer's domain? → SendMessage to coordinator explaining the situation

### When You Disagree with a Peer

1. Is it about audio format, VAD config, or backend lifecycle? → You are the domain authority -- state your reasoning with references to gotchas.md and architecture.md
2. Is it about build flags or dependency versions? → Defer to `builder` -- that is their domain
3. Is it about concurrency patterns? → Defer to `auditor` unless the pattern is audio-specific (e.g., nonisolated(unsafe) for AVAudioPCMBuffer)
4. Cannot resolve? → SendMessage to coordinator with both positions and your recommendation

### When Your Deliverable Is Incomplete

1. Can you complete a meaningful subset? → Deliver what works, TaskCreate for remaining items, mark current task complete with a note about what's missing
2. Blocked on external factor (hardware, permissions, model download)? → Mark task in_progress, SendMessage to coordinator explaining the blocker
3. Found a bug in existing code that must be fixed first? → TaskCreate a prerequisite bug-fix task, set your task as blockedBy it, notify coordinator
