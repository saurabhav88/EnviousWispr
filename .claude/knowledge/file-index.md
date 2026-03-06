<!-- GENERATED — do not hand-edit. Run scripts/brain-refresh.sh to update. -->

# File Index -- EnviousWispr

Quick-reference for every source file. Auto-generated from source tree.

## Sources/EnviousWispr/App (4 files, ~1599 lines)

| File | Lines | Path |
|------|-------|------|
| `AppDelegate.swift` | 444 | `Sources/EnviousWispr/App/AppDelegate.swift` |
| `AppState.swift` | 771 | `Sources/EnviousWispr/App/AppState.swift` |
| `EnviousWisprApp.swift` | 72 | `Sources/EnviousWispr/App/EnviousWisprApp.swift` |
| `MenuBarIconAnimator.swift` | 312 | `Sources/EnviousWispr/App/MenuBarIconAnimator.swift` |

## Sources/EnviousWispr/ASR (5 files, ~658 lines)

| File | Lines | Path |
|------|-------|------|
| `ASRManager.swift` | 148 | `Sources/EnviousWispr/ASR/ASRManager.swift` |
| `ASRProtocol.swift` | 76 | `Sources/EnviousWispr/ASR/ASRProtocol.swift` |
| `ParakeetBackend.swift` | 129 | `Sources/EnviousWispr/ASR/ParakeetBackend.swift` |
| `WhisperKitBackend.swift` | 133 | `Sources/EnviousWispr/ASR/WhisperKitBackend.swift` |
| `WhisperKitSetupService.swift` | 172 | `Sources/EnviousWispr/ASR/WhisperKitSetupService.swift` |

## Sources/EnviousWispr/Audio (4 files, ~1313 lines)

| File | Lines | Path |
|------|-------|------|
| `AudioBufferProcessor.swift` | 35 | `Sources/EnviousWispr/Audio/AudioBufferProcessor.swift` |
| `AudioCaptureManager.swift` | 699 | `Sources/EnviousWispr/Audio/AudioCaptureManager.swift` |
| `AudioDeviceManager.swift` | 273 | `Sources/EnviousWispr/Audio/AudioDeviceManager.swift` |
| `SilenceDetector.swift` | 306 | `Sources/EnviousWispr/Audio/SilenceDetector.swift` |

## Sources/EnviousWispr/LLM (10 files, ~1792 lines)

| File | Lines | Path |
|------|-------|------|
| `AppleIntelligenceConnector.swift` | 163 | `Sources/EnviousWispr/LLM/AppleIntelligenceConnector.swift` |
| `GeminiConnector.swift` | 260 | `Sources/EnviousWispr/LLM/GeminiConnector.swift` |
| `KeychainManager.swift` | 119 | `Sources/EnviousWispr/LLM/KeychainManager.swift` |
| `LLMModelDiscovery.swift` | 335 | `Sources/EnviousWispr/LLM/LLMModelDiscovery.swift` |
| `LLMNetworkSession.swift` | 52 | `Sources/EnviousWispr/LLM/LLMNetworkSession.swift` |
| `LLMProtocol.swift` | 128 | `Sources/EnviousWispr/LLM/LLMProtocol.swift` |
| `LLMRetryPolicy.swift` | 29 | `Sources/EnviousWispr/LLM/LLMRetryPolicy.swift` |
| `OllamaConnector.swift` | 143 | `Sources/EnviousWispr/LLM/OllamaConnector.swift` |
| `OllamaSetupService.swift` | 426 | `Sources/EnviousWispr/LLM/OllamaSetupService.swift` |
| `OpenAIConnector.swift` | 137 | `Sources/EnviousWispr/LLM/OpenAIConnector.swift` |

## Sources/EnviousWispr/Models (4 files, ~258 lines)

| File | Lines | Path |
|------|-------|------|
| `AppSettings.swift` | 80 | `Sources/EnviousWispr/Models/AppSettings.swift` |
| `ASRResult.swift` | 31 | `Sources/EnviousWispr/Models/ASRResult.swift` |
| `LLMResult.swift` | 103 | `Sources/EnviousWispr/Models/LLMResult.swift` |
| `Transcript.swift` | 44 | `Sources/EnviousWispr/Models/Transcript.swift` |

## Sources/EnviousWispr/Pipeline (4 files, ~1318 lines)

| File | Lines | Path |
|------|-------|------|
| `DictationPipeline.swift` | 25 | `Sources/EnviousWispr/Pipeline/DictationPipeline.swift` |
| `TextProcessingStep.swift` | 32 | `Sources/EnviousWispr/Pipeline/TextProcessingStep.swift` |
| `TranscriptionPipeline.swift` | 788 | `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` |
| `WhisperKitPipeline.swift` | 473 | `Sources/EnviousWispr/Pipeline/WhisperKitPipeline.swift` |

## Sources/EnviousWispr/Pipeline/Steps (3 files, ~198 lines)

| File | Lines | Path |
|------|-------|------|
| `FillerRemovalStep.swift` | 57 | `Sources/EnviousWispr/Pipeline/Steps/FillerRemovalStep.swift` |
| `LLMPolishStep.swift` | 113 | `Sources/EnviousWispr/Pipeline/Steps/LLMPolishStep.swift` |
| `WordCorrectionStep.swift` | 28 | `Sources/EnviousWispr/Pipeline/Steps/WordCorrectionStep.swift` |

## Sources/EnviousWispr/PostProcessing (2 files, ~176 lines)

| File | Lines | Path |
|------|-------|------|
| `CustomWordStore.swift` | 38 | `Sources/EnviousWispr/PostProcessing/CustomWordStore.swift` |
| `WordCorrector.swift` | 138 | `Sources/EnviousWispr/PostProcessing/WordCorrector.swift` |

## Sources/EnviousWispr/Services (4 files, ~1151 lines)

| File | Lines | Path |
|------|-------|------|
| `HotkeyService.swift` | 409 | `Sources/EnviousWispr/Services/HotkeyService.swift` |
| `PasteService.swift` | 254 | `Sources/EnviousWispr/Services/PasteService.swift` |
| `PermissionsService.swift` | 79 | `Sources/EnviousWispr/Services/PermissionsService.swift` |
| `SettingsManager.swift` | 409 | `Sources/EnviousWispr/Services/SettingsManager.swift` |

## Sources/EnviousWispr/Storage (1 files, ~104 lines)

| File | Lines | Path |
|------|-------|------|
| `TranscriptStore.swift` | 104 | `Sources/EnviousWispr/Storage/TranscriptStore.swift` |

## Sources/EnviousWispr/Utilities (6 files, ~715 lines)

| File | Lines | Path |
|------|-------|------|
| `AppLogger.swift` | 125 | `Sources/EnviousWispr/Utilities/AppLogger.swift` |
| `BenchmarkSuite.swift` | 268 | `Sources/EnviousWispr/Utilities/BenchmarkSuite.swift` |
| `Constants.swift` | 94 | `Sources/EnviousWispr/Utilities/Constants.swift` |
| `DebugLogLevel.swift` | 20 | `Sources/EnviousWispr/Utilities/DebugLogLevel.swift` |
| `KeySymbols.swift` | 160 | `Sources/EnviousWispr/Utilities/KeySymbols.swift` |
| `WERCalculator.swift` | 48 | `Sources/EnviousWispr/Utilities/WERCalculator.swift` |

## Sources/EnviousWispr/Views/Components (2 files, ~275 lines)

| File | Lines | Path |
|------|-------|------|
| `AccessibilityWarningBanner.swift` | 49 | `Sources/EnviousWispr/Views/Components/AccessibilityWarningBanner.swift` |
| `HotkeyRecorderView.swift` | 226 | `Sources/EnviousWispr/Views/Components/HotkeyRecorderView.swift` |

## Sources/EnviousWispr/Views/Main (5 files, ~645 lines)

| File | Lines | Path |
|------|-------|------|
| `HistoryContentView.swift` | 30 | `Sources/EnviousWispr/Views/Main/HistoryContentView.swift` |
| `MainWindowView.swift` | 310 | `Sources/EnviousWispr/Views/Main/MainWindowView.swift` |
| `SidebarStatsHeader.swift` | 94 | `Sources/EnviousWispr/Views/Main/SidebarStatsHeader.swift` |
| `TranscriptDetailView.swift` | 113 | `Sources/EnviousWispr/Views/Main/TranscriptDetailView.swift` |
| `TranscriptHistoryView.swift` | 98 | `Sources/EnviousWispr/Views/Main/TranscriptHistoryView.swift` |

## Sources/EnviousWispr/Views/Onboarding (3 files, ~1463 lines)

| File | Lines | Path |
|------|-------|------|
| `OnboardingDesignTokens.swift` | 76 | `Sources/EnviousWispr/Views/Onboarding/OnboardingDesignTokens.swift` |
| `OnboardingV2View.swift` | 927 | `Sources/EnviousWispr/Views/Onboarding/OnboardingV2View.swift` |
| `RainbowLipsView.swift` | 460 | `Sources/EnviousWispr/Views/Onboarding/RainbowLipsView.swift` |

## Sources/EnviousWispr/Views/Overlay (1 files, ~458 lines)

| File | Lines | Path |
|------|-------|------|
| `RecordingOverlayPanel.swift` | 458 | `Sources/EnviousWispr/Views/Overlay/RecordingOverlayPanel.swift` |

## Sources/EnviousWispr/Views/Settings (14 files, ~2268 lines)

| File | Lines | Path |
|------|-------|------|
| `AIPolishSettingsView.swift` | 777 | `Sources/EnviousWispr/Views/Settings/AIPolishSettingsView.swift` |
| `AudioSettingsView.swift` | 48 | `Sources/EnviousWispr/Views/Settings/AudioSettingsView.swift` |
| `ClipboardSettingsView.swift` | 28 | `Sources/EnviousWispr/Views/Settings/ClipboardSettingsView.swift` |
| `DiagnosticsSettingsView.swift` | 189 | `Sources/EnviousWispr/Views/Settings/DiagnosticsSettingsView.swift` |
| `MemorySettingsView.swift` | 36 | `Sources/EnviousWispr/Views/Settings/MemorySettingsView.swift` |
| `PermissionsSettingsView.swift` | 41 | `Sources/EnviousWispr/Views/Settings/PermissionsSettingsView.swift` |
| `PromptEditorView.swift` | 138 | `Sources/EnviousWispr/Views/Settings/PromptEditorView.swift` |
| `SettingsComponents.swift` | 345 | `Sources/EnviousWispr/Views/Settings/SettingsComponents.swift` |
| `SettingsDesignTokens.swift` | 74 | `Sources/EnviousWispr/Views/Settings/SettingsDesignTokens.swift` |
| `SettingsSection.swift` | 69 | `Sources/EnviousWispr/Views/Settings/SettingsSection.swift` |
| `SettingsView.swift` | 82 | `Sources/EnviousWispr/Views/Settings/SettingsView.swift` |
| `ShortcutsSettingsView.swift` | 52 | `Sources/EnviousWispr/Views/Settings/ShortcutsSettingsView.swift` |
| `SpeechEngineSettingsView.swift` | 291 | `Sources/EnviousWispr/Views/Settings/SpeechEngineSettingsView.swift` |
| `WordFixSettingsView.swift` | 98 | `Sources/EnviousWispr/Views/Settings/WordFixSettingsView.swift` |

---

**Total: 72 Swift files, ~14391 lines**
