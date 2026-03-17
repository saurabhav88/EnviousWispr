# Settings UI & Feature Enhancements -- March 2026

Nine targeted improvements to the Settings experience and audio pipeline, scoped from user feedback and competitive analysis. Each item is self-contained and can be implemented independently.

---

## 1. AI Polish "None" Provider State

### Context

When the user selects "None" as the LLM provider, the Settings view still shows the OpenAI and Gemini API key sections (lines 110-208 of `AIPolishSettingsView.swift` use `|| appState.settings.llmProvider == .none` to display both key sections). This is confusing for users who explicitly opted out of LLM polishing -- they see two API key forms with no explanation of what polishing does or why they might want it. The "None" state should be an educational opportunity, not a cluttered key-entry form.

### Acceptance Criteria

- When LLM provider is set to "None", the OpenAI API Key and Gemini API Key sections are completely hidden.
- In their place, display an informational panel explaining what LLM polishing does: grammar correction, filler removal, punctuation, formatting.
- The explainer includes a call-to-action encouraging the user to select a provider (e.g., "Choose a provider above to enable AI polishing").
- Existing API keys stored in KeychainManager are preserved -- hiding the UI does not clear saved keys.
- Switching from "None" to any provider restores the normal key/model UI immediately.

### Files Likely Affected

| File | Change |
|------|--------|
| `Views/Settings/AIPolishSettingsView.swift` | Remove `.none` from the API key section visibility guards (lines 110, 160); add explainer `Section` when provider is `.none` |
| `LLM/KeychainManager.swift` | No change -- keys persist regardless of UI visibility |

---

## 2. OpenAI Model Picker Bug

### Context

When the user switches the LLM provider to OpenAI, the model dropdown populates but defaults to an Apple Intelligence model rather than an OpenAI model (e.g., `gpt-4o` or `gpt-4o-mini`). This is a state management issue: the `llmModel` property in `SettingsManager` carries over the previously selected model string from another provider, or `LLMModelDiscovery` returns models in an order where the first match is not an OpenAI model. The `onChange(of: appState.settings.llmProvider)` handler clears `discoveredModels` but does not reset `llmModel` to a sensible default for the new provider.

### Acceptance Criteria

- When switching to OpenAI, the model picker defaults to the first available OpenAI model (e.g., `gpt-4o-mini`).
- When switching to any provider, the previously selected model is cleared if it does not belong to the new provider.
- If the user previously used OpenAI and switches back, the last-used OpenAI model is restored (per-provider model memory).
- No Apple Intelligence, Gemini, or Ollama models appear in the OpenAI dropdown.
- The fix covers all provider transitions, not just the OpenAI case.

### Files Likely Affected

| File | Change |
|------|--------|
| `Views/Settings/AIPolishSettingsView.swift` | Update `onChange(of: llmProvider)` to reset `llmModel` when provider changes |
| `Services/SettingsManager.swift` | Add per-provider last-used model storage (e.g., `lastOpenAIModel`, `lastGeminiModel`) or a dictionary-based approach |
| `App/AppState.swift` | Ensure `validateKeyAndDiscoverModels` sets a default model after discovery completes |
| `LLM/LLMModelDiscovery.swift` | Verify model filtering returns only models for the requested provider |

---

## 3. Ollama Model Management

### Context

When Ollama is running, the current model picker only shows models that are already downloaded locally. Users have no visibility into which models are available but not yet installed, and no way to download new models from within the app. The existing `OllamaSetupService` already supports `ollama pull` with NDJSON progress tracking, but this is only used during initial setup (the "Download a Model" wizard step). Power users who want to try different models must use the terminal.

### Acceptance Criteria

- When Ollama is the active provider and the server is running, the model picker shows all viable text-generation models from the Ollama library (not just locally installed ones).
- Each model entry displays a quality tier label: "Best" (70B+ params), "Medium" (7B-30B), "Lightweight" (< 7B).
- Models that are already downloaded show a checkmark or "Installed" badge.
- Models that are not downloaded show a download button that triggers `ollama pull` with the existing NDJSON progress UI from `OllamaSetupService`.
- Multiple models can be managed without leaving Settings.
- Model size (GB) is displayed alongside tier labels to help users make informed choices.

### Files Likely Affected

| File | Change |
|------|--------|
| `LLM/OllamaSetupService.swift` | Add method to fetch available models from Ollama library API; expose model metadata (param count, size) |
| `LLM/LLMModelDiscovery.swift` | Extend Ollama discovery to merge remote-available models with locally-installed models |
| `Models/LLMResult.swift` | Add quality tier enum or field to `LLMModelInfo`; add `isInstalled` / `parameterCount` / `sizeBytes` properties |
| `Views/Settings/AIPolishSettingsView.swift` | Update Ollama model picker to show tier labels, installed badges, and per-model download buttons |
| `LLM/OllamaConnector.swift` | No change expected -- connector already uses model name string |

---

## 4. Ollama Prompt Restrictions

### Context

Weaker Ollama models (e.g., Phi-3 Mini, Gemma 2B, TinyLlama) do not handle complex system prompts or custom instructions well. Sending a multi-step system prompt to a 2B-parameter model produces worse results than sending no prompt at all. Currently, the custom prompt editor and system prompt options are available for all Ollama models regardless of capability, leading users to degrade their own output quality unknowingly.

### Acceptance Criteria

- For Ollama models classified as "Lightweight" tier (< 7B parameters), the "System Prompt" / "Edit Prompt" button is hidden.
- A brief explanation appears instead: "This model works best with the built-in default prompt."
- For "Medium" and "Best" tier models, full prompt customization remains available.
- Research community best practices for transcript polishing prompts per model tier and document findings (e.g., simpler "fix grammar only" prompt for lightweight, full multi-step instructions for best).
- The built-in default prompt for lightweight models is optimized for their capability (short, single-instruction).

### Files Likely Affected

| File | Change |
|------|--------|
| `Views/Settings/AIPolishSettingsView.swift` | Conditionally hide "Edit Prompt" button based on model tier; show capability-appropriate explainer |
| `Models/LLMResult.swift` | Add model tier classification logic or lookup |
| `Pipeline/Steps/LLMPolishStep.swift` | Select prompt variant based on model tier when provider is Ollama |
| `Utilities/Constants.swift` | Add lightweight-optimized prompt constant |
| `Views/Settings/PromptEditorView.swift` | May need to display read-only prompt for lightweight tier |

---

## 5. Shortcuts Settings Cleanup

### Context

The Shortcuts settings tab (`ShortcutsSettingsView.swift`) currently has two UX issues:

1. **"Enable Global Hotkey" toggle (line 12)**: This toggle wraps all shortcut configuration. When disabled, all hotkeys stop working and the entire shortcuts section disappears. In practice, there is no valid use case for disabling hotkeys -- a dictation app without hotkeys is unusable. The toggle adds confusion without value.

2. **"Push to Talk" toggle (line 25)**: The current boolean toggle with static helper text does not clearly communicate the two distinct recording modes. Users should see the mode names ("Push to Talk" vs "Toggle") with descriptions that update to reflect the currently selected mode.

### Acceptance Criteria

- The "Enable Global Hotkey" toggle is removed entirely. Hotkeys are always enabled.
- The `hotkeyEnabled` setting in `SettingsManager` defaults to `true` and is no longer user-configurable (or is removed entirely if no other code depends on it).
- The shortcut recorder sections are always visible (no conditional on `hotkeyEnabled`).
- The "Push to Talk" toggle is replaced with a segmented Picker showing two options: "Push to Talk" and "Toggle".
- Each mode shows a contextual description that updates when the selection changes:
  - Push to Talk: "Hold the shortcut to record. Release to stop and transcribe."
  - Toggle: "Press the shortcut to start recording. Press again to stop and transcribe."
- Existing hotkey registrations continue to work without regression.

### Files Likely Affected

| File | Change |
|------|--------|
| `Views/Settings/ShortcutsSettingsView.swift` | Remove "Enable global hotkey" toggle; remove `if hotkeyEnabled` guard; replace PTT `Toggle` with segmented `Picker` |
| `Services/SettingsManager.swift` | Either remove `hotkeyEnabled` property or hard-code it to `true`; verify `isPushToTalk` persistence is unaffected |
| `Services/HotkeyService.swift` | Verify no code path depends on `hotkeyEnabled` being false; remove any conditional registration gated on it |
| `App/AppState.swift` | Update `handleSettingChanged` if `.hotkeyEnabled` key is removed |

---

## 6. Noise Cancellation

### Context

The current audio pipeline captures raw microphone input and passes it directly through the 16kHz resampler to the ASR backend. In noisy environments (cafes, open offices, outdoors), background noise degrades transcription accuracy significantly. There is no voice isolation or noise suppression in the pipeline today.

Research has been completed. The recommended solution is **DeepFilterNet** (Phase 2), an open-source deep learning noise suppression model licensed under MIT/Apache-2.0. It operates on 16kHz audio and is designed for real-time streaming, making it a natural fit for the existing pipeline.

### Acceptance Criteria

- A new noise cancellation processing step is integrated into the audio pipeline.
- Integration point: `AudioCaptureManager` tap handler, applied to audio buffers **before** the 16kHz format converter (or immediately after, depending on DeepFilterNet's input requirements).
- Noise cancellation is togglable via a setting in the Speech Engine tab.
- When enabled, background noise (keyboard typing, fan noise, ambient chatter) is significantly reduced in the audio sent to ASR.
- Speech clarity is preserved -- no robotic artifacts or clipping on clean voice input.
- Latency overhead is < 50ms per buffer (real-time capable).
- A "Noise Cancellation" toggle appears in `SpeechEngineSettingsView` under a new "Audio Processing" section.

### Files Likely Affected

| File | Change |
|------|--------|
| `Audio/AudioCaptureManager.swift` | Insert DeepFilterNet processing in the tap handler callback, before or after format conversion |
| `Audio/NoiseCancellation.swift` | **New file** -- DeepFilterNet wrapper, model loading, buffer processing interface |
| `Views/Settings/SpeechEngineSettingsView.swift` | Add "Noise Cancellation" toggle in a new "Audio Processing" section |
| `Services/SettingsManager.swift` | Add `noiseCancellationEnabled` property and `SettingKey.noiseCancellation` |
| `App/AppState.swift` | Propagate noise cancellation setting changes to `AudioCaptureManager` |
| `Package.swift` | Add DeepFilterNet Swift package dependency (or C library bridging) |
| `Utilities/Constants.swift` | Add noise cancellation-related constants (model path, buffer size) |

---

## 7. Settings Default Tab

### Context

The unified window (`SettingsView.swift` / `UnifiedWindowView`) initializes with `@State private var selectedSection: SettingsSection = .history` on line 6, which means it already defaults to the History tab. However, the user reports that Settings does not always open to History first. This could be caused by the `pendingNavigationSection` override in the `onChange` handler (line 47-52), which navigates to a specific section when triggered from elsewhere in the app (e.g., the Accessibility warning banner navigates to Permissions). The issue may be that `pendingNavigationSection` is not being cleared properly, causing stale navigation state on subsequent opens.

### Acceptance Criteria

- The Settings window always opens to the History tab on first display.
- `pendingNavigationSection` overrides (e.g., from the Accessibility banner) still work correctly but are consumed (set to `nil`) after navigation.
- Reopening the Settings window after it was closed returns to History, not the last-viewed section.
- If the window is already open and the user switches apps and returns, the current section is preserved (no unexpected reset).

### Files Likely Affected

| File | Change |
|------|--------|
| `Views/Settings/SettingsView.swift` | Ensure `selectedSection` resets to `.history` on window open (not just on init); verify `pendingNavigationSection` is consumed correctly |
| `App/AppDelegate.swift` | If `openSettings()` sets `pendingNavigationSection`, verify it is cleared after use |
| `App/AppState.swift` | Verify `pendingNavigationSection` lifecycle -- set, consumed, cleared |

---

## 8. WhisperKit Quality Parity

### Context

The app supports two ASR backends: Parakeet (via FluidAudio) and WhisperKit (via ArgMax). Parakeet has received significant optimization work -- streaming ASR support, optimal pipeline configuration, and latency tuning. WhisperKit, by contrast, is batch-only (90 lines, no streaming support) and has not been tuned for quality or speed parity. Users who select WhisperKit may experience noticeably worse transcription latency and potentially different accuracy characteristics without understanding why.

### Acceptance Criteria

- WhisperKit backend supports streaming ASR (implements `startStreaming`, `feedAudio`, `finalizeStreaming`, `cancelStreaming` from `ASRBackend` protocol).
- WhisperKit model variant selection is optimized for Apple Silicon (e.g., `large-v3` for M-series Macs with sufficient RAM).
- WhisperKit pipeline configuration is tuned (chunking strategy, language detection, temperature fallback).
- Transcription quality (WER) is benchmarked against Parakeet using `BenchmarkSuite` and results are comparable or the delta is documented.
- Latency (RTF) is benchmarked and within 2x of Parakeet for equivalent audio length.
- WhisperKit model download/management is exposed in the Speech Engine settings (model variant picker).

### Files Likely Affected

| File | Change |
|------|--------|
| `ASR/WhisperKitBackend.swift` | Implement streaming protocol methods; optimize configuration (model variant, language, chunking) |
| `ASR/ASRProtocol.swift` | Verify streaming protocol requirements are compatible with WhisperKit's streaming API |
| `ASR/ASRManager.swift` | Ensure streaming path routes correctly for WhisperKit when `supportsStreaming` becomes true |
| `Views/Settings/SpeechEngineSettingsView.swift` | Add WhisperKit model variant picker and download status |
| `Utilities/BenchmarkSuite.swift` | Add WhisperKit-specific benchmarks for WER and RTF comparison |
| `Utilities/WERCalculator.swift` | No change expected -- already generic |
| `Pipeline/TranscriptionPipeline.swift` | Verify streaming pipeline works with WhisperKit backend |

---

## 9. Audio Input Device Selection

### Context

The app currently uses the system default audio input device via `AVAudioEngine`. Users with multiple microphones (e.g., built-in mic, external USB mic, AirPods, studio interface) have no way to select which device the app uses without changing the macOS system-wide default. This is a significant gap for a dictation-focused product -- users want to use their best microphone for dictation while keeping a different default for system audio.

Research has been completed. The implementation uses CoreAudio's `AudioObjectGetPropertyData` for device enumeration, device UID strings for persistence across connect/disconnect cycles, and `AudioObjectAddPropertyListenerBlock` for monitoring device changes.

### Acceptance Criteria

- A "Microphone" picker appears in the Speech Engine settings tab showing all available audio input devices.
- Each device shows its name as reported by CoreAudio (e.g., "MacBook Pro Microphone", "Blue Yeti", "AirPods Pro").
- The selected device UID is persisted in `SettingsManager` and survives app restarts.
- If the selected device is disconnected, the app falls back to the system default and shows a non-intrusive notification.
- If the selected device is reconnected, the app automatically switches back to it.
- A "System Default" option is always available and is the initial default.
- Device changes (connect/disconnect) are detected in real-time via CoreAudio property listeners without polling.
- The selected device is applied to `AVAudioEngine` before recording starts.

### Files Likely Affected

| File | Change |
|------|--------|
| `Audio/AudioDeviceManager.swift` | **New file** -- CoreAudio device enumeration, UID persistence, connect/disconnect monitoring, property listener registration |
| `Audio/AudioCaptureManager.swift` | Accept device UID parameter; configure `AVAudioEngine` input node to use specified device instead of system default |
| `Views/Settings/SpeechEngineSettingsView.swift` | Add "Microphone" picker section showing available devices from `AudioDeviceManager` |
| `Services/SettingsManager.swift` | Add `selectedAudioDeviceUID` property and `SettingKey.audioDevice` |
| `App/AppState.swift` | Own `AudioDeviceManager` instance; propagate device selection to `AudioCaptureManager`; handle device disconnect fallback |
| `Pipeline/TranscriptionPipeline.swift` | Pass selected device UID to `AudioCaptureManager.startCapture()` |

---

## Implementation Priority

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| P0 | #2 OpenAI Model Picker Bug | Small | Bug fix -- broken core flow |
| P0 | #7 Settings Default Tab | Small | UX polish -- trivial fix |
| P1 | #1 AI Polish "None" State | Small | UX clarity |
| P1 | #5 Shortcuts Cleanup | Small | UX clarity |
| P2 | #3 Ollama Model Management | Medium | Power user feature |
| P2 | #4 Ollama Prompt Restrictions | Medium | Quality improvement |
| P2 | #9 Audio Input Device Selection | Medium | Core feature gap |
| P3 | #8 WhisperKit Quality Parity | Large | Backend parity |
| P3 | #6 Noise Cancellation | Large | Pipeline enhancement, external dependency |
