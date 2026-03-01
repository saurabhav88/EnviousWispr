# Task Router — EnviousWispr

**Use this file first.** Given a task description, find the files to change, agent to dispatch, and skill to invoke.

## Common Task Patterns

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
| 1. Model catalog | `Services/OllamaSetupService.swift` — REST API `GET /api/tags`, `POST /api/pull`, `DELETE /api/delete` |
| 2. Quality tiers | `Services/OllamaSetupService.swift` — classify models as strong/weak for feature gating |
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
- **State machine issue:** `Pipeline/TranscriptionPipeline.swift` (563 lines — the big one)
- **Audio capture:** `Audio/AudioCaptureManager.swift`
- **VAD/silence:** `Audio/SilenceDetector.swift`
- **ASR routing:** `ASR/ASRManager.swift`
- **Streaming ASR:** `ASR/ParakeetBackend.swift`
- **Streaming protocol:** `ASR/ASRProtocol.swift` — `supportsStreaming` flag, streaming methods
- **Latency measurement:** `Utilities/BenchmarkSuite.swift` — pipeline timing

### Fix hotkey/shortcut issues
**Agent:** macos-platform | **Skill:** `wispr-validate-menu-bar-patterns`
- **Carbon registration:** `Services/HotkeyService.swift` (442 lines)
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
- **Polish step:** `Pipeline/Steps/LLMPolishStep.swift` (117 lines — extended thinking, provider routing)
- **Connector code:** `LLM/{Provider}Connector.swift`
- **Error types:** `LLM/LLMProtocol.swift`
- **Network session:** `LLM/LLMNetworkSession.swift`
- **Model discovery:** `LLM/LLMModelDiscovery.swift`
- **Settings UI:** `Views/Settings/AIPolishSettingsView.swift` (512 lines)
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
- **VAD actor:** `Audio/SilenceDetector.swift` (295 lines)
- **VAD monitoring loop:** `Pipeline/TranscriptionPipeline.swift` → `monitorVAD()`
- **Settings:** `Services/SettingsManager.swift` (vadAutoStop, vadSilenceTimeout, vadSensitivity, vadEnergyGate)
- **Settings UI:** `Views/Settings/SpeechEngineSettingsView.swift`

### Add/modify a UserDefaults setting
**Agent:** macos-platform | **Skill:** `wispr-review-swiftui-conventions`
| Step | Files |
|------|-------|
| 1. Add property | `Services/SettingsManager.swift` → new property + didSet + SettingKey case |
| 2. Add init default | `Services/SettingsManager.swift` → init() |
| 3. Handle change | `App/AppState.swift` → handleSettingChanged(.newKey) |
| 4. Add UI control | Appropriate `Views/Settings/___SettingsView.swift` |

### Change menu bar behavior
**Agent:** macos-platform | **Skill:** `wispr-validate-menu-bar-patterns`
- **Icon animator:** `App/MenuBarIconAnimator.swift` (265 lines) — CG-rendered icons, 4 states, audio-reactive
- **Menu construction:** `App/AppDelegate.swift` → `populateMenu()` (NSMenuDelegate)
- **Icon state management:** `App/AppDelegate.swift` → drives `MenuBarIconAnimator` via pipeline state callbacks
- **Window targeting:** `App/AppDelegate.swift` → `openSettings()`, NSApp window focus

### Change overlay appearance
**Agent:** macos-platform | **Skill:** `wispr-review-swiftui-conventions`
- **Overlay panel:** `Views/Overlay/RecordingOverlayPanel.swift` (347 lines)
- **Brand icons:** `SpectrumWheelIcon` (rotating rainbow wheel), `RainbowLipsIcon` (cupid's bow bars with bounce)
- **Background:** `OverlayCapsuleBackground` (capsule with blur)
- **Recording view:** `RecordingOverlayView` — waveform + timer + brand icon
- **Polishing view:** `PolishingOverlayView` — rotating spectrum wheel

### Change onboarding flow
**Agent:** macos-platform | **Skill:** `wispr-review-swiftui-conventions`
- **Onboarding view:** `Views/Onboarding/OnboardingView.swift` (250 lines, 4 steps)
- **Trigger:** `Views/Settings/SettingsView.swift` → `showOnboarding` state
- **Completion flag:** `Services/SettingsManager.swift` → `hasCompletedOnboarding`

### Security/concurrency audit
**Agent:** quality-security | **Skills:** `wispr-audit-actor-isolation`, `wispr-detect-hardcoded-secrets`
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
- **Tracker:** `docs/feature-requests/TRACKER.md`
- **Roadmap:** `.claude/knowledge/roadmap.md`
- Dispatches to domain agents for implementation

### Run tests / validate
**Agent:** testing
- **Smoke test (compile only):** Skill `wispr-run-smoke-test`
- **Smart UAT (behavioral):** Skill `wispr-run-smart-uat`
- **Benchmarks:** Skill `wispr-run-benchmarks`
- **API contracts:** Skill `wispr-validate-api-contracts`
- **AX tree inspect:** Skill `wispr-ui-ax-inspect`

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

1. **`App/AppState.swift`** (512 lines) — 26 edits
2. **`Pipeline/TranscriptionPipeline.swift`** (563 lines) — 16 edits
3. **`App/AppDelegate.swift`** (312 lines) — 16 edits
4. **`Views/Settings/SettingsView.swift`** (81 lines) — 13 edits
5. **`Services/SettingsManager.swift`** — 12 edits (every new setting lands here)
6. **`Views/Main/MainWindowView.swift`** (324 lines) — 9 edits
7. **`LLM/GeminiConnector.swift`** (219 lines) — 9 edits
8. **`Views/Overlay/RecordingOverlayPanel.swift`** (347 lines) — 8 edits
9. **`Utilities/Constants.swift`** (93 lines) — 8 edits
10. **`Services/PasteService.swift`** (130 lines) — 8 edits
11. **`Audio/AudioCaptureManager.swift`** — 8 edits (capture config, noise suppression, device selection)
12. **`Audio/SilenceDetector.swift`** (295 lines) — 8 edits
