# Architecture

macOS dictation app heading toward consumer publication and commercialization. Record → Transcribe (Parakeet v3 / WhisperKit) → optional LLM polish → clipboard. macOS 14+, Apple Silicon.

## Directory Structure

```text
Sources/EnviousWispr/
├── App/              # SwiftUI entry, AppState (@Observable)
├── ASR/              # ASRBackend protocol, Parakeet + WhisperKit backends
├── Audio/            # AVAudioEngine capture, SilenceDetector (Silero VAD)
├── LLM/              # TranscriptPolisher protocol, OpenAI + Gemini + Ollama + Apple Intelligence, KeychainManager, LLMModelDiscovery
├── Models/           # Transcript, ASRResult, AppSettings, LLMResult
├── Pipeline/         # TranscriptionPipeline orchestrator
├── PostProcessing/   # CustomWordStore, WordCorrector
├── Resources/        # Info.plist, entitlements, AppIcon.icns
├── Services/         # PasteService, PermissionsService, HotkeyService, SettingsManager
├── Storage/          # TranscriptStore (JSON persistence)
├── Utilities/        # Constants, BenchmarkSuite, KeySymbols, AppLogger, DebugLogLevel
└── Views/
    ├── Components/   # HotkeyRecorderView
    ├── Main/         # History list, detail, controls
    ├── Onboarding/   # First-launch flow
    ├── Overlay/      # RecordingOverlayPanel
    └── Settings/     # Speech Engine, Shortcuts, AI Polish, Voice Detection, etc.

docs/
├── comparison-handy-vs-enviouswispr.md   # Technical comparison with Handy
├── feature-requests/                      # Future feature specs + tracker
│   ├── TRACKER.md                         # Master status checklist
│   └── NNN-feature-name.md               # One file per feature (001-020)
└── plans/                                 # Design docs + implementation plans
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
| `HotkeyService` | Carbon RegisterEventHotKey global hotkeys | `@MainActor` |
| `OpenAIConnector` | GPT polish | `TranscriptPolisher` |
| `GeminiConnector` | Gemini polish | `TranscriptPolisher` |
| `OllamaConnector` | Ollama local LLM polish | `TranscriptPolisher` |
| `AppleIntelligenceConnector` | Apple Intelligence polish | `TranscriptPolisher` |
| `OllamaSetupService` | Ollama server detection + model mgmt | `@MainActor` |
| `LLMModelDiscovery` | Runtime discovery of available LLM models | — |
| `SettingsManager` | Centralized settings persistence | `@MainActor` |
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
