# UI/UX Polish — 8 Fixes

## Context
User-identified friction points in the app dropdown menu, settings UI, and recording pipeline. Goal: streamline for consumer readiness by removing clutter, consolidating settings, and fixing behavioral bugs.

## Implementation Order
`1 → 7 → 2 → 3 → 8 → 4 → 5 → 6` (grouped by file to minimize conflicts)

---

## Fix 1: Remove gear icon from dropdown
**File**: `Sources/EnviousWispr/App/AppDelegate.swift:122`
**Change**: `"⚙️ Settings..."` → `"Settings..."`

---

## Fix 7: Remove "Start Recording" — single recording action
**File**: `Sources/EnviousWispr/App/AppDelegate.swift:106-112`
**Change**: Delete the conditional "Record + AI Polish" block (lines 106-112). Keep only the existing "Start Recording" / "Stop Recording" item. LLM polish already runs automatically when a provider is configured (`LLMPolishStep.isEnabled` checks `llmProvider != .none`).

---

## Fix 2: Fix status text — show ASR + LLM model
**Files**: `AppDelegate.swift:79-95`, `AppState.swift`, `LLMResult.swift`

1. Add `LLMProvider.displayName` computed property in `LLMResult.swift`
2. Add `activeLLMDisplayName` computed property on `AppState` — returns model name if LLM configured, "LLM Deactivated" if not
3. Replace lines 79-95 in `AppDelegate.populateMenu()`:
   - Remove old status line (state.statusText + model)
   - Remove transcript count item
   - New single status: `"Parakeet v3 — Gemini 2.5 Flash"` or `"Parakeet v3 — LLM Deactivated"`

---

## Fix 3: Add API key help links
**File**: `Sources/EnviousWispr/Views/Settings/AIPolishSettingsView.swift`

- After OpenAI API key buttons (line ~129): Add `HStack { Text("Get your API key at") Link("platform.openai.com", ...) }` with `.font(.caption)`
- After Gemini API key buttons (line ~171): Add `HStack { Text("Get your API key at") Link("aistudio.google.com", ...) }` with `.font(.caption)`

---

## Fix 8: Silently discard too-short recordings
**Files**: `TranscriptionPipeline.swift`, `Constants.swift`

1. Add `TimingConstants.minimumRecordingDuration = 0.5` in Constants.swift
2. Add `private var recordingStartTime: Date?` property on TranscriptionPipeline
3. Set `recordingStartTime = Date()` in `startRecording()` after `state = .recording`
4. In `stopAndTranscribe()`, check elapsed time — if < 0.5s, silently reset to `.idle` and return
5. Change "No speech detected" error (line ~170) to silently return to `.idle` instead of `.error`
6. Clear `recordingStartTime` in `cancelRecording()` and `reset()` if they exist

---

## Fix 4: Move benchmark to debug window
**Source**: `SpeechEngineSettingsView.swift:47-84` (Section "Performance"))
**Destination**: `DiagnosticsSettingsView.swift` (new Section at end of Form)

- Cut the entire Performance section from SpeechEngineSettingsView
- Paste into DiagnosticsSettingsView before the closing `}` of Form
- `appState.benchmark` and `appState.asrManager` are already available via `@Environment`

---

## Fix 5: Merge Voice Detection into Speech Engine
**Files**: `SpeechEngineSettingsView.swift`, `SettingsSection.swift`, `SettingsView.swift`, `VoiceDetectionSettingsView.swift`

1. Copy VAD section content from `VoiceDetectionSettingsView` into `SpeechEngineSettingsView` as new `Section("Voice Activity Detection")` (after ASR Backend, where Recording used to be before Fix 6 removes it)
2. Copy the `vadSensitivityLabel()` helper function
3. Remove `.voiceDetection` from `SettingsSection` enum (all 4 computed properties + group mapping)
4. Remove `case .voiceDetection:` from `SettingsView.settingsDetail`
5. Delete `VoiceDetectionSettingsView.swift`

---

## Fix 6: Simplify shortcuts — one keybind, one PTT toggle
**Files**: `ShortcutsSettingsView.swift`, `SpeechEngineSettingsView.swift`, `SettingsManager.swift`, `HotkeyService.swift`, `AppState.swift`

### 6a — ShortcutsSettingsView.swift (full rewrite)
- Section "Global Hotkey": Toggle enable
- Section "Transcribe Shortcut":
  - One `HotkeyRecorderView` (binds to `toggleKeyCode`/`toggleModifiers`)
  - `Toggle("Push to Talk", isOn: $state.settings.isPushToTalk)` with descriptive help text
  - Cancel hotkey recorder (keep as-is)
- Remove: second PTT recorder, "Current Mode" section, "Hotkey Reference" section

### 6b — SettingsManager.swift
- Add computed `isPushToTalk: Bool` that maps to `recordingMode`:
  ```swift
  var isPushToTalk: Bool {
      get { recordingMode == .pushToTalk }
      set { recordingMode = newValue ? .pushToTalk : .toggle }
  }
  ```

### 6c — HotkeyService.swift (unify hotkey registration)
- In `start()`: sync PTT keybind to match toggle keybind before registering
- In `handleCarbonHotkey()`: Route `HotkeyID.toggle` based on `recordingMode` — if toggle mode, fire `onToggleRecording`; if PTT mode, handle press/release via `onStartRecording`/`onStopRecording`
- Keep `HotkeyID.ptt` registration but have it use the same keyCode/modifiers as toggle
- In `handleFlagsChanged()`: Check `toggleKeyCode` for both modes (remove separate `pushToTalkKeyCode` check)
- Update `hotkeyDescription` to always use `toggleKeyCode`/`toggleModifiers`

### 6d — SpeechEngineSettingsView.swift
- Remove `Section("Recording")` (the mode picker) — mode is now controlled by the PTT toggle in Shortcuts

### 6e — AppState.swift `handleSettingChanged`
- On `.toggleKeyCode`/`.toggleModifiers` change: also sync `hotkeyService.pushToTalkKeyCode`/`pushToTalkModifiers`
- Remove `.pushToTalkKeyCode`/`.pushToTalkModifiers` cases (no longer independently configurable)

---

## Files Modified (14 total)

| File | Fixes |
|------|-------|
| `App/AppDelegate.swift` | 1, 2, 7 |
| `Models/LLMResult.swift` | 2 |
| `App/AppState.swift` | 2, 6e |
| `Views/Settings/AIPolishSettingsView.swift` | 3 |
| `Views/Settings/SpeechEngineSettingsView.swift` | 4, 5, 6d |
| `Views/Settings/DiagnosticsSettingsView.swift` | 4 |
| `Views/Settings/VoiceDetectionSettingsView.swift` | 5 (delete) |
| `Views/Settings/SettingsSection.swift` | 5 |
| `Views/Settings/SettingsView.swift` | 5 |
| `Views/Settings/ShortcutsSettingsView.swift` | 6a |
| `Services/SettingsManager.swift` | 6b |
| `Services/HotkeyService.swift` | 6c |
| `Pipeline/TranscriptionPipeline.swift` | 8 |
| `Utilities/Constants.swift` | 8 |

## Verification
1. `swift build` — must compile clean
2. `/wispr-rebuild-and-relaunch` — bundle and launch
3. `/wispr-run-smart-uat` — behavioral tests against running app
4. Manual checks: dropdown menu shows correct status, settings tabs consolidated, single shortcut works in both toggle and PTT modes, brief hotkey press doesn't show error
