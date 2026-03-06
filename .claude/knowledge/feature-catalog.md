<!-- GENERATED — do not hand-edit. Run scripts/brain-refresh.sh to update. -->

# Feature Catalog -- EnviousWispr

Auto-generated stats from source code.

## Source Stats

- **SettingKey cases:** 52
- **Total type declarations:** 163

## Files by Directory

| Directory | Files | Lines |
|-----------|-------|-------|
| `Sources/EnviousWispr/App` | 4 | 1599 |
| `Sources/EnviousWispr/ASR` | 5 | 658 |
| `Sources/EnviousWispr/Audio` | 4 | 1313 |
| `Sources/EnviousWispr/LLM` | 10 | 1792 |
| `Sources/EnviousWispr/Models` | 4 | 258 |
| `Sources/EnviousWispr/Pipeline` | 4 | 1318 |
| `Sources/EnviousWispr/Pipeline/Steps` | 3 | 198 |
| `Sources/EnviousWispr/PostProcessing` | 2 | 176 |
| `Sources/EnviousWispr/Services` | 4 | 1151 |
| `Sources/EnviousWispr/Storage` | 1 | 104 |
| `Sources/EnviousWispr/Utilities` | 6 | 715 |
| `Sources/EnviousWispr/Views/Components` | 2 | 275 |
| `Sources/EnviousWispr/Views/Main` | 5 | 645 |
| `Sources/EnviousWispr/Views/Onboarding` | 3 | 1463 |
| `Sources/EnviousWispr/Views/Overlay` | 1 | 458 |
| `Sources/EnviousWispr/Views/Settings` | 14 | 2268 |
| **Total** | **72** | **14391** |

<!-- MANUAL SECTION BELOW — human-authored, preserved across regeneration -->

# Feature Catalog

Feature → files → settings → UI lookup. Paths relative to `Sources/EnviousWispr/`.

## Pipeline (5)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| State machine | idle→recording→transcribing→polishing→complete→error | `Pipeline/TranscriptionPipeline`, `Models/AppSettings` | — | StatusView, StatusBadge |
| Streaming ASR | Real-time audio buffers → partial transcript via `feedAudio()` | `Pipeline/TranscriptionPipeline`, `ASR/ParakeetBackend` | — | — |
| Batch ASR | Accumulated samples → full transcript post-recording | `Pipeline/TranscriptionPipeline`, `ASR/*Backend` | — | — |
| Text processing chain | Sequential post-ASR steps (word correction → LLM polish) | `Pipeline/TextProcessingStep`, `Pipeline/Steps/*` | — | — |
| Streaming finalize timeout | Timeout + batch fallback when streaming ASR stalls | `Pipeline/TranscriptionPipeline` | — | — |

## Recording Control (5)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| Push-to-talk | Hold key to record, release to stop | `Services/HotkeyService`, `Pipeline/TranscriptionPipeline` | `recordingMode` | SpeechEngineSettingsView |
| Toggle mode | Press once to start, again to stop | `Services/HotkeyService`, `Pipeline/TranscriptionPipeline` | `recordingMode` | SpeechEngineSettingsView |
| Cancel hotkey | Abort recording mid-capture | `Services/HotkeyService` | `cancelKeyCode`, `cancelModifiers` | ShortcutsSettingsView |
| Custom hotkey binding | User-assigned keyboard shortcuts for all actions | `Services/HotkeyService`, `Views/Components/HotkeyRecorderView` | `toggleKeyCode`, `pushToTalkKeyCode` | ShortcutsSettingsView |
| PTT pre-warm | BT codec switch on key-down before capture begins | `Services/HotkeyService`, `Audio/AudioCaptureManager` | — | — |

## VAD (3)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| Auto-stop on silence | Stop recording when speech ends (Silero VAD) | `Audio/SilenceDetector`, `Pipeline/TranscriptionPipeline` | `vadAutoStop`, `vadSilenceTimeout` | SpeechEngineSettingsView |
| VAD sensitivity | Smoothed VAD threshold + confirmation chunks | `Audio/SilenceDetector` | `vadSensitivity` | SpeechEngineSettingsView |
| Energy gate | RMS energy filter to reject ambient noise | `Audio/SilenceDetector` | `vadEnergyGate` | SpeechEngineSettingsView |

## Audio Input (3)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| Input device selection | Choose mic or Auto (smart BT-aware selection) | `Audio/AudioDeviceManager`, `Audio/AudioCaptureManager` | `selectedInputDeviceUID`, `preferredInputDeviceIDOverride` | AudioSettingsView |
| Noise suppression | Apple Voice Processing I/O on AVAudioEngine input | `Audio/AudioCaptureManager` | `noiseSuppression` | AudioSettingsView |
| BT codec-switch recovery | Graceful A2DP→SCO handling, device-alive check | `Audio/AudioCaptureManager`, `Audio/AudioDeviceManager` | — | — |

## ASR Quality (3)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| Backend selection | Parakeet v3 (streaming) or WhisperKit (batch) | `ASR/ASRManager`, `ASR/*Backend` | `selectedBackend` | SpeechEngineSettingsView |
| WhisperKit tuning | Temperature, no-speech threshold, language auto-detect | `ASR/WhisperKitBackend` | `whisperKitTemperature`, `whisperKitNoSpeechThreshold`, `whisperKitLanguageAutoDetect` | SpeechEngineSettingsView |
| Temperature fallback | Re-transcribe with elevated temp on low confidence | `ASR/WhisperKitBackend` | — | — |
| WhisperKit independent pipeline | DictationPipeline conformance, WhisperKitPipelineState, shared AudioCaptureManager | `Pipeline/WhisperKitPipeline`, `Pipeline/DictationPipeline` | — | — |
| WhisperKit VAD | EnergyVAD silence trimming + chunkingStrategy for long recordings | `Pipeline/WhisperKitPipeline`, `ASR/WhisperKitBackend` | — | — |
| WhisperKit streaming | AudioStreamTranscriber chunked streaming with batch fallback | `ASR/WhisperKitStreamingCoordinator`, `Pipeline/WhisperKitPipeline` | — | — |

## Post-Processing (2)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| Filler word removal | Regex-based um/uh/like removal | `Pipeline/Steps/FillerRemovalStep` | `fillerRemovalEnabled` | SpeechEngineSettingsView |
| Custom word correction | Fuzzy match (Levenshtein+Dice+Soundex) replacement | `PostProcessing/WordCorrector`, `PostProcessing/CustomWordStore` | `wordCorrectionEnabled` | WordFixSettingsView |

## AI Polish (8)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| LLM provider selection | OpenAI, Gemini, Ollama, Apple Intelligence, None | `LLM/*Connector` | `llmProvider`, `llmModel`, `ollamaModel` | AIPolishSettingsView |
| Custom system prompt | User prompt with `${transcript}` placeholder | `Services/SettingsManager` | `customSystemPrompt` | PromptEditorView |
| Prompt presets | cleanUp, formal, casual templates | `Models/LLMResult` (PromptPreset) | — | PromptEditorView |
| Extended thinking | Gemini thinking budget + OpenAI reasoning effort | `Pipeline/Steps/LLMPolishStep` | `useExtendedThinking` | AIPolishSettingsView |
| SSE streaming polish | Gemini token-by-token streaming via `onToken` | `LLM/GeminiConnector` | — | — |
| Ollama setup wizard | Install, start server, pull/delete models, quality tiers | `LLM/OllamaSetupService` | — | AIPolishSettingsView |
| API key management | File-based storage in `~/.enviouswispr-keys/` (0600) | `LLM/KeychainManager` | — | AIPolishSettingsView |
| Model discovery | Runtime probe all providers for available models | `LLM/LLMModelDiscovery` | — | AIPolishSettingsView |

## Clipboard (2)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| Auto-copy to clipboard | Copy transcript to clipboard after processing | `Services/PasteService` | `autoCopyToClipboard` | ClipboardSettingsView |
| Clipboard restore | Save/restore clipboard around Cmd+V paste | `Services/PasteService` | `restoreClipboardAfterPaste` | ClipboardSettingsView |

## History (5)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| Transcript list | Sidebar with badges, timestamps, delete | `Views/Main/TranscriptHistoryView` | — | HistoryContentView |
| Transcript detail | Polished + original panes, copy/paste/enhance | `Views/Main/TranscriptDetailView` | — | HistoryContentView |
| JSON persistence | File store in `~/Library/Application Support/` | `Storage/TranscriptStore` | — | — |
| Search | Filter transcripts by text content | `Views/Main/SidebarStatsHeader`, `Views/Main/TranscriptHistoryView` | — | HistoryContentView |
| Delete all | Bulk transcript removal from sidebar | `Views/Main/TranscriptHistoryView` | — | HistoryContentView |

## Model Lifecycle (1)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| Model unload policy | Timer-based memory management (never→60min) | `ASR/ASRManager`, `Models/AppSettings` | `modelUnloadPolicy` | MemorySettingsView |

## UI Chrome (4)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| Menu bar icon | 4-state CG-rendered: idle/recording/processing/error | `App/MenuBarIconAnimator`, `App/AppDelegate` | — | NSStatusItem |
| Recording overlay | Floating NSPanel with spectrum wheel + rainbow lips | `Views/Overlay/RecordingOverlayPanel` | — | RecordingOverlayView |
| Settings sidebar | NavigationSplitView — 10 sections in 5 groups | `Views/Settings/SettingsView`, `Views/Settings/SettingsSection` | — | UnifiedWindowView |
| Accessibility banner | Orange "Fix Now" warning when AX not granted | `Views/Components/AccessibilityWarningBanner` | — | HistoryContentView |

## Permissions (2)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| Microphone | AVCaptureDevice authorization check + request | `Services/PermissionsService` | — | PermissionsSettingsView |
| Accessibility | AXIsProcessTrusted check + System Preferences link | `Services/PermissionsService` | — | PermissionsSettingsView |

## Diagnostics (5)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| Debug mode | Enable verbose logging output | `Services/SettingsManager` | `isDebugModeEnabled`, `debugLogLevel` | DiagnosticsSettingsView |
| File logging | Rotating log files via OSLog + file sink | `Utilities/AppLogger` | — | DiagnosticsSettingsView |
| ASR benchmarks | Throughput + WER measurement per backend | `Utilities/BenchmarkSuite` | — | DiagnosticsSettingsView |
| Pipeline benchmarks | End-to-end timing (batch vs streaming, WER delta) | `Utilities/BenchmarkSuite` | — | DiagnosticsSettingsView |
| Sparkle auto-update | Check for + install app updates | `App/AppDelegate` (SPUStandardUpdaterController) | — | Menu bar |

## Onboarding (1)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| 3-screen onboarding | Welcome → Setting Up (auto-install + permissions) → Ready to Wispr | `Views/Onboarding/OnboardingV2View`, `Views/Onboarding/OnboardingDesignTokens`, `Views/Onboarding/RainbowLipsView` | `onboardingState` | OnboardingV2View |

## Brand & Design (1)

| Feature | Description | Files | Settings | UI |
|---------|-------------|-------|----------|----|
| Brand design system | Color palette, typography, gradients, component patterns for all visual artifacts | `.claude/skills/brand-guide/SKILL.md`, `Views/Onboarding/OnboardingDesignTokens` | — | All views (accent purple, rainbow spectrum) |
