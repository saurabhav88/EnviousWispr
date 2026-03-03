# File Index — EnviousWispr

Quick-reference for every source file. Use this to find files by domain or purpose.

**68 Swift files, ~14,007 lines** in `Sources/EnviousWispr/`

## App (4 files, ~1,420 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `App/AppDelegate.swift` | 423 | `AppDelegate` (@MainActor) | Menu bar NSStatusItem, Sparkle updater, MenuBarIconAnimator lifecycle, Carbon hotkey startup; stores NotificationCenter observer token |
| `App/AppState.swift` | 590 | `AppState` (@MainActor @Observable), `KeyValidationState` | Root observable, owns all subsystems, recording toggle, transcript CRUD, settings propagation, audio device monitor wiring, buildEngine for noise suppression, BT codec-switch recovery monitoring, smart input device selection |
| `App/EnviousWisprApp.swift` | 72 | `EnviousWisprApp` (@main), `ActionWirer` | SwiftUI entry point, single Window scene, action wiring helper |
| `App/MenuBarIconAnimator.swift` | 312 | `MenuBarIconAnimator` (@MainActor), `IconState` | CG-rendered menu bar icons — 4 states (idle/recording/processing/error), audio-reactive rainbow lips, rotating spectrum wheel |

## ASR (4 files, ~460 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `ASR/ASRManager.swift` | 147 | `ASRManager` (@MainActor @Observable) | Backend router, idle unload timer, delegates to active backend; guards against double sessions and refuses unload during streaming |
| `ASR/ASRProtocol.swift` | 76 | `ASRBackend` (protocol: Actor), `ASRError` | Unified backend interface — batch + streaming |
| `ASR/ParakeetBackend.swift` | 129 | `ParakeetBackend` (actor) | FluidAudio/CoreML backend, streaming support via StreamingAsrManager; cancels existing streamingManager before creating new one |
| `ASR/WhisperKitBackend.swift` | 108 | `WhisperKitBackend` (actor) | ArgMax WhisperKit backend, batch-only, makeDecodeOptions(), temperature fallback retry, model pre-warming |

## Audio (4 files, ~1,309 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Audio/AudioBufferProcessor.swift` | 35 | `AudioBufferProcessor` (enum), `AudioError` | Pure RMS calculation utility |
| `Audio/AudioCaptureManager.swift` | 699 | `AudioCaptureManager` (@MainActor @Observable) | AVAudioEngine mic capture, resamples to 16kHz mono, two-phase start (buildEngine then startCapture), BT codec-switch recovery via kAudioDevicePropertyDeviceIsAlive, format stabilization, preWarm(), buildEngine(), setInputDevice(), voice processing enable/disable, AVAudioEngineConfigurationChange observer; emergencyTeardown(), trackTask(), onEngineInterrupted, maxRecordingDurationSeconds cap |
| `Audio/AudioDeviceManager.swift` | 273 | `AudioInputDevice` (struct), `AudioDeviceEnumerator` (enum), `AudioDeviceMonitor` (class) | CoreAudio device enumeration, UID persistence, connect/disconnect monitoring, Bluetooth device detection, smart input device selection, recommendedInputDevice(), built-in mic fallback |
| `Audio/SilenceDetector.swift` | 302 | `SilenceDetector` (actor), `SmoothedVADConfig`, `SmoothedVADPhase`, `SpeechSegment` | Silero VAD wrapper, 3-phase state machine (idle/speech/hangover), auto-stop |

## LLM (10 files, ~1,708 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `LLM/AppleIntelligenceConnector.swift` | 140 | `AppleIntelligenceConnector` (struct), `CleanedTranscript` | On-device via FoundationModels (macOS 26+) |
| `LLM/GeminiConnector.swift` | 260 | `GeminiConnector` (struct: TranscriptPolisher) | Google Gemini, SSE streaming + batch, systemInstruction field, thinking budget |
| `LLM/KeychainManager.swift` | 119 | `KeychainManager` (struct: Sendable) | File-based key storage (~/.enviouswispr-keys/), 0600 perms |
| `LLM/LLMModelDiscovery.swift` | 314 | `LLMModelDiscovery` (struct: Sendable) | Discovers models from all providers, concurrent probing |
| `LLM/LLMNetworkSession.swift` | 52 | `LLMNetworkSession` (final class: Sendable) | Singleton URLSession, HTTP/2 reuse, TLS pre-warm |
| `LLM/LLMProtocol.swift` | 128 | `TranscriptPolisher` (protocol), `LLMError` | Polisher interface, error types, preamble stripping |
| `LLM/LLMRetryPolicy.swift` | 29 | `LLMRetryPolicy` (enum) | Shared retry infrastructure, isRetryable() for transient errors |
| `LLM/OllamaConnector.swift` | 143 | `OllamaConnector` (struct: TranscriptPolisher) | Local Ollama, OpenAI-compatible endpoint |
| `LLM/OllamaSetupService.swift` | 426 | `OllamaSetupService` (@MainActor @Observable), `OllamaSetupState`, `OllamaModelCatalogEntry` | Ollama install/start/pull wizard, static modelCatalog with quality tiers, isWeakModel(), pullModel(), deleteModel() |
| `LLM/OpenAIConnector.swift` | 137 | `OpenAIConnector` (struct: TranscriptPolisher) | OpenAI chat completions, reasoning effort for o-series models |

## Models (4 files, ~266 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Models/AppSettings.swift` | 80 | `RecordingMode`, `PipelineState`, `ModelUnloadPolicy` | Core enums for pipeline state and recording modes |
| `Models/ASRResult.swift` | 39 | `ASRBackendType`, `ASRResult`, `TranscriptSegment`, `TranscriptionOptions` | ASR output types |
| `Models/LLMResult.swift` | 103 | `LLMProvider`, `LLMResult`, `LLMProviderConfig`, `LLMModelInfo`, `PolishInstructions`, `PromptPreset` | LLM types, polish instructions, prompt presets |
| `Models/Transcript.swift` | 44 | `Transcript` (struct: Codable) | Full transcript record with polished/raw text, metadata |

## Pipeline (5 files, ~857 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Pipeline/Steps/FillerRemovalStep.swift` | 57 | `FillerRemovalStep` (@MainActor) | Regex-based filler word removal (um, uh, etc.) |
| `Pipeline/Steps/LLMPolishStep.swift` | 113 | `LLMPolishStep` (@MainActor) | Selects LLM connector, resolves ${transcript} placeholder, streams tokens, extended thinking config |
| `Pipeline/Steps/WordCorrectionStep.swift` | 28 | `WordCorrectionStep` (@MainActor) | Runs WordCorrector against custom word list |
| `Pipeline/TextProcessingStep.swift` | 32 | `TextProcessingContext` (struct), `TextProcessingStep` (protocol) | Step interface and context carrier for processing chain |
| `Pipeline/TranscriptionPipeline.swift` | 686 | `TranscriptionPipeline` (@MainActor @Observable) | Core orchestrator — state machine, streaming/batch ASR, VAD monitoring, text processing, paste; wires onEngineInterrupted, preWarmAudioInput(), two-phase engine startup, finalizeStreaming timeout with defer cleanup |

## PostProcessing (2 files, ~176 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `PostProcessing/CustomWordStore.swift` | 38 | `CustomWordStore` (final class: Sendable) | Persists custom words as JSON |
| `PostProcessing/WordCorrector.swift` | 138 | `WordCorrector` (struct: Sendable) | Fuzzy matching: Levenshtein(40%) + bigram Dice(40%) + Soundex(20%), threshold 0.82 |

## Services (4 files, ~1,023 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Services/HotkeyService.swift` | 415 | `HotkeyService` (@MainActor @Observable), `ModifierKeyCodes`, `HotkeyID` | Carbon RegisterEventHotKey, NSEvent monitors, suspend/resume for recorder, onPreWarmAudio callback for PTT key-down |
| `Services/PasteService.swift` | 130 | `PasteService` (enum), `ClipboardSnapshot` | Clipboard save/restore, CGEvent Cmd+V paste simulation |
| `Services/PermissionsService.swift` | 79 | `PermissionsService` (@MainActor @Observable) | Mic (AVFoundation) + Accessibility (AXIsProcessTrusted) checks |
| `Services/SettingsManager.swift` | 399 | `SettingsManager` (@MainActor @Observable), `SettingKey` (31 cases) | All UserDefaults persistence — includes whiskerKitLanguageAutoDetect, whisperKitTemperature, whisperKitNoSpeechThreshold, selectedInputDeviceUID, noiseSuppression, preferredInputDeviceIDOverride |

## Storage (1 file, ~104 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Storage/TranscriptStore.swift` | 104 | `TranscriptStore` (@MainActor) | JSON file store in ~/Library/Application Support/, async load |

## Utilities (6 files, ~691 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Utilities/AppLogger.swift` | 125 | `AppLogger` (actor) | Dual OSLog + rotating file log, singleton |
| `Utilities/BenchmarkSuite.swift` | 268 | `BenchmarkSuite` (@MainActor @Observable), `Result`, `PipelineBenchmarkResult` | ASR throughput + pipeline benchmarks, WER comparison |
| `Utilities/Constants.swift` | 82 | `AppConstants`, `AudioConstants`, `TimingConstants`, `LLMConstants`, `FormattingConstants` | All magic numbers, paths, thinking budget defaults |
| `Utilities/DebugLogLevel.swift` | 20 | `DebugLogLevel` (enum) | .info/.verbose/.debug with Comparable |
| `Utilities/KeySymbols.swift` | 148 | `KeySymbols` (enum) | Keycode → symbol conversion, modifier formatting |
| `Utilities/WERCalculator.swift` | 48 | `WERCalculator` (enum), `Result` | Word Error Rate via edit distance |

## Views — Components (2 files, ~258 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Views/Components/AccessibilityWarningBanner.swift` | 49 | `AccessibilityWarningBanner` | Orange banner, "Fix Now" → Permissions tab, dismissible |
| `Views/Components/HotkeyRecorderView.swift` | 209 | `HotkeyRecorderView`, `KeyCaptureNSView`, `KeyCaptureView` | Click-to-record shortcut widget, suspends Carbon during capture |

## Views — Main (5 files, ~682 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Views/Main/HistoryContentView.swift` | 30 | `HistoryContentView` | HSplitView: sidebar + detail, accessibility banner |
| `Views/Main/MainWindowView.swift` | 314 | `StatusView`, `PulsingRingsView`, `WaveformView`, `AudioLevelBar`, `StatusBadge`, `RecordButton` | Recording state display, toolbar components |
| `Views/Main/SidebarStatsHeader.swift` | 94 | `SidebarStatsHeader`, `ModelStatusBar` | Search field, transcript count, model status dot |
| `Views/Main/TranscriptDetailView.swift` | 136 | `TranscriptDetailView` | Copy/Paste/Enhance toolbar, dual-pane polished+original |
| `Views/Main/TranscriptHistoryView.swift` | 108 | `TranscriptHistoryView`, `TranscriptRowView` | Sidebar list with search, badges, delete-all |

## Views — Onboarding (4 files, ~2,970 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Views/Onboarding/OnboardingV2View.swift` | 927 | `OnboardingV2View`, `OnboardingV2ViewModel`, `KeycapHotkeyView` | 3-screen first-launch flow (Welcome/Setting Up/Ready to Wispr), auto-install, permissions, DNA equalizer + heart animations |
| `Views/Onboarding/OnboardingDesignTokens.swift` | 76 | `OnboardingButtonStyle` | Design tokens — Color/Font extensions + parameterized button style |
| `Views/Onboarding/RainbowLipsView.swift` | 460 | `RainbowLipsView`, `LipsAnimationState`, `LipsBar`, `EqBarConfig`, `LipsData` | Animated rainbow lips component — 12 animation states (idle/denied/happy/equalizer/wave/drooping/shimmer/recording/pulse/smile/triumph/heart) |
| `Views/Onboarding/OnboardingView.swift` | 1507 | `OnboardingView` (deprecated) | Old 5-step wizard — dead code, superseded by OnboardingV2View |

## Views — Overlay (1 file, ~457 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Views/Overlay/RecordingOverlayPanel.swift` | 457 | `RecordingOverlayPanel`, `SpectrumWheelIcon`, `RainbowLipsIcon`, `OverlayCapsuleBackground`, `RecordingOverlayView`, `PolishingOverlayView` | Floating NSPanel, brand icons (spectrum wheel + rainbow lips), recording/polishing overlays; generation-counter token gating for async show/hide |

## Views — Settings (11 files, ~1,548 lines)

| File | Lines | Key Types | Purpose |
|------|-------|-----------|---------|
| `Views/Settings/AIPolishSettingsView.swift` | 668 | `AIPolishSettingsView` | LLM provider/model picker, API key entry, None-state explainer, fixed OpenAI model picker, Ollama model catalog with quality tiers + download buttons, weak model prompt restrictions, Apple Intelligence, extended thinking toggle |
| `Views/Settings/AudioSettingsView.swift` | 42 | `AudioSettingsView` | Audio input device picker (Auto/manual) with BT output detection, noise suppression toggle |
| `Views/Settings/ClipboardSettingsView.swift` | 21 | `ClipboardSettingsView` | Auto-copy + restore-clipboard toggles |
| `Views/Settings/DiagnosticsSettingsView.swift` | 150 | `DiagnosticsSettingsView` | Debug mode, log management, ASR/pipeline benchmarks |
| `Views/Settings/MemorySettingsView.swift` | 32 | `MemorySettingsView` | ModelUnloadPolicy picker |
| `Views/Settings/PermissionsSettingsView.swift` | 58 | `PermissionsSettingsView` | Mic + Accessibility status, request buttons, 5s polling |
| `Views/Settings/PromptEditorView.swift` | 138 | `PromptEditorView` | Modal prompt editor, presets, ${transcript} validation |
| `Views/Settings/SettingsSection.swift` | 69 | `SettingsSection` (enum), `SettingsGroup` (enum) | 10 sections in 5 groups (APP/RECORD/PROCESS/OUTPUT/SYSTEM), includes `.audio` |
| `Views/Settings/SettingsView.swift` | 71 | `UnifiedWindowView` | Root NavigationSplitView, sidebar sections, onboarding sheet, `.audio` case routing |
| `Views/Settings/SpeechEngineSettingsView.swift` | 127 | `SpeechEngineSettingsView` | Backend picker, VAD controls (auto-stop, sensitivity, energy gate), WhisperKit quality controls (temperature, no-speech threshold, language auto-detect), filler removal |
| `Views/Settings/WordFixSettingsView.swift` | 92 | `WordFixSettingsView` | "Custom Words" label, toggle, custom word list CRUD |
