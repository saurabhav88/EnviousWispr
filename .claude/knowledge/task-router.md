<!-- GENERATED — do not hand-edit. Run scripts/brain-refresh.sh to update. -->

# Task Router -- EnviousWispr

**Use this file first.** Given a task description, find the files to change, agent to dispatch, and skill to invoke.

**For detailed file info, see [file-index.md](file-index.md). For reverse lookups (type -> file), see [type-index.md](type-index.md).**

## Source File Map (auto-generated)

### Sources/EnviousWispr/App

- `AppDelegate.swift` (444 lines)
- `AppState.swift` (771 lines)
- `EnviousWisprApp.swift` (72 lines)
- `MenuBarIconAnimator.swift` (312 lines)

### Sources/EnviousWispr/ASR

- `ASRManager.swift` (148 lines)
- `ASRProtocol.swift` (76 lines)
- `ParakeetBackend.swift` (129 lines)
- `WhisperKitBackend.swift` (133 lines)
- `WhisperKitSetupService.swift` (172 lines)

### Sources/EnviousWispr/Audio

- `AudioBufferProcessor.swift` (35 lines)
- `AudioCaptureManager.swift` (699 lines)
- `AudioDeviceManager.swift` (273 lines)
- `SilenceDetector.swift` (306 lines)

### Sources/EnviousWispr/LLM

- `AppleIntelligenceConnector.swift` (163 lines)
- `GeminiConnector.swift` (260 lines)
- `KeychainManager.swift` (119 lines)
- `LLMModelDiscovery.swift` (335 lines)
- `LLMNetworkSession.swift` (52 lines)
- `LLMProtocol.swift` (128 lines)
- `LLMRetryPolicy.swift` (29 lines)
- `OllamaConnector.swift` (143 lines)
- `OllamaSetupService.swift` (426 lines)
- `OpenAIConnector.swift` (137 lines)

### Sources/EnviousWispr/Models

- `AppSettings.swift` (80 lines)
- `ASRResult.swift` (31 lines)
- `LLMResult.swift` (103 lines)
- `Transcript.swift` (44 lines)

### Sources/EnviousWispr/Pipeline

- `DictationPipeline.swift` (25 lines)
- `TextProcessingStep.swift` (32 lines)
- `TranscriptionPipeline.swift` (788 lines)
- `WhisperKitPipeline.swift` (473 lines)

### Sources/EnviousWispr/Pipeline/Steps

- `FillerRemovalStep.swift` (57 lines)
- `LLMPolishStep.swift` (113 lines)
- `WordCorrectionStep.swift` (28 lines)

### Sources/EnviousWispr/PostProcessing

- `CustomWordStore.swift` (38 lines)
- `WordCorrector.swift` (138 lines)

### Sources/EnviousWispr/Services

- `HotkeyService.swift` (409 lines)
- `PasteService.swift` (254 lines)
- `PermissionsService.swift` (79 lines)
- `SettingsManager.swift` (409 lines)

### Sources/EnviousWispr/Storage

- `TranscriptStore.swift` (104 lines)

### Sources/EnviousWispr/Utilities

- `AppLogger.swift` (125 lines)
- `BenchmarkSuite.swift` (268 lines)
- `Constants.swift` (94 lines)
- `DebugLogLevel.swift` (20 lines)
- `KeySymbols.swift` (160 lines)
- `WERCalculator.swift` (48 lines)

### Sources/EnviousWispr/Views/Components

- `AccessibilityWarningBanner.swift` (49 lines)
- `HotkeyRecorderView.swift` (226 lines)

### Sources/EnviousWispr/Views/Main

- `HistoryContentView.swift` (30 lines)
- `MainWindowView.swift` (310 lines)
- `SidebarStatsHeader.swift` (94 lines)
- `TranscriptDetailView.swift` (113 lines)
- `TranscriptHistoryView.swift` (98 lines)

### Sources/EnviousWispr/Views/Onboarding

- `OnboardingDesignTokens.swift` (76 lines)
- `OnboardingV2View.swift` (927 lines)
- `RainbowLipsView.swift` (460 lines)

### Sources/EnviousWispr/Views/Overlay

- `RecordingOverlayPanel.swift` (458 lines)

### Sources/EnviousWispr/Views/Settings

- `AIPolishSettingsView.swift` (777 lines)
- `AudioSettingsView.swift` (48 lines)
- `ClipboardSettingsView.swift` (28 lines)
- `DiagnosticsSettingsView.swift` (189 lines)
- `MemorySettingsView.swift` (36 lines)
- `PermissionsSettingsView.swift` (41 lines)
- `PromptEditorView.swift` (138 lines)
- `SettingsComponents.swift` (345 lines)
- `SettingsDesignTokens.swift` (74 lines)
- `SettingsSection.swift` (69 lines)
- `SettingsView.swift` (82 lines)
- `ShortcutsSettingsView.swift` (52 lines)
- `SpeechEngineSettingsView.swift` (291 lines)
- `WordFixSettingsView.swift` (98 lines)


<!-- MANUAL SECTION BELOW — human-authored, preserved across regeneration -->

# Task Router — EnviousWispr

**Use this file first.** Given a task description, find the files to change, agent to dispatch, and skill to invoke.

**For detailed file info, see [file-index.md](file-index.md). For reverse lookups (type → file), see [type-index.md](type-index.md).**

## Common Task Patterns

### Create a mockup / visual artifact / HTML design
**Agent:** frontend-designer | **Skill:** `brand-guide`
| Step | Files |
|------|-------|
| 1. Read brand guide | `.claude/skills/brand-guide/SKILL.md` — colors, fonts, gradients, components |
| 2. Create artifact | `docs/mockups/descriptive-name.html` |
| 3. Verify in browser | Open in Chrome, screenshot, iterate |

**All visual artifacts MUST use brand tokens.** No improvising colors or fonts. Web mockups use Plus Jakarta Sans; macOS settings mockups use system-ui with brand accent colors.

### Add a new LLM provider
**Agent:** feature-scaffolding | **Skill:** `wispr-scaffold-llm-connector`
| Step | Files |
|------|-------|
| 1. Create connector | `LLM/New___Connector.swift` (conform to `TranscriptPolisher`) |
| 2. Add provider case | `Models/LLMResult.swift` → `LLMProvider` enum |
| 3. Wire into pipeline | `Pipeline/Steps/LLMPolishStep.swift` → switch on new case |
| 4. Add Keychain slot | `LLM/KeychainManager.swift` → new static key ID |
| 5. Add settings UI | `Views/Settings/AIPolishSettingsView.swift` → new section |
| 6. Add model discovery | `LLM/LLMModelDiscovery.swift` → new fetch method |

### Add a new ASR backend
**Agent:** feature-scaffolding | **Skill:** `wispr-scaffold-asr-backend`
| Step | Files |
|------|-------|
| 1. Create backend | `ASR/New___Backend.swift` (actor conforming to `ASRBackend`) |
| 2. Add backend type | `Models/ASRResult.swift` → `ASRBackendType` enum |
| 3. Wire into manager | `ASR/ASRManager.swift` → instantiate + route |
| 4. Add settings UI | `Views/Settings/SpeechEngineSettingsView.swift` → picker option |
| 5. Update Package.swift | Add dependency if needed |

### Add a new settings tab
**Agent:** feature-scaffolding | **Skill:** `wispr-scaffold-settings-tab`
| Step | Files |
|------|-------|
| 1. Add section enum | `Views/Settings/SettingsSection.swift` → new case + group |
| 2. Create view | `Views/Settings/New___SettingsView.swift` |
| 3. Wire into root | `Views/Settings/SettingsView.swift` → add case in detail switch |
| 4. Add state properties | `Services/SettingsManager.swift` → new properties + UserDefaults keys |
| 5. Propagate changes | `App/AppState.swift` → handleSettingChanged() |

### Add audio input device selection
**Agents:** audio-pipeline + macos-platform
| Step | Files |
|------|-------|
| 1. Enumerate devices | `Audio/AudioDeviceManager.swift` — CoreAudio `kAudioHardwarePropertyDevices`, return `[AudioDevice]` |
| 2. Apply selected device | `Audio/AudioCaptureManager.swift` — use UID to configure AVAudioEngine input node |
| 3. Persist selection | `Services/SettingsManager.swift` — `selectedAudioDeviceUID` (String?) |
| 4. Wire into pipeline | `App/AppState.swift` — `handleSettingChanged(.selectedAudioDeviceUID)` |
| 5. Settings UI | `Views/Settings/AudioSettingsView.swift` — device picker |

### Add noise suppression
**Agent:** audio-pipeline
| Step | Files |
|------|-------|
| 1. Toggle Voice Processing | `Audio/AudioCaptureManager.swift` — `AVAudioInputNode` voice processing I/O unit flag |
| 2. Persist preference | `Services/SettingsManager.swift` — `noiseSuppressionEnabled` (Bool, default `true`) |
| 3. Settings UI | `Views/Settings/AudioSettingsView.swift` — toggle control |

### Modify Ollama model management
**Agent:** macos-platform
| Step | Files |
|------|-------|
| 1. Model catalog | `LLM/OllamaSetupService.swift` — REST API `GET /api/tags`, `POST /api/pull`, `DELETE /api/delete` |
| 2. Quality tiers | `LLM/OllamaSetupService.swift` — classify models as strong/weak for feature gating |
| 3. In-app download/delete | `Views/Settings/AIPolishSettingsView.swift` — progress UI for pull, confirm-delete |
| 4. Prompt restrictions | `Views/Settings/AIPolishSettingsView.swift` — hide custom prompt section for weak models |

### Add WhisperKit quality controls
**Agents:** audio-pipeline + macos-platform
| Step | Files |
|------|-------|
| 1. Transcription options | `ASR/WhisperKitBackend.swift` — `temperature`, `noSpeechThreshold`, `language` (auto-detect) |
| 2. Persist settings | `Services/SettingsManager.swift` — `whisperTemperature`, `whisperNoSpeechThreshold`, `whisperLanguage` |
| 3. Settings UI | `Views/Settings/SpeechEngineSettingsView.swift` — sliders/pickers for quality knobs |
| 4. Temperature fallback | `ASR/WhisperKitBackend.swift` — retry with higher temperature on low-confidence result |

### Build the WhisperKit independent highway
**Agent:** audio-pipeline | **Skills:** `wispr-scaffold-whisperkit-capture`, `wispr-scaffold-independent-pipeline`, `wispr-configure-whisperkit-vad`, `wispr-configure-whisperkit-streaming`
| Step | Files |
|------|-------|
| 1. DictationPipeline protocol (Phase 0) | **NEW:** `Pipeline/DictationPipeline.swift` — PipelineEvent, OverlayIntent, DictationPipeline protocol |
| 2. TranscriptionPipeline conformance | `Pipeline/TranscriptionPipeline.swift` — add DictationPipeline conformance (1-line) |
| 3. WhisperKitPipeline (Phase 1) | **NEW:** `Pipeline/WhisperKitPipeline.swift` — WhisperKitPipelineState, shared AudioCaptureManager, batch transcription |
| 4. AppState routing | `App/AppState.swift` — activePipeline: any DictationPipeline, dispatch(_ event:) |
| 5. Overlay decoupling | `Views/Overlay/RecordingOverlayPanel.swift` — observe OverlayIntent, not PipelineState |
| 6. VAD integration (Phase 2) | `Pipeline/WhisperKitPipeline.swift` + `ASR/WhisperKitBackend.swift` — EnergyVAD, chunkingStrategy |
| 7. Streaming coordinator (Phase 3) | **NEW:** `ASR/WhisperKitStreamingCoordinator.swift` — AudioStreamTranscriber wrapper |
| 8. Test dual pipeline | Use `wispr-test-dual-pipeline` for regression verification |

### Test dual-pipeline architecture
**Agent:** testing | **Skill:** `wispr-test-dual-pipeline`
| Step | Files |
|------|-------|
| 1. Regression check | Verify Parakeet path unchanged after WhisperKit changes |
| 2. Backend switching | Test Parakeet->WhisperKit and back, rapid switching |
| 3. State machine tests | Verify all state transitions per pipeline |
| 4. Performance baseline | Run benchmarks for both backends |

### Add a new SwiftUI view
**Agent:** feature-scaffolding | **Skill:** `wispr-scaffold-swiftui-view`
- Inject state: `@Environment(AppState.self) private var appState`
- For bindings: `@Bindable var state = appState`
- No `#Preview` macros (CLT only)
- Place in appropriate `Views/` subdirectory

### Fix a build error
**Agent:** build-compile | **Skill:** `wispr-auto-fix-compiler-errors`
- Run `swift build` to capture errors
- Categories: concurrency (→ @preconcurrency), type mismatch, missing import, actor isolation, API change, other
- After fix: `wispr-validate-build-post-update`

### Fix a pipeline bug (recording/transcription)
**Agent:** audio-pipeline | **Skill:** `wispr-trace-audio-pipeline`
- **State machine issue:** `Pipeline/TranscriptionPipeline.swift` (686 lines — the big one)
- **Audio capture:** `Audio/AudioCaptureManager.swift`
- **VAD/silence:** `Audio/SilenceDetector.swift`
- **ASR routing:** `ASR/ASRManager.swift`
- **Streaming ASR:** `ASR/ParakeetBackend.swift`
- **Streaming protocol:** `ASR/ASRProtocol.swift` — `supportsStreaming` flag, streaming methods
- **Latency measurement:** `Utilities/BenchmarkSuite.swift` — pipeline timing

### Fix hotkey/shortcut issues
**Agent:** macos-platform | **Skill:** `wispr-review-platform`
- **Carbon registration:** `Services/HotkeyService.swift` (415 lines)
- **Recorder widget:** `Views/Components/HotkeyRecorderView.swift`
- **Key formatting:** `Utilities/KeySymbols.swift`
- **Settings persistence:** `Services/SettingsManager.swift` (keyCode/modifier keys)

### Fix paste/clipboard issues
**Agent:** macos-platform
- **Paste mechanism:** `Services/PasteService.swift` (CGEvent Cmd+V)
- **Clipboard save/restore:** `Services/PasteService.swift` (ClipboardSnapshot)
- **Accessibility check:** `Services/PermissionsService.swift`
- **Pipeline integration:** `Pipeline/TranscriptionPipeline.swift` (stopAndTranscribe)

### Fix LLM polish issues
**Agent:** audio-pipeline (pipeline) or feature-scaffolding (connector)
- **Polish step:** `Pipeline/Steps/LLMPolishStep.swift` (113 lines — extended thinking, provider routing)
- **Connector code:** `LLM/{Provider}Connector.swift`
- **Error types:** `LLM/LLMProtocol.swift`
- **Network session:** `LLM/LLMNetworkSession.swift`
- **Model discovery:** `LLM/LLMModelDiscovery.swift`
- **Settings UI:** `Views/Settings/AIPolishSettingsView.swift` (668 lines)
- **Streaming polish:**
  - `LLM/GeminiConnector.swift` — SSE streaming via `streamGenerateContent?alt=sse`, thinking budget
  - `LLM/LLMProtocol.swift` — `onToken` callback parameter
  - `LLM/LLMNetworkSession.swift` — URLSession reuse
- **Extended thinking:**
  - `Pipeline/Steps/LLMPolishStep.swift` — `resolveThinkingConfig()` (Gemini thinkingBudget, OpenAI reasoningEffort)
  - `Models/LLMResult.swift` — `LLMProviderConfig.thinkingBudget?`, `LLMProviderConfig.reasoningEffort?`
  - `Utilities/Constants.swift` — `LLMConstants.defaultThinkingBudget`
  - `Views/Settings/AIPolishSettingsView.swift` — toggle UI
  - `Services/SettingsManager.swift` — `useExtendedThinking` setting

### Fix VAD/silence detection
**Agent:** audio-pipeline | **Skill:** `wispr-apply-vad-manager-patterns`
- **VAD actor:** `Audio/SilenceDetector.swift` (302 lines)
- **VAD monitoring loop:** `Pipeline/TranscriptionPipeline.swift` → `monitorVAD()`
- **Settings:** `Services/SettingsManager.swift` (vadAutoStop, vadSilenceTimeout, vadSensitivity, vadEnergyGate)
- **Settings UI:** `Views/Settings/SpeechEngineSettingsView.swift`

### Add/modify a UserDefaults setting
**Agent:** macos-platform | **Skill:** `wispr-review-platform`
| Step | Files |
|------|-------|
| 1. Add property | `Services/SettingsManager.swift` → new property + didSet + SettingKey case |
| 2. Add init default | `Services/SettingsManager.swift` → init() |
| 3. Handle change | `App/AppState.swift` → handleSettingChanged(.newKey) |
| 4. Add UI control | Appropriate `Views/Settings/___SettingsView.swift` |

### Change menu bar behavior
**Agent:** macos-platform | **Skill:** `wispr-review-platform`
- **Icon animator:** `App/MenuBarIconAnimator.swift` (312 lines) — CG-rendered icons, 4 states, audio-reactive
- **Menu construction:** `App/AppDelegate.swift` → `populateMenu()` (NSMenuDelegate)
- **Icon state management:** `App/AppDelegate.swift` → drives `MenuBarIconAnimator` via pipeline state callbacks
- **Window targeting:** `App/AppDelegate.swift` → `openSettings()`, NSApp window focus

### Change overlay appearance
**Agent:** macos-platform | **Skill:** `wispr-review-platform`
- **Overlay panel:** `Views/Overlay/RecordingOverlayPanel.swift` (457 lines)
- **Brand icons:** `SpectrumWheelIcon` (rotating rainbow wheel), `RainbowLipsIcon` (cupid's bow bars with bounce)
- **Background:** `OverlayCapsuleBackground` (capsule with blur)
- **Recording view:** `RecordingOverlayView` — waveform + timer + brand icon
- **Polishing view:** `PolishingOverlayView` — rotating spectrum wheel

### Change onboarding flow
**Agent:** macos-platform | **Skill:** `wispr-review-platform`
- **Onboarding view:** `Views/Onboarding/OnboardingV2View.swift` (~927 lines, 3 screens)
- **Design tokens:** `Views/Onboarding/OnboardingDesignTokens.swift`
- **Animations:** `Views/Onboarding/RainbowLipsView.swift` (DNA equalizer, heart, triumph)
- **Trigger:** `App/EnviousWisprApp.swift` → `onboardingState != .completed`
- **Completion flag:** `Services/SettingsManager.swift` → `onboardingState`
- **State cases:** `.notStarted`, `.settingUp`, `.needsPermissions`, `.completed`

### Security/concurrency audit
**Agent:** quality-security | **Skills:** `wispr-audit-concurrency`, `wispr-audit-secrets`
- All actors: SilenceDetector, ParakeetBackend, WhisperKitBackend, AppLogger
- All @MainActor classes: AppState, TranscriptionPipeline, ASRManager, AudioCaptureManager, HotkeyService, PermissionsService, SettingsManager, OllamaSetupService, BenchmarkSuite, TranscriptStore, RecordingOverlayPanel, MenuBarIconAnimator, LLMPolishStep, WordCorrectionStep
- Key storage: `LLM/KeychainManager.swift`
- Sensitive logging: `LLM/` directory, `Utilities/AppLogger.swift`

### Release / distribute
**Agent:** release-maintenance | **Skill:** `wispr-release-checklist`
- **Build script:** `scripts/build-dmg.sh`
- **CI workflow:** `.github/workflows/release.yml`
- **Info.plist:** `Sources/EnviousWispr/Resources/Info.plist`
- **Entitlements:** `Sources/EnviousWispr/Resources/EnviousWispr.entitlements`
- **Sparkle key:** `Sources/EnviousWispr/Resources/sparkle_public_key.txt`
- **Icon:** `Sources/EnviousWispr/Resources/AppIcon.icns`

### Implement a feature request
**Agent:** feature-planning | **Skill:** `wispr-implement-feature-request`
- **Feature specs:** `docs/feature-requests/NNN-feature-name.md`
- **Tracker:** Beads (`bd ready`, `bd show <id>`, `bd close <id>`)
- **Roadmap:** `.claude/knowledge/roadmap.md`
- Dispatches to domain agents for implementation

### Run tests / validate
**Agent:** testing
- **Smoke test (compile only):** Skill `wispr-run-smoke-test`
- **UI verification:** Skill `wispr-eyes`
- **Benchmarks:** Skill `wispr-run-benchmarks`
- **API contracts:** Skill `wispr-validate-api-contracts`
- **UI testing (AX inspect, input simulation, screenshot):** Skill `wispr-ui-testing-tools`

### Fix pipeline latency
**Agent:** audio-pipeline | **Skill:** `wispr-trace-audio-pipeline`
| Step | Files |
|------|-------|
| 1. Add instrumentation | `Pipeline/TranscriptionPipeline.swift` — CFAbsoluteTimeGetCurrent timing |
| 2. Enable streaming ASR | `ASR/ASRManager.swift`, `ASR/ParakeetBackend.swift` |
| 3. Optimize LLM stream | `LLM/GeminiConnector.swift` — onToken callback, SSE |
| 4. Pre-warm network | `LLM/LLMNetworkSession.swift` — URLSession singleton |
| 5. Benchmark | `Utilities/BenchmarkSuite.swift` — RTF, WER delta |

### Benchmark ASR/pipeline performance
**Agent:** testing | **Skill:** `wispr-run-benchmarks`
| Step | Files |
|------|-------|
| 1. Configure | `Utilities/BenchmarkSuite.swift` |
| 2. Measure WER | `Utilities/WERCalculator.swift` |
| 3. View results | `Views/Settings/DiagnosticsSettingsView.swift` |

### Fix Bluetooth audio / device switching issues
**Agent:** audio-pipeline | **Skill:** `wispr-trace-audio-pipeline`
| Step | Files |
|------|-------|
| 1. Config change handler | `Audio/AudioCaptureManager.swift` — `handleEngineConfigurationChange()`, `recoverFromCodecSwitch()` |
| 2. Device liveness check | `Audio/AudioDeviceManager.swift` — `kAudioDevicePropertyDeviceIsAlive` |
| 3. Pipeline integration | `Pipeline/TranscriptionPipeline.swift` — `onEngineInterrupted` wiring |

### Fix PTT pre-warm / hotkey timing
**Agent:** audio-pipeline
| Step | Files |
|------|-------|
| 1. Pre-warm trigger | `Services/HotkeyService.swift` — `onPreWarmAudio` callback on key-down |
| 2. Engine pre-warm | `Audio/AudioCaptureManager.swift` — `preWarm()`, `isPreWarmed` flag |
| 3. Pipeline routing | `Pipeline/TranscriptionPipeline.swift` — skip engine phase if pre-warmed |

### Fix noise suppression toggle
**Agent:** audio-pipeline
| Step | Files |
|------|-------|
| 1. Engine rebuild | `Audio/AudioCaptureManager.swift` — `buildEngine(noiseSuppression:)` |
| 2. Setting persistence | `App/AppState.swift` — `handleSettingChanged(.noiseSuppressionEnabled)` |
| 3. Settings UI | `Views/Settings/AudioSettingsView.swift` — toggle control |

### Configure streaming ASR
**Agent:** audio-pipeline
| Step | Files |
|------|-------|
| 1. Backend flag | `ASR/ASRProtocol.swift` — `supportsStreaming` |
| 2. Pipeline routing | `Pipeline/TranscriptionPipeline.swift` — streaming vs batch path |
| 3. Buffer forwarding | `Audio/AudioCaptureManager.swift` — `onBufferCaptured` callback |

### Manage network pre-warming
**Agent:** audio-pipeline or quality-security
| Step | Files |
|------|-------|
| 1. Session singleton | `LLM/LLMNetworkSession.swift` |
| 2. Lifecycle hooks | `App/AppDelegate.swift` — preWarm on launch/activate |
| 3. Pipeline hook | `Pipeline/TranscriptionPipeline.swift` — preWarm on recording stop |

## Dependency Graph (what depends on what)

```
AppState ──owns──> TranscriptionPipeline
                     ├──> AudioCaptureManager
                     ├──> ASRManager ──> ParakeetBackend / WhisperKitBackend
                     ├──> SilenceDetector
                     ├──> LLMPolishStep ──> {OpenAI,Gemini,Ollama,AppleIntelligence}Connector
                     ├──> WordCorrectionStep ──> WordCorrector
                     ├──> TranscriptStore
                     ├──> PasteService
                     └──> KeychainManager
AppState ──owns──> SettingsManager (propagates via onChange)
AppState ──owns──> PermissionsService
AppState ──owns──> HotkeyService
AppState ──owns──> BenchmarkSuite
AppState ──owns──> RecordingOverlayPanel
AppState ──owns──> OllamaSetupService
AppState ──owns──> CustomWordStore
AppDelegate ──owns──> AppState (creates it)
AppDelegate ──owns──> MenuBarIconAnimator (drives icon state from pipeline callbacks)
EnviousWisprApp ──refs──> AppDelegate (via @NSApplicationDelegateAdaptor)
```

## Top 12 Most-Edited Files (git-verified)

These files are touched by almost every feature. Read them first when scoping work:

1. **`App/AppState.swift`** (613 lines) — 26 edits
2. **`Pipeline/TranscriptionPipeline.swift`** (686 lines) — 16 edits
3. **`App/AppDelegate.swift`** (423 lines) — 16 edits
4. **`Views/Settings/SettingsView.swift`** (71 lines) — 13 edits
5. **`Services/SettingsManager.swift`** (399 lines) — 12 edits (every new setting lands here)
6. **`Views/Main/MainWindowView.swift`** (314 lines) — 9 edits
7. **`LLM/GeminiConnector.swift`** (260 lines) — 9 edits
8. **`Views/Overlay/RecordingOverlayPanel.swift`** (457 lines) — 8 edits
9. **`Utilities/Constants.swift`** (82 lines) — 8 edits
10. **`Services/PasteService.swift`** (130 lines) — 8 edits
11. **`Audio/AudioCaptureManager.swift`** (699 lines) — 8 edits (capture config, noise suppression, device selection)
12. **`Audio/SilenceDetector.swift`** (302 lines) — 8 edits
