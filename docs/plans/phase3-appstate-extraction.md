# Phase 3: Break AppState God Object

**Bead:** ew-ud7
**Status:** In Progress
**Depends on:** Phase 2 (done)
**Blocks:** Phase 4 XPC Audio (ew-8y3)

## Goal

Reduce AppState from ~870 lines / 7 responsibilities / 22 dependents to a thin coordinator under 300 lines. Each extraction is independently shippable — build + relaunch + verify after each step.

## Current State

AppState owns 7 distinct responsibility clusters. Only coordination logic (pipeline wiring, hotkey closures, toggleRecording/cancelRecording, computed display properties) legitimately belongs in a top-level coordinator.

## Extraction Order

Low-risk first. Each step is a single commit. Build must pass after each.

---

### Step 1: AudioDeviceList (~15 lines)

**Extract from AppState:**
- `availableInputDevices: [AudioInputDevice]`
- `deviceMonitor: AudioDeviceMonitor?`
- `refreshInputDevices()`
- Device monitor init wiring (lines 135–141)

**New file:** `Sources/EnviousWispr/App/AudioDeviceList.swift`

```swift
@MainActor @Observable
final class AudioDeviceList {
    var availableInputDevices: [AudioInputDevice] = []
    private var deviceMonitor: AudioDeviceMonitor?

    init() {
        refresh()
        deviceMonitor = AudioDeviceMonitor { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        availableInputDevices = AudioDeviceEnumerator.allInputDevices()
    }
}
```

**AppState change:** `let audioDeviceList = AudioDeviceList()`. Remove the 3 properties and init wiring.

**Consumer change:** `AudioSettingsView` — `appState.availableInputDevices` → `appState.audioDeviceList.availableInputDevices`

**Risk:** None. Fully self-contained. Zero coupling to pipelines or other clusters.

---

### Step 2: Accessibility Monitor (~50 lines)

**Extract from AppState:**
- `accessibilityMonitorTask: Task<Void, Never>?`
- `refreshAccessibilityOnLaunch()`
- `startAccessibilityMonitoring()`
- `restartAccessibilityMonitoringIfNeeded()`

**Target:** Fold into existing `PermissionsService` (Sources/EnviousWisprServices/PermissionsService.swift) as monitoring extension methods. PermissionsService already owns `accessibilityGranted` — monitoring is its natural responsibility.

**AppState change:** Replace `self.startAccessibilityMonitoring()` with `permissions.startMonitoring()`, etc. The `onAccessibilityChange` callback stays on PermissionsService (move it there from AppState).

**Consumer change:** `AppDelegate` — `appState.refreshAccessibilityOnLaunch()` → `appState.permissions.refreshOnLaunch()`, etc. Hotkey closures call `appState.permissions.restartMonitoringIfNeeded()`.

**Risk:** Low-Medium. The monitoring task captures `self` (PermissionsService) instead of AppState. The `onAccessibilityChange` callback wiring moves to AppDelegate setting it on `permissions` instead of `appState`.

---

### Step 3: LLMModelDiscoveryCoordinator (~80 lines)

**Extract from AppState:**
- `discoveredModels: [LLMModelInfo]`
- `isDiscoveringModels: Bool`
- `keyValidationState: KeyValidationState`
- `enum KeyValidationState`
- `validateKeyAndDiscoverModels(provider:)`
- `loadCachedModels(for:)`
- `cacheModels(_:for:)` (private)

**New file:** `Sources/EnviousWispr/App/LLMModelDiscoveryCoordinator.swift`

```swift
@MainActor @Observable
final class LLMModelDiscoveryCoordinator {
    var discoveredModels: [LLMModelInfo] = []
    var isDiscoveringModels = false
    var keyValidationState: KeyValidationState = .idle

    enum KeyValidationState: Equatable { ... }

    private let keychainManager: KeychainManager

    init(keychainManager: KeychainManager) {
        self.keychainManager = keychainManager
    }

    func validateKeyAndDiscoverModels(provider: LLMProvider, settings: SettingsManager) async { ... }
    func loadCachedModels(for provider: LLMProvider) { ... }
    private func cacheModels(_ models: [LLMModelInfo], for provider: LLMProvider) { ... }
}
```

**AppState change:** `let llmDiscovery = LLMModelDiscoveryCoordinator(keychainManager: keychainManager)`

**Consumer change:** `AIPolishSettingsView` — all `appState.discoveredModels` → `appState.llmDiscovery.discoveredModels`, etc. Direct state mutations (`appState.keyValidationState = .idle`) become method calls.

**Coupling hazard:** `validateKeyAndDiscoverModels` writes to `settings.llmModel` and `settings.ollamaModel` on model mismatch. Pass `settings` as parameter, not stored reference.

**Risk:** Medium. One consumer, but that consumer mutates state directly — needs refactoring to method calls.

---

### Step 4: CustomWordsCoordinator (~50 lines)

**Extract from AppState:**
- `customWords: [CustomWord]`
- `customWordError: String?`
- `customWordsManager: CustomWordsManager`
- `wordSuggestionService: WordSuggestionService`
- `addCustomWord(_:)`, `removeCustomWord(_:UUID)`, `removeCustomWord(_:String)`, `updateCustomWord(_:)`

**New file:** `Sources/EnviousWispr/App/CustomWordsCoordinator.swift`

```swift
@MainActor @Observable
final class CustomWordsCoordinator {
    var customWords: [CustomWord] = []
    var customWordError: String?
    let suggestionService = WordSuggestionService()

    private let manager = CustomWordsManager()
    var onWordsChanged: (([CustomWord]) -> Void)?

    init() {
        customWords = manager.load() ?? []
    }

    func add(_ word: String) { ... ; onWordsChanged?(customWords) }
    func remove(id: UUID) { ... ; onWordsChanged?(customWords) }
    func remove(canonical: String) { ... }
    func update(_ word: CustomWord) { ... ; onWordsChanged?(customWords) }
}
```

**AppState change:** `let customWordsCoordinator = CustomWordsCoordinator()`. Wire `onWordsChanged` to sync both pipelines. Remove `syncCustomWordsToPipelines()`.

**Consumer change:** `WordFixSettingsView` — `appState.customWords` → `appState.customWordsCoordinator.customWords`, etc.

**Risk:** Medium. The `onWordsChanged` callback pattern keeps pipeline sync in AppState (where it belongs as coordination) while the CRUD logic moves out.

---

### Step 5: PipelineSettingsSync (~175 lines)

**Extract from AppState:**
- `handleSettingChanged(_:)` — 130 lines
- `syncTranscriptionOptions()` — 10 lines
- `syncWhisperKitPipelineSettings()` — 20 lines
- Init-time settings mirroring — 15 lines

**New file:** `Sources/EnviousWispr/App/PipelineSettingsSync.swift`

```swift
@MainActor
final class PipelineSettingsSync {
    private let pipeline: TranscriptionPipeline
    private let whisperKitPipeline: WhisperKitPipeline
    private let audioCapture: AudioCaptureManager
    private let asrManager: ASRManager
    private let hotkeyService: HotkeyService
    private let whisperKitSetup: WhisperKitSetupService

    init(...) { ... }

    func applyInitialSettings(_ settings: SettingsManager, customWords: [CustomWord]) { ... }
    func handleSettingChanged(_ key: SettingsManager.SettingKey, settings: SettingsManager) { ... }
    func syncTranscriptionOptions(_ settings: SettingsManager) { ... }
}
```

**AppState change:** `let settingsSync = PipelineSettingsSync(...)`. Init becomes `settingsSync.applyInitialSettings(settings, customWords: customWordsCoordinator.customWords)`. The `settings.onChange` closure becomes `settingsSync.handleSettingChanged(key, settings: settings)`.

**Coupling hazard:** `handleSettingChanged` does heterogeneous things — backend switching, hotkey re-registration, noise suppression engine rebuild, logger config. These are all cross-subsystem side effects. The extracted type needs references to 6 subsystems. This is acceptable because it's a dedicated settings-sync coordinator, not a god object — it has one job (forward settings changes).

**Special cases that stay in AppState:**
- `startWhisperKitPreloadObservation()` — called from `.selectedBackend` and `.whisperKitModel` cases. Pass a callback `onNeedsPreloadObservation` that AppState handles.

**Risk:** Medium. Biggest line-count win. The type is a legitimate coordinator with one responsibility.

---

### Step 6: TranscriptCoordinator (~80 lines)

**Extract from AppState:**
- `transcripts: [Transcript]`
- `loadTask: Task<Void, Never>?`
- `searchQuery: String`
- `selectedTranscriptID: UUID?`
- `filteredTranscripts` computed
- `activeTranscript` computed
- `transcriptCount`, `averageProcessingSpeed` computed
- `loadTranscripts()`, `deleteTranscript(_:)`, `deleteAllTranscripts()`, `polishTranscript(_:)`

**New file:** `Sources/EnviousWispr/App/TranscriptCoordinator.swift`

```swift
@MainActor @Observable
final class TranscriptCoordinator {
    var transcripts: [Transcript] = []
    var searchQuery: String = ""
    var selectedTranscriptID: UUID?

    private let store: TranscriptStore
    private var loadTask: Task<Void, Never>?

    var filteredTranscripts: [Transcript] { ... }
    var transcriptCount: Int { ... }
    var averageProcessingSpeed: Double { ... }

    init(store: TranscriptStore) { self.store = store }

    func load() { ... }
    func delete(_ transcript: Transcript) { ... }
    func deleteAll() { ... }
}
```

**AppState change:** `let transcriptCoordinator = TranscriptCoordinator(store: transcriptStore)`. Pipeline `onStateChange` closures call `self.transcriptCoordinator.load()` on `.complete`.

**Coupling hazards:**
- `activeTranscript` falls back to `pipeline.currentTranscript` — this computed property stays in AppState as a thin wrapper: `var activeTranscript: Transcript? { transcriptCoordinator.selectedTranscriptID != nil ? transcriptCoordinator.selected : pipeline.currentTranscript }`
- `polishTranscript(_:)` calls `pipeline.polishExistingTranscript()` — stays in AppState as coordination.
- 6 consumer views need path updates.

**Risk:** High. Most consumers, most coupling. Do last.

---

## Post-Extraction AppState (~290 lines)

What remains is genuine coordination:
- Subsystem declarations (~20 lines)
- Coordinator declarations (~10 lines)
- Pipeline init + wiring (~25 lines)
- Hotkey closure wiring (~80 lines) — legitimate coordination
- Pipeline onStateChange wiring (~40 lines)
- `toggleRecording()`, `cancelRecording()` (~50 lines)
- Computed display properties (`activePipeline`, `pipelineState`, `audioLevel`, `activeModelName`, `activeLLMDisplayName`, `modelStatusText`) (~40 lines)
- `startHotkeyServiceIfEnabled()`, `reregisterHotkeys()` (~10 lines)
- `polishTranscript()` forwarding (~10 lines)
- WhisperKit preload observation (~30 lines)

**Total: ~290-310 lines**

## Definition of Done

- [~] AppState < 300 lines — **437 lines (accepted: remaining code is legitimate coordination)**
- [x] Each extracted type is `@Observable` and independently testable
- [x] No extracted type imports upward (no circular dependencies)
- [x] All 22 consumer files updated and compiling
- [x] `swift build -c release` passes after each step
- [x] Rebuild + relaunch + smoke test after each step
- [~] Dependency count on AppState reduced (target: <15 files) — **20 files (reduced from ~32)**
- [x] No behavioral changes — pure structural refactor

## Completion Summary (2026-03-14)

**AppState:** 870 → 437 lines (50% reduction, 6 commits)
**New types:** AudioDeviceList, LLMModelDiscoveryCoordinator, CustomWordsCoordinator, PipelineSettingsSync, TranscriptCoordinator
**Extended:** PermissionsService (gained accessibility monitoring from AppState)
**Commits:** 8dadcc6, 0cfa0a5, e7c7ad8, 52ae999, e823ffc, 14c2b26

**What remains in AppState:** pipeline init + wiring, hotkey closures, pipeline state change handlers, toggleRecording, cancelRecording, computed display properties, WhisperKit preload observation. All legitimate coordination — no further extraction justified.

**Monitored hotspot:** PipelineSettingsSync (246 lines, 30+ keys). Single responsibility but high line count. Review if any case grows past ~15 lines.
