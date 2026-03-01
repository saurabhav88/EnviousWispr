# Architecture

macOS dictation app heading toward consumer publication and commercialization. Record → Transcribe (Parakeet v3 / WhisperKit) → optional LLM polish → clipboard. macOS 14+, Apple Silicon.

## Directory Structure

```text
Sources/EnviousWispr/
├── App/              # SwiftUI entry, AppState (@Observable), MenuBarIconAnimator
├── ASR/              # ASRBackend protocol, Parakeet + WhisperKit backends
├── Audio/            # AVAudioEngine capture, SilenceDetector (Silero VAD)
├── LLM/              # TranscriptPolisher protocol, OpenAI + Gemini + Ollama + Apple Intelligence, KeychainManager, LLMModelDiscovery
├── Models/           # Transcript, ASRResult, AppSettings, LLMResult
├── Pipeline/         # TranscriptionPipeline orchestrator, TextProcessingStep
│   └── Steps/        # LLMPolishStep, WordCorrectionStep
├── PostProcessing/   # CustomWordStore, WordCorrector
├── Resources/        # Info.plist, entitlements, AppIcon.icns
├── Services/         # PasteService, PermissionsService, HotkeyService, SettingsManager
├── Storage/          # TranscriptStore (JSON persistence)
├── Utilities/        # Constants, BenchmarkSuite, KeySymbols, AppLogger, DebugLogLevel
└── Views/
    ├── Components/   # HotkeyRecorderView
    ├── Main/         # History list, detail, controls
    ├── Onboarding/   # First-launch flow
    ├── Overlay/      # RecordingOverlayPanel, brand icons (SpectrumWheelIcon, RainbowLipsIcon)
    └── Settings/     # Speech Engine, Shortcuts, AI Polish, Voice Detection, etc.

docs/
├── comparison-handy-vs-enviouswispr.md   # Technical comparison with Handy
├── feature-requests/                      # Future feature specs + tracker
│   ├── TRACKER.md                         # Master status checklist
│   └── NNN-feature-name.md               # One file per feature (001-020)
└── plans/                                 # Design docs + implementation plans

scripts/
└── build-dmg.sh                           # Release build: arm64 binary + .app bundle + DMG
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
| `OpenAIConnector` | GPT polish | `struct` → `TranscriptPolisher` |
| `GeminiConnector` | Gemini polish | `struct` → `TranscriptPolisher` |
| `OllamaConnector` | Ollama local LLM polish | `struct` → `TranscriptPolisher` |
| `AppleIntelligenceConnector` | Apple Intelligence polish | `struct` → `TranscriptPolisher` |
| `OllamaSetupService` | Ollama server detection + model mgmt | `@MainActor` |
| `LLMModelDiscovery` | Runtime discovery of available LLM models | — |
| `SettingsManager` | Centralized settings persistence (26 keys) | `@MainActor` |
| `MenuBarIconAnimator` | CG-rendered 4-state menu bar icons, audio-reactive | `@MainActor` |
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
  → ASRResult → [optional] LLM polish → Transcript → TranscriptStore + ClipboardSnapshot + Clipboard
```

**Streaming ASR:** During recording, audio buffers are streamed to ASRBackend via `feedAudio()` for live partial transcription. `onToken` callback enables SSE streaming for Gemini polish responses.

## Protocols

- `ASRBackend` (actor protocol) — `prepare()`, `transcribe(audioURL:)`, `transcribe(audioSamples:)`, `unload()`, `supportsStreaming: Bool`, `startStreaming(options:)`, `feedAudio(_:)`, `finalizeStreaming()`, `cancelStreaming()`
- `TranscriptPolisher` — `polish(text:instructions:config:onToken:)`. The `onToken: (@Sendable (String) -> Void)?` callback enables SSE streaming for Gemini polish responses. Pass `nil` for batch mode.
- `TextProcessingStep` (`@MainActor` protocol) — post-ASR text processing chain. Properties: `name: String`, `isEnabled: Bool`. Method: `process(_ context: TextProcessingContext) async throws -> TextProcessingContext`. Implementations: `LLMPolishStep`, `WordCorrectionStep`.

## Notable Subsystems

- **Model Unload Management** — `ModelUnloadPolicy` enum (never/immediately/2min/5min/10min/15min/60min). `ASRManager` runs idle timer to auto-unload models after inactivity.
- **LLMNetworkSession** — `Sendable` singleton wrapping `URLSession` with HTTP/2 multiplexing. `preWarm()` pre-warms connections before first polish request.
- **Advanced VAD** — `SmoothedVADConfig` with EMA smoothing, confirmation chunks, hangover. `SmoothedVADPhase` state machine: idle → speech → hangover → idle.
- **ClipboardSnapshot** — saves/restores clipboard contents around paste operations so user's clipboard is not clobbered.
- **Extended Thinking** — `LLMPolishStep.resolveThinkingConfig()` supports Gemini `thinkingBudget` (2.5 Flash/Pro) and OpenAI `reasoningEffort` (o-series). Controlled by `useExtendedThinking` setting. `LLMProviderConfig` carries `thinkingBudget: Int?` and `reasoningEffort: String?`.
- **Menu Bar Icon Animation** — `MenuBarIconAnimator` renders 4 icon states via Core Graphics: idle (grey lips), recording (rainbow lips with audio-reactive bars), processing (rotating spectrum wheel), error (red lips). Driven by `AppDelegate` via pipeline state callbacks.

## UAT Testing Architecture

```text
Tests/UITests/
├── uat_runner.py          # Static tests + auto-discovery of generated/
├── ui_helpers.py          # AX tree primitives (find, wait, assert)
├── simulate_input.py      # CGEvent HID simulation (click, key, type)
├── screenshot_verify.py   # Visual regression
├── ax_inspect.py          # AX tree inspector
├── diff_analyzer.py       # Git diff → structured summary with domain inference
└── generated/             # LLM-generated test files (ephemeral, per-diff, run via --files)
```

**Smart UAT flow:** scope (completed todos → conversation context → `diff_analyzer.py` fallback) → `uat-generator` agent → test files in `generated/` → `uat_runner.py run --files <generated paths>`.

**FIRM RULE:** All UAT execution MUST use `run_in_background: true`. CGEvent simulation collides with VSCode foreground dialogs.
