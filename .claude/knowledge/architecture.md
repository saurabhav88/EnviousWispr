# Architecture

Local-first macOS dictation app. Record → Transcribe (Parakeet v3 / WhisperKit) → optional LLM polish → clipboard. macOS 14+, Apple Silicon.

## Directory Structure

```text
Sources/EnviousWispr/
├── App/          # SwiftUI entry, AppState (@Observable)
├── ASR/          # ASRBackend protocol, Parakeet + WhisperKit backends
├── Audio/        # AVAudioEngine capture, SilenceDetector (Silero VAD)
├── LLM/          # TranscriptPolisher protocol, OpenAI + Gemini, KeychainManager
├── Models/       # Transcript, ASRResult, AppSettings, LLMResult
├── Pipeline/     # TranscriptionPipeline orchestrator
├── Services/     # PasteService, PermissionsService, HotkeyService
├── Storage/      # TranscriptStore (JSON persistence)
├── Utilities/    # Constants, BenchmarkSuite
└── Views/
    ├── Main/         # History list, detail, controls
    ├── MenuBar/      # (reserved — menu bar uses NSStatusItem in AppDelegate)
    ├── Onboarding/   # First-launch flow
    └── Settings/     # 4 tabs: General, Shortcuts, AI Polish, Permissions
```

## Key Types

| Type | Role | Isolation |
|------|------|-----------|
| `AppState` | Root observable, DI container | `@MainActor @Observable` |
| `TranscriptionPipeline` | Orchestrates record → transcribe → polish → store | `@MainActor @Observable` |
| `AudioCaptureManager` | AVAudioEngine tap + buffer accumulation | `@MainActor @Observable` |
| `ASRManager` | Backend selection + delegation | `@MainActor @Observable` |
| `ParakeetBackend` | FluidAudio Parakeet v3 | `actor` → `ASRBackend` |
| `WhisperKitBackend` | WhisperKit transcription | `actor` → `ASRBackend` |
| `SilenceDetector` | Silero VAD streaming | `actor` |
| `HotkeyService` | NSEvent global/local monitors | `@MainActor` |
| `OpenAIConnector` | GPT polish | `TranscriptPolisher` |
| `GeminiConnector` | Gemini polish | `TranscriptPolisher` |
| `SPUStandardUpdaterController` | Sparkle auto-update (in AppDelegate) | `@MainActor` |

## Pipeline State Machine

```
.idle → .recording → .transcribing → .polishing → .complete
                                                     ↓
Any state can transition to .error(String)
```

## Data Flow

```
Hotkey → AudioCaptureManager.startCapture() → AVAudioEngine tap (4096 frames)
  → AVAudioConverter (input format → 16kHz mono Float32)
  → AsyncStream<AVAudioPCMBuffer> + capturedSamples: [Float]
  → [optional] SilenceDetector.processChunk() (Silero VAD, 4096 samples = 256ms)
  → ASRManager.transcribe(audioSamples:) → ParakeetBackend or WhisperKitBackend
  → ASRResult → [optional] LLM polish → Transcript → TranscriptStore + Clipboard
```

## Protocols

- `ASRBackend` (actor protocol) — `prepare()`, `transcribe(audioURL:)`, `transcribe(audioSamples:)`, `unload()`
- `TranscriptPolisher` — `polish(text:instructions:config:)`, `validateCredentials(config:)`
