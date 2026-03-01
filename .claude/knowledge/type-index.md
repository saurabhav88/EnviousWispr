# Type Index — EnviousWispr

Reverse lookup: type name → file, isolation, category. Use this to find where any type is defined.

## Protocols

| Protocol | File | Isolation | Conformers |
|----------|------|-----------|------------|
| `ASRBackend` | `ASR/ASRProtocol.swift` | `: Actor` | `ParakeetBackend`, `WhisperKitBackend` |
| `TranscriptPolisher` | `LLM/LLMProtocol.swift` | `: Sendable` | `OpenAIConnector`, `GeminiConnector`, `OllamaConnector`, `AppleIntelligenceConnector` |
| `TextProcessingStep` | `Pipeline/TextProcessingStep.swift` | `@MainActor` | `LLMPolishStep`, `WordCorrectionStep` |

## Actors (true Swift actors — own executor)

| Actor | File | Purpose |
|-------|------|---------|
| `SilenceDetector` | `Audio/SilenceDetector.swift` | Silero VAD, 3-phase speech detection |
| `ParakeetBackend` | `ASR/ParakeetBackend.swift` | FluidAudio ASR, batch + streaming |
| `WhisperKitBackend` | `ASR/WhisperKitBackend.swift` | WhisperKit ASR, batch only |
| `AppLogger` | `Utilities/AppLogger.swift` | Thread-safe logging singleton |

## @MainActor @Observable Classes

| Class | File | Purpose |
|-------|------|---------|
| `AppState` | `App/AppState.swift` | Root observable, owns everything |
| `TranscriptionPipeline` | `Pipeline/TranscriptionPipeline.swift` | Core state machine orchestrator |
| `ASRManager` | `ASR/ASRManager.swift` | Backend router + idle timer |
| `AudioCaptureManager` | `Audio/AudioCaptureManager.swift` | AVAudioEngine mic capture |
| `HotkeyService` | `Services/HotkeyService.swift` | Carbon hotkeys + NSEvent monitors |
| `PermissionsService` | `Services/PermissionsService.swift` | Mic + Accessibility checks |
| `SettingsManager` | `Services/SettingsManager.swift` | UserDefaults persistence (26 keys) |
| `OllamaSetupService` | `LLM/OllamaSetupService.swift` | Ollama install wizard |
| `BenchmarkSuite` | `Utilities/BenchmarkSuite.swift` | ASR/pipeline benchmarks |

## @MainActor Classes (not Observable)

| Class | File | Purpose |
|-------|------|---------|
| `AppDelegate` | `App/AppDelegate.swift` | Menu bar, Sparkle, lifecycle |
| `TranscriptStore` | `Storage/TranscriptStore.swift` | JSON file persistence |
| `RecordingOverlayPanel` | `Views/Overlay/RecordingOverlayPanel.swift` | Floating NSPanel |
| `MenuBarIconAnimator` | `App/MenuBarIconAnimator.swift` | CG-rendered 4-state menu bar icons, audio-reactive |
| `LLMPolishStep` | `Pipeline/Steps/LLMPolishStep.swift` | LLM polish with extended thinking |
| `WordCorrectionStep` | `Pipeline/Steps/WordCorrectionStep.swift` | Custom word fuzzy matching |

## Sendable Classes

| Class | File | Purpose |
|-------|------|---------|
| `LLMNetworkSession` | `LLM/LLMNetworkSession.swift` | Singleton URLSession wrapper for API requests |
| `CustomWordStore` | `PostProcessing/CustomWordStore.swift` | Persists custom words as JSON |

## Sendable Structs (data types)

| Struct | File | Key Fields |
|--------|------|------------|
| `ASRResult` | `Models/ASRResult.swift` | text, segments, language, duration, processingTime, confidence, backendType |
| `TranscriptSegment` | `Models/ASRResult.swift` | text, startTime, endTime |
| `TranscriptionOptions` | `Models/ASRResult.swift` | language?, enableTimestamps |
| `Transcript` | `Models/Transcript.swift` | id, text, polishedText?, duration, processingTime, backendType, createdAt, llmProvider? |
| `LLMResult` | `Models/LLMResult.swift` | polishedText, provider, model |
| `LLMProviderConfig` | `Models/LLMResult.swift` | provider, model, apiKeyKeychainId?, maxTokens, temperature, thinkingBudget?, reasoningEffort? |
| `LLMModelInfo` | `Models/LLMResult.swift` | id, displayName, provider, isAvailable |
| `PolishInstructions` | `Models/LLMResult.swift` | systemPrompt, removeFillerWords, fixGrammar, fixPunctuation |
| `ClipboardSnapshot` | `Services/PasteService.swift` | items, changeCount |
| `SmoothedVADConfig` | `Audio/SilenceDetector.swift` | thresholds, chunk counts, energy gate |
| `SpeechSegment` | `Audio/SilenceDetector.swift` | startSample, endSample |
| `KeychainManager` | `LLM/KeychainManager.swift` | file-based key store |
| `WordCorrector` | `PostProcessing/WordCorrector.swift` | fuzzy matching engine |
| `LLMModelDiscovery` | `LLM/LLMModelDiscovery.swift` | multi-provider model discovery |
| `BenchmarkSuite.Result` | `Utilities/BenchmarkSuite.swift` | label, audioDuration, processingTime, rtf, backend |
| `BenchmarkSuite.PipelineBenchmarkResult` | `Utilities/BenchmarkSuite.swift` | batchASRTime, streamingFinalizeTime, werDelta |
| `WERCalculator.Result` | `Utilities/WERCalculator.swift` | WER calculation result |
| `TextProcessingContext` | `Pipeline/TextProcessingStep.swift` | text, polishedText?, llmProvider?, llmModel? |

## Sendable Structs (LLM connectors)

| Struct | File | Endpoint |
|--------|------|----------|
| `OpenAIConnector` | `LLM/OpenAIConnector.swift` | `api.openai.com/v1/chat/completions` |
| `GeminiConnector` | `LLM/GeminiConnector.swift` | `generativelanguage.googleapis.com/v1beta/...` |
| `OllamaConnector` | `LLM/OllamaConnector.swift` | `localhost:11434/v1/chat/completions` |
| `AppleIntelligenceConnector` | `LLM/AppleIntelligenceConnector.swift` | On-device FoundationModels (macOS 26+) |

## Enums (state/config)

| Enum | File | Cases |
|------|------|-------|
| `PipelineState` | `Models/AppSettings.swift` | idle, recording, transcribing, polishing, complete, error(String) |
| `RecordingMode` | `Models/AppSettings.swift` | pushToTalk, toggle |
| `ModelUnloadPolicy` | `Models/AppSettings.swift` | never, immediately, 2/5/10/15/60 min |
| `ASRBackendType` | `Models/ASRResult.swift` | parakeet, whisperKit |
| `LLMProvider` | `Models/LLMResult.swift` | openAI, gemini, ollama, appleIntelligence, none |
| `PromptPreset` | `Models/LLMResult.swift` | cleanUp, formal, casual |
| `DebugLogLevel` | `Utilities/DebugLogLevel.swift` | info, verbose, debug |
| `SettingKey` | `Services/SettingsManager.swift` | 26 cases for all UserDefaults keys (nested in SettingsManager) |
| `ASRError` | `ASR/ASRProtocol.swift` | notReady, modelLoadFailed, transcriptionFailed, streamingNotSupported |
| `AudioError` | `Audio/AudioBufferProcessor.swift` | formatCreationFailed |
| `LLMError` | `LLM/LLMProtocol.swift` | invalidAPIKey, requestFailed, rateLimited, emptyResponse, providerUnavailable, modelNotFound, frameworkUnavailable |
| `KeychainError` | `LLM/KeychainManager.swift` | storeFailed, retrieveFailed, deleteFailed |
| `SmoothedVADPhase` | `Audio/SilenceDetector.swift` | idle, speech, hangover(chunksRemaining) |
| `OllamaSetupState` | `LLM/OllamaSetupService.swift` | detecting, notInstalled, installedNotRunning, runningNoModels, pullingModel, ready, error |
| `KeyValidationState` | `App/AppState.swift` | idle, validating, valid, invalid(String) |
| `IconState` | `App/MenuBarIconAnimator.swift` | idle, recording, processing, error (nested in MenuBarIconAnimator) |
| `StepState` | `Views/Onboarding/OnboardingView.swift` | completed, current, upcoming |
| `HotkeyID` | `Services/HotkeyService.swift` | toggle(1), ptt(2), cancel(3) (private nested in HotkeyService) |
| `SettingsSection` | `Views/Settings/SettingsSection.swift` | history, speechEngine, shortcuts, aiPolish, wordCorrection, clipboard, memory, permissions, diagnostics |
| `SettingsGroup` | `Views/Settings/SettingsSection.swift` | app, record, process, output, system |

## Enum Namespaces (no cases, static members only)

| Enum | File | Purpose |
|------|------|---------|
| `AppConstants` | `Utilities/Constants.swift` | App name, paths |
| `AudioConstants` | `Utilities/Constants.swift` | Sample rate, buffer size |
| `TimingConstants` | `Utilities/Constants.swift` | Delays, intervals |
| `LLMConstants` | `Utilities/Constants.swift` | Max tokens, probe limits, thinking budget |
| `FormattingConstants` | `Utilities/Constants.swift` | Duration formatting |
| `PasteService` | `Services/PasteService.swift` | Clipboard/paste operations |
| `AudioBufferProcessor` | `Audio/AudioBufferProcessor.swift` | RMS calculation |
| `KeySymbols` | `Utilities/KeySymbols.swift` | Keycode formatting |
| `WERCalculator` | `Utilities/WERCalculator.swift` | Word error rate |
| `ModifierKeyCodes` | `Services/HotkeyService.swift` | Modifier key code constants |

## SwiftUI Views

| View | File | Parent Context |
|------|------|---------------|
| `UnifiedWindowView` | `Views/Settings/SettingsView.swift` | Window root — NavigationSplitView |
| `HistoryContentView` | `Views/Main/HistoryContentView.swift` | History tab — HSplitView |
| `TranscriptHistoryView` | `Views/Main/TranscriptHistoryView.swift` | Sidebar list |
| `TranscriptRowView` | `Views/Main/TranscriptHistoryView.swift` | List row |
| `TranscriptDetailView` | `Views/Main/TranscriptDetailView.swift` | Detail pane |
| `SidebarStatsHeader` | `Views/Main/SidebarStatsHeader.swift` | Above sidebar list |
| `ModelStatusBar` | `Views/Main/SidebarStatsHeader.swift` | Inside stats header |
| `StatusView` | `Views/Main/MainWindowView.swift` | Detail when no transcript |
| `PulsingRingsView` | `Views/Main/MainWindowView.swift` | Recording animation |
| `WaveformView` | `Views/Main/MainWindowView.swift` | Audio level bars |
| `AudioLevelBar` | `Views/Main/MainWindowView.swift` | Horizontal level bar |
| `StatusBadge` | `Views/Main/MainWindowView.swift` | Toolbar status |
| `RecordButton` | `Views/Main/MainWindowView.swift` | Toolbar record toggle |
| `OnboardingView` | `Views/Onboarding/OnboardingView.swift` | Modal sheet on first launch |
| `StepBadge` | `Views/Onboarding/OnboardingView.swift` | Onboarding step indicator |
| `IconCircle` | `Views/Onboarding/OnboardingView.swift` | Onboarding icon circle |
| `HotkeyRecorderView` | `Views/Components/HotkeyRecorderView.swift` | Shortcut capture widget |
| `AccessibilityWarningBanner` | `Views/Components/AccessibilityWarningBanner.swift` | Top-of-history warning |
| `SpectrumWheelIcon` | `Views/Overlay/RecordingOverlayPanel.swift` | Rotating rainbow spectrum wheel (processing state) |
| `RainbowLipsIcon` | `Views/Overlay/RecordingOverlayPanel.swift` | Rainbow cupid's bow lips with bounce animation |
| `OverlayCapsuleBackground` | `Views/Overlay/RecordingOverlayPanel.swift` | Capsule background for overlay (private) |
| `RecordingOverlayView` | `Views/Overlay/RecordingOverlayPanel.swift` | Floating recording indicator |
| `PolishingOverlayView` | `Views/Overlay/RecordingOverlayPanel.swift` | Floating polishing indicator |
| `ActionWirer` | `App/EnviousWisprApp.swift` | Invisible view wiring window actions (private) |
| `SpeechEngineSettingsView` | `Views/Settings/SpeechEngineSettingsView.swift` | Settings tab |
| `AIPolishSettingsView` | `Views/Settings/AIPolishSettingsView.swift` | Settings tab (512 lines — largest view) |
| `ShortcutsSettingsView` | `Views/Settings/ShortcutsSettingsView.swift` | Settings tab |
| `PermissionsSettingsView` | `Views/Settings/PermissionsSettingsView.swift` | Settings tab |
| `ClipboardSettingsView` | `Views/Settings/ClipboardSettingsView.swift` | Settings tab |
| `MemorySettingsView` | `Views/Settings/MemorySettingsView.swift` | Settings tab |
| `WordFixSettingsView` | `Views/Settings/WordFixSettingsView.swift` | Settings tab |
| `PromptEditorView` | `Views/Settings/PromptEditorView.swift` | Modal prompt editor |
| `DiagnosticsSettingsView` | `Views/Settings/DiagnosticsSettingsView.swift` | Settings tab |

## NSView Subclasses

| Class | File | Purpose |
|-------|------|---------|
| `KeyCaptureNSView` | `Views/Components/HotkeyRecorderView.swift` | Raw key event capture for shortcut recording (private) |

## NSViewRepresentable Wrappers

| Struct | File | Purpose |
|--------|------|---------|
| `KeyCaptureView` | `Views/Components/HotkeyRecorderView.swift` | SwiftUI bridge for KeyCaptureNSView (private) |
