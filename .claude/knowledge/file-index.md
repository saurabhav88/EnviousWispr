# File Index — EnviousWispr

Quick-reference for every source file. Use this to find files by domain or purpose.

**61 Swift files, ~9,266 lines** in `Sources/EnviousWispr/`

## App (4 files, ~1,121 lines)


| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `App/EnviousWisprApp.swift` | 32 | `EnviousWisprApp` (@main), `ActionWirer` | SwiftUI entry point, single Window scene, action wiring helper |
| `App/AppDelegate.swift` | 312 | `AppDelegate` (@MainActor) | Menu bar NSStatusItem, Sparkle updater, MenuBarIconAnimator lifecycle, Carbon hotkey startup |
| `App/AppState.swift` | 516 | `AppState` (@MainActor @Observable), `KeyValidationState` | Root observable, owns all subsystems, recording toggle, transcript CRUD, settings propagation |
| `App/MenuBarIconAnimator.swift` | 265 | `MenuBarIconAnimator` (@MainActor), `IconState` | CG-rendered menu bar icons — 4 states (idle/recording/processing/error), audio-reactive rainbow lips, rotating spectrum wheel |

## ASR (4 files, ~444 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `ASR/ASRProtocol.swift` | 76 | `ASRBackend` (protocol: Actor), `ASRError` | Unified backend interface — batch + streaming |
| `ASR/ASRManager.swift` | 134 | `ASRManager` (@MainActor @Observable) | Backend router, idle unload timer, delegates to active backend |
| `ASR/ParakeetBackend.swift` | 144 | `ParakeetBackend` (actor) | FluidAudio/CoreML backend, streaming support via StreamingAsrManager |
| `ASR/WhisperKitBackend.swift` | 90 | `WhisperKitBackend` (actor) | ArgMax WhisperKit backend, batch-only, configurable model variant |

## Audio (3 files, ~500 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Audio/AudioCaptureManager.swift` | 170 | `AudioCaptureManager` (@MainActor @Observable) | AVAudioEngine mic capture, resamples to 16kHz mono, accumulates samples |
| `Audio/AudioBufferProcessor.swift` | 35 | `AudioBufferProcessor` (enum), `AudioError` | Pure RMS calculation utility |
| `Audio/SilenceDetector.swift` | 295 | `SilenceDetector` (actor), `SmoothedVADConfig`, `SmoothedVADPhase`, `SpeechSegment` | Silero VAD wrapper, 3-phase state machine (idle/speech/hangover), auto-stop |

## Pipeline (4 files, ~740 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Pipeline/TranscriptionPipeline.swift` | 563 | `TranscriptionPipeline` (@MainActor @Observable) | Core orchestrator — state machine, streaming/batch ASR, VAD monitoring, text processing, paste |
| `Pipeline/TextProcessingStep.swift` | 32 | `TextProcessingContext` (struct), `TextProcessingStep` (protocol) | Step interface and context carrier for processing chain |
| `Pipeline/Steps/LLMPolishStep.swift` | 117 | `LLMPolishStep` (@MainActor) | Selects LLM connector, resolves ${transcript} placeholder, streams tokens, extended thinking config |
| `Pipeline/Steps/WordCorrectionStep.swift` | 28 | `WordCorrectionStep` (@MainActor) | Runs WordCorrector against custom word list |

## LLM (9 files, ~1,431 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `LLM/LLMProtocol.swift` | 102 | `TranscriptPolisher` (protocol), `LLMError` | Polisher interface, error types, preamble stripping |
| `LLM/OpenAIConnector.swift` | 91 | `OpenAIConnector` (struct: TranscriptPolisher) | OpenAI chat completions, reasoning effort for o-series models |
| `LLM/GeminiConnector.swift` | 219 | `GeminiConnector` (struct: TranscriptPolisher) | Google Gemini, SSE streaming + batch, systemInstruction field, thinking budget |
| `LLM/OllamaConnector.swift` | 93 | `OllamaConnector` (struct: TranscriptPolisher) | Local Ollama, OpenAI-compatible endpoint |
| `LLM/AppleIntelligenceConnector.swift` | 121 | `AppleIntelligenceConnector` (struct), `CleanedTranscript` | On-device via FoundationModels (macOS 26+) |
| `LLM/KeychainManager.swift` | 113 | `KeychainManager` (struct: Sendable) | File-based key storage (~/.enviouswispr-keys/), 0600 perms |
| `LLM/LLMNetworkSession.swift` | 51 | `LLMNetworkSession` (final class: Sendable) | Singleton URLSession, HTTP/2 reuse, TLS pre-warm |
| `LLM/LLMModelDiscovery.swift` | 314 | `LLMModelDiscovery` (struct: Sendable) | Discovers models from all providers, concurrent probing |
| `LLM/OllamaSetupService.swift` | 327 | `OllamaSetupService` (@MainActor @Observable), `OllamaSetupState` | Ollama install/start/pull wizard with NDJSON progress |

## Models (4 files, ~276 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Models/AppSettings.swift` | 80 | `RecordingMode`, `PipelineState`, `ModelUnloadPolicy` | Core enums for pipeline state and recording modes |
| `Models/ASRResult.swift` | 33 | `ASRBackendType`, `ASRResult`, `TranscriptSegment`, `TranscriptionOptions` | ASR output types |
| `Models/Transcript.swift` | 47 | `Transcript` (struct: Codable) | Full transcript record with polished/raw text, metadata |
| `Models/LLMResult.swift` | 116 | `LLMProvider`, `LLMResult`, `LLMProviderConfig`, `LLMModelInfo`, `PolishInstructions`, `PromptPreset` | LLM types, polish instructions, prompt presets |

## Services (4 files, ~938 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Services/SettingsManager.swift` | 287 | `SettingsManager` (@MainActor @Observable), `SettingKey` (26 cases) | All UserDefaults persistence, didSet observers, onChange callback |
| `Services/HotkeyService.swift` | 442 | `HotkeyService` (@MainActor @Observable), `ModifierKeyCodes`, `HotkeyID` | Carbon RegisterEventHotKey, NSEvent monitors, suspend/resume for recorder |
| `Services/PermissionsService.swift` | 79 | `PermissionsService` (@MainActor @Observable) | Mic (AVFoundation) + Accessibility (AXIsProcessTrusted) checks |
| `Services/PasteService.swift` | 130 | `PasteService` (enum), `ClipboardSnapshot` | Clipboard save/restore, CGEvent Cmd+V paste simulation |

## Storage (1 file, 101 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Storage/TranscriptStore.swift` | 101 | `TranscriptStore` (@MainActor) | JSON file store in ~/Library/Application Support/, async load |

## PostProcessing (2 files, ~175 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `PostProcessing/CustomWordStore.swift` | 37 | `CustomWordStore` (final class: Sendable) | Persists custom words as JSON |
| `PostProcessing/WordCorrector.swift` | 138 | `WordCorrector` (struct: Sendable) | Fuzzy matching: Levenshtein(40%) + bigram Dice(40%) + Soundex(20%), threshold 0.82 |

## Views — Main (5 files, ~682 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Views/Main/MainWindowView.swift` | 324 | `StatusView`, `PulsingRingsView`, `WaveformView`, `AudioLevelBar`, `StatusBadge`, `RecordButton` | Recording state display, toolbar components |
| `Views/Main/HistoryContentView.swift` | 30 | `HistoryContentView` | HSplitView: sidebar + detail, accessibility banner |
| `Views/Main/TranscriptHistoryView.swift` | 108 | `TranscriptHistoryView`, `TranscriptRowView` | Sidebar list with search, badges, delete-all |
| `Views/Main/TranscriptDetailView.swift` | 127 | `TranscriptDetailView` | Copy/Paste/Enhance toolbar, dual-pane polished+original |
| `Views/Main/SidebarStatsHeader.swift` | 93 | `SidebarStatsHeader`, `ModelStatusBar` | Search field, transcript count, model status dot |

## Views — Settings (10 files, ~1,292 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Views/Settings/SettingsView.swift` | 81 | `UnifiedWindowView` | Root NavigationSplitView, sidebar sections, onboarding sheet |
| `Views/Settings/SettingsSection.swift` | 66 | `SettingsSection` (enum), `SettingsGroup` (enum) | 9 sections in 5 groups (APP/RECORD/PROCESS/OUTPUT/SYSTEM) |
| `Views/Settings/SpeechEngineSettingsView.swift` | 88 | `SpeechEngineSettingsView` | Backend picker, VAD controls (auto-stop, sensitivity, energy gate) |
| `Views/Settings/AIPolishSettingsView.swift` | 512 | `AIPolishSettingsView` | LLM provider/model picker, API key entry, Ollama wizard, Apple Intelligence, extended thinking toggle |
| `Views/Settings/ShortcutsSettingsView.swift` | 51 | `ShortcutsSettingsView` | Hotkey enable, transcribe/cancel shortcut recorders, PTT toggle |
| `Views/Settings/PermissionsSettingsView.swift` | 64 | `PermissionsSettingsView` | Mic + Accessibility status, request buttons, 5s polling |
| `Views/Settings/ClipboardSettingsView.swift` | 21 | `ClipboardSettingsView` | Auto-copy + restore-clipboard toggles |
| `Views/Settings/MemorySettingsView.swift` | 32 | `MemorySettingsView` | ModelUnloadPolicy picker |
| `Views/Settings/WordFixSettingsView.swift` | 88 | `WordFixSettingsView` | Word correction toggle, custom word list CRUD |
| `Views/Settings/PromptEditorView.swift` | 138 | `PromptEditorView` | Modal prompt editor, presets, ${transcript} validation |
| `Views/Settings/DiagnosticsSettingsView.swift` | 151 | `DiagnosticsSettingsView` | Debug mode, log management, ASR/pipeline benchmarks |

## Views — Other (4 files, ~855 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Views/Onboarding/OnboardingView.swift` | 250 | `OnboardingView`, `StepBadge`, `IconCircle` | 4-step first-launch wizard (Welcome/Mic/Accessibility/Ready) |
| `Views/Components/HotkeyRecorderView.swift` | 209 | `HotkeyRecorderView`, `KeyCaptureNSView`, `KeyCaptureView` | Click-to-record shortcut widget, suspends Carbon during capture |
| `Views/Components/AccessibilityWarningBanner.swift` | 49 | `AccessibilityWarningBanner` | Orange banner, "Fix Now" → Permissions tab, dismissible |
| `Views/Overlay/RecordingOverlayPanel.swift` | 347 | `RecordingOverlayPanel`, `SpectrumWheelIcon`, `RainbowLipsIcon`, `OverlayCapsuleBackground`, `RecordingOverlayView`, `PolishingOverlayView` | Floating NSPanel, brand icons (spectrum wheel + rainbow lips), recording/polishing overlays |

## Utilities (6 files, ~738 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Utilities/Constants.swift` | 93 | `AppConstants`, `AudioConstants`, `TimingConstants`, `LLMConstants`, `FormattingConstants` | All magic numbers, paths, thinking budget defaults |
| `Utilities/AppLogger.swift` | 125 | `AppLogger` (actor) | Dual OSLog + rotating file log, singleton |
| `Utilities/DebugLogLevel.swift` | 20 | `DebugLogLevel` (enum) | .info/.verbose/.debug with Comparable |
| `Utilities/BenchmarkSuite.swift` | 268 | `BenchmarkSuite` (@MainActor @Observable), `Result`, `PipelineBenchmarkResult` | ASR throughput + pipeline benchmarks, WER comparison |
| `Utilities/KeySymbols.swift` | 148 | `KeySymbols` (enum) | Keycode → symbol conversion, modifier formatting |
| `Utilities/WERCalculator.swift` | 84 | `WERCalculator` (enum), `Result` | Word Error Rate via edit distance |
