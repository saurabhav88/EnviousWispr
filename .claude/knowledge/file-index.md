# File Index — EnviousWispr

Quick-reference for every source file. Use this to find files by domain or purpose.

**63 Swift files, ~10,263 lines** in `Sources/EnviousWispr/`

## App (4 files, ~1,181 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `App/EnviousWisprApp.swift` | 32 | `EnviousWisprApp` (@main), `ActionWirer` | SwiftUI entry point, single Window scene, action wiring helper |
| `App/AppDelegate.swift` | 326 | `AppDelegate` (@MainActor) | Menu bar NSStatusItem, Sparkle updater, MenuBarIconAnimator lifecycle, Carbon hotkey startup; stores NotificationCenter observer token |
| `App/AppState.swift` | 562 | `AppState` (@MainActor @Observable), `KeyValidationState` | Root observable, owns all subsystems, recording toggle, transcript CRUD, settings propagation, audio device monitor wiring |
| `App/MenuBarIconAnimator.swift` | 265 | `MenuBarIconAnimator` (@MainActor), `IconState` | CG-rendered menu bar icons — 4 states (idle/recording/processing/error), audio-reactive rainbow lips, rotating spectrum wheel |

## ASR (4 files, ~459 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `ASR/ASRProtocol.swift` | 74 | `ASRBackend` (protocol: Actor), `ASRError` | Unified backend interface — batch + streaming |
| `ASR/ASRManager.swift` | 147 | `ASRManager` (@MainActor @Observable) | Backend router, idle unload timer, delegates to active backend; guards against double sessions and refuses unload during streaming |
| `ASR/ParakeetBackend.swift` | 129 | `ParakeetBackend` (actor) | FluidAudio/CoreML backend, streaming support via StreamingAsrManager; cancels existing streamingManager before creating new one |
| `ASR/WhisperKitBackend.swift` | 108 | `WhisperKitBackend` (actor) | ArgMax WhisperKit backend, batch-only, makeDecodeOptions(), temperature fallback retry, model pre-warming |

## Audio (4 files, ~853 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Audio/AudioCaptureManager.swift` | 332 | `AudioCaptureManager` (@MainActor @Observable) | AVAudioEngine mic capture, resamples to 16kHz mono, setInputDevice(), voice processing enable/disable, AVAudioEngineConfigurationChange observer; emergencyTeardown(), trackTask(), onEngineInterrupted, maxRecordingDurationSeconds cap |
| `Audio/AudioBufferProcessor.swift` | 35 | `AudioBufferProcessor` (enum), `AudioError` | Pure RMS calculation utility |
| `Audio/AudioDeviceManager.swift` | 191 | `AudioInputDevice` (struct), `AudioDeviceEnumerator` (enum), `AudioDeviceMonitor` (class) | CoreAudio device enumeration, UID persistence, connect/disconnect monitoring |
| `Audio/SilenceDetector.swift` | 295 | `SilenceDetector` (actor), `SmoothedVADConfig`, `SmoothedVADPhase`, `SpeechSegment` | Silero VAD wrapper, 3-phase state machine (idle/speech/hangover), auto-stop |

## Pipeline (4 files, ~826 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Pipeline/TranscriptionPipeline.swift` | 649 | `TranscriptionPipeline` (@MainActor @Observable) | Core orchestrator — state machine, streaming/batch ASR, VAD monitoring, text processing, paste; wires onEngineInterrupted, finalizeStreaming timeout with defer cleanup |
| `Pipeline/TextProcessingStep.swift` | 32 | `TextProcessingContext` (struct), `TextProcessingStep` (protocol) | Step interface and context carrier for processing chain |
| `Pipeline/Steps/LLMPolishStep.swift` | 117 | `LLMPolishStep` (@MainActor) | Selects LLM connector, resolves ${transcript} placeholder, streams tokens, extended thinking config |
| `Pipeline/Steps/WordCorrectionStep.swift` | 28 | `WordCorrectionStep` (@MainActor) | Runs WordCorrector against custom word list |

## LLM (9 files, ~1,555 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `LLM/LLMProtocol.swift` | 102 | `TranscriptPolisher` (protocol), `LLMError` | Polisher interface, error types, preamble stripping |
| `LLM/OpenAIConnector.swift` | 91 | `OpenAIConnector` (struct: TranscriptPolisher) | OpenAI chat completions, reasoning effort for o-series models |
| `LLM/GeminiConnector.swift` | 219 | `GeminiConnector` (struct: TranscriptPolisher) | Google Gemini, SSE streaming + batch, systemInstruction field, thinking budget |
| `LLM/OllamaConnector.swift` | 99 | `OllamaConnector` (struct: TranscriptPolisher) | Local Ollama, OpenAI-compatible endpoint |
| `LLM/AppleIntelligenceConnector.swift` | 121 | `AppleIntelligenceConnector` (struct), `CleanedTranscript` | On-device via FoundationModels (macOS 26+) |
| `LLM/KeychainManager.swift` | 113 | `KeychainManager` (struct: Sendable) | File-based key storage (~/.enviouswispr-keys/), 0600 perms |
| `LLM/LLMNetworkSession.swift` | 51 | `LLMNetworkSession` (final class: Sendable) | Singleton URLSession, HTTP/2 reuse, TLS pre-warm |
| `LLM/LLMModelDiscovery.swift` | 314 | `LLMModelDiscovery` (struct: Sendable) | Discovers models from all providers, concurrent probing |
| `LLM/OllamaSetupService.swift` | 445 | `OllamaSetupService` (@MainActor @Observable), `OllamaSetupState`, `OllamaModelCatalogEntry` | Ollama install/start/pull wizard, static modelCatalog with quality tiers, isWeakModel(), pullModel(), deleteModel() |

## Models (4 files, ~282 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Models/AppSettings.swift` | 80 | `RecordingMode`, `PipelineState`, `ModelUnloadPolicy` | Core enums for pipeline state and recording modes |
| `Models/ASRResult.swift` | 39 | `ASRBackendType`, `ASRResult`, `TranscriptSegment`, `TranscriptionOptions` | ASR output types |
| `Models/Transcript.swift` | 47 | `Transcript` (struct: Codable) | Full transcript record with polished/raw text, metadata |
| `Models/LLMResult.swift` | 116 | `LLMProvider`, `LLMResult`, `LLMProviderConfig`, `LLMModelInfo`, `PolishInstructions`, `PromptPreset` | LLM types, polish instructions, prompt presets |

## Services (4 files, ~1,010 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Services/SettingsManager.swift` | 359 | `SettingsManager` (@MainActor @Observable), `SettingKey` (31 cases) | All UserDefaults persistence — added whiskerKitLanguageAutoDetect, whisperKitTemperature, whisperKitNoSpeechThreshold, selectedInputDeviceUID, noiseSuppression; hotkeyEnabled forced true |
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

## Views — Settings (11 files, ~1,538 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Views/Settings/SettingsView.swift` | 80 | `UnifiedWindowView` | Root NavigationSplitView, sidebar sections, onboarding sheet, `.audio` case routing |
| `Views/Settings/SettingsSection.swift` | 69 | `SettingsSection` (enum), `SettingsGroup` (enum) | 10 sections in 5 groups (APP/RECORD/PROCESS/OUTPUT/SYSTEM) — added `.audio` |
| `Views/Settings/AudioSettingsView.swift` | 32 | `AudioSettingsView` | Audio input device picker and noise suppression toggle |
| `Views/Settings/SpeechEngineSettingsView.swift` | 127 | `SpeechEngineSettingsView` | Backend picker, VAD controls (auto-stop, sensitivity, energy gate), WhisperKit quality controls (temperature, no-speech threshold, language auto-detect), filler removal |
| `Views/Settings/AIPolishSettingsView.swift` | 612 | `AIPolishSettingsView` | LLM provider/model picker, API key entry, None-state explainer, fixed OpenAI model picker, Ollama model catalog with quality tiers + download buttons, weak model prompt restrictions, Apple Intelligence, extended thinking toggle |
| `Views/Settings/ShortcutsSettingsView.swift` | 48 | `ShortcutsSettingsView` | Transcribe/cancel shortcut recorders, PTT/Toggle mode labels with dynamic descriptions (hotkey enable toggle removed) |
| `Views/Settings/PermissionsSettingsView.swift` | 64 | `PermissionsSettingsView` | Mic + Accessibility status, request buttons, 5s polling |
| `Views/Settings/ClipboardSettingsView.swift` | 21 | `ClipboardSettingsView` | Auto-copy + restore-clipboard toggles |
| `Views/Settings/MemorySettingsView.swift` | 32 | `MemorySettingsView` | ModelUnloadPolicy picker |
| `Views/Settings/WordFixSettingsView.swift` | 87 | `WordFixSettingsView` | "Custom Words" label, toggle, custom word list CRUD |
| `Views/Settings/PromptEditorView.swift` | 138 | `PromptEditorView` | Modal prompt editor, presets, ${transcript} validation |
| `Views/Settings/DiagnosticsSettingsView.swift` | 151 | `DiagnosticsSettingsView` | Debug mode, log management, ASR/pipeline benchmarks |

## Views — Other (4 files, ~914 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Views/Onboarding/OnboardingView.swift` | 250 | `OnboardingView`, `StepBadge`, `IconCircle` | 4-step first-launch wizard (Welcome/Mic/Accessibility/Ready) |
| `Views/Components/HotkeyRecorderView.swift` | 209 | `HotkeyRecorderView`, `KeyCaptureNSView`, `KeyCaptureView` | Click-to-record shortcut widget, suspends Carbon during capture |
| `Views/Components/AccessibilityWarningBanner.swift` | 49 | `AccessibilityWarningBanner` | Orange banner, "Fix Now" → Permissions tab, dismissible |
| `Views/Overlay/RecordingOverlayPanel.swift` | 406 | `RecordingOverlayPanel`, `SpectrumWheelIcon`, `RainbowLipsIcon`, `OverlayCapsuleBackground`, `RecordingOverlayView`, `PolishingOverlayView` | Floating NSPanel, brand icons (spectrum wheel + rainbow lips), recording/polishing overlays; generation-counter token gating for async show/hide |

## Utilities (6 files, ~738 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Utilities/Constants.swift` | 93 | `AppConstants`, `AudioConstants`, `TimingConstants`, `LLMConstants`, `FormattingConstants` | All magic numbers, paths, thinking budget defaults |
| `Utilities/AppLogger.swift` | 125 | `AppLogger` (actor) | Dual OSLog + rotating file log, singleton |
| `Utilities/DebugLogLevel.swift` | 20 | `DebugLogLevel` (enum) | .info/.verbose/.debug with Comparable |
| `Utilities/BenchmarkSuite.swift` | 268 | `BenchmarkSuite` (@MainActor @Observable), `Result`, `PipelineBenchmarkResult` | ASR throughput + pipeline benchmarks, WER comparison |
| `Utilities/KeySymbols.swift` | 148 | `KeySymbols` (enum) | Keycode → symbol conversion, modifier formatting |
| `Utilities/WERCalculator.swift` | 84 | `WERCalculator` (enum), `Result` | Word Error Rate via edit distance |
