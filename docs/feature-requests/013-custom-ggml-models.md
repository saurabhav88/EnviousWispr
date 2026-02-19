# Feature: Custom GGML Model Support

**ID:** 013
**Category:** Audio & Models
**Priority:** Low
**Inspired by:** Handy — any `.bin` file in models dir auto-discovered as custom Whisper model
**Status:** Ready for Implementation

## Problem

Users are limited to the pre-defined WhisperKit model variants (base, small, large-v3). Power users who have fine-tuned Whisper models or want to use community models (e.g., distil-whisper, specialized language models) cannot load them.

## Proposed Solution

**Option A (chosen):** Allow users to specify a custom HuggingFace repo ID that WhisperKit downloads and loads. WhisperKit's `WhisperKitConfig` already accepts a `modelRepo` parameter pointing to any HuggingFace repo that contains a WhisperKit-compatible CoreML model bundle. No new dependencies are required.

`WhisperKitBackend` gains a `customRepoID: String?` property. When non-nil it is passed to `WhisperKitConfig(model:modelRepo:)`. `ASRManager` exposes a combined `updateWhisperKit(variant:customRepoID:)` method. `AppState` persists `whisperKitCustomRepo` and wires it through. Settings shows a `TextField` with a placeholder, a clear button, and an orange notice explaining that custom repos are fetched from HuggingFace.

**Option B (not implemented):** Add whisper.cpp as a third ASR backend. Deferred — adds a C/C++ dependency, a new build step, and produces slower inference on Apple Silicon (no Neural Engine). Can be scaffolded later via the `feature-scaffolding` agent's `scaffold-asr-backend` skill.

## Files to Modify

| File | Change |
| ---- | ------ |
| `Sources/EnviousWispr/ASR/WhisperKitBackend.swift` | Add `customRepoID: String?` init parameter; pass `modelRepo` to `WhisperKitConfig` when non-nil |
| `Sources/EnviousWispr/ASR/ASRManager.swift` | Replace `updateWhisperKitModel(_:)` with `updateWhisperKit(variant:customRepoID:)` |
| `Sources/EnviousWispr/App/AppState.swift` | Add `whisperKitCustomRepo: String` persisted property; update `whisperKitModel` didSet to call new combined method |
| `Sources/EnviousWispr/Views/Settings/SettingsView.swift` | Add custom repo `TextField` inside the WhisperKit branch of `GeneralSettingsView` |

## New Types / Properties

### Updated `WhisperKitBackend`

```swift
actor WhisperKitBackend: ASRBackend {
    private(set) var isReady = false

    private let modelVariant: String
    private let customRepoID: String?   // e.g. "distil-whisper/distil-large-v3"
    private var whisperKit: WhisperKit?

    init(modelVariant: String = "large-v3", customRepoID: String? = nil) {
        self.modelVariant = modelVariant
        self.customRepoID = customRepoID
    }

    func prepare() async throws {
        var config = WhisperKitConfig(model: modelVariant)
        if let repo = customRepoID, !repo.isEmpty {
            config.modelRepo = repo
        }
        let kit = try await WhisperKit(config)
        self.whisperKit = kit
        isReady = true
    }

    // unload(), transcribe() — unchanged
}
```

### Updated `ASRManager`

Replace the existing `updateWhisperKitModel(_:)` method with:

```swift
/// Update WhisperKit model variant and/or custom HuggingFace repo.
/// Passing nil for customRepoID clears any previously set custom repo.
func updateWhisperKit(variant: String, customRepoID: String? = nil) async {
    await whisperKitBackend.unload()
    whisperKitBackend = WhisperKitBackend(
        modelVariant: variant,
        customRepoID: customRepoID
    )
    if activeBackendType == .whisperKit {
        isModelLoaded = false
    }
}
```

### `AppState` additions

```swift
var whisperKitCustomRepo: String {
    didSet {
        UserDefaults.standard.set(whisperKitCustomRepo, forKey: "whisperKitCustomRepo")
        Task {
            await asrManager.updateWhisperKit(
                variant: whisperKitModel,
                customRepoID: whisperKitCustomRepo.isEmpty ? nil : whisperKitCustomRepo
            )
        }
    }
}
```

The existing `whisperKitModel` didSet must also be updated to call the new combined method:

```swift
var whisperKitModel: String {
    didSet {
        UserDefaults.standard.set(whisperKitModel, forKey: "whisperKitModel")
        Task {
            await asrManager.updateWhisperKit(
                variant: whisperKitModel,
                customRepoID: whisperKitCustomRepo.isEmpty ? nil : whisperKitCustomRepo
            )
        }
    }
}
```

Initialise in `AppState.init()`:

```swift
whisperKitCustomRepo = defaults.string(forKey: "whisperKitCustomRepo") ?? ""
```

The `WhisperKitBackend` constructed inside `ASRManager` at app launch also needs the initial custom repo. Pass it during the first `updateWhisperKit` call or have `ASRManager.init()` accept initial values. The simplest approach: after constructing the pipeline in `AppState.init()`, call:

```swift
if selectedBackend == .whisperKit && !whisperKitCustomRepo.isEmpty {
    Task {
        await asrManager.updateWhisperKit(
            variant: whisperKitModel,
            customRepoID: whisperKitCustomRepo
        )
    }
}
```

## Implementation Plan

### Step 1 — Update `WhisperKitBackend`

Add `customRepoID: String?` to `init`. In `prepare()`, after constructing `WhisperKitConfig(model: modelVariant)`, conditionally set `config.modelRepo` when `customRepoID` is non-nil and non-empty. Check the current WhisperKit SPM API to confirm the exact property name — it is `modelRepo` in WhisperKit 0.9+. If the API differs, adjust accordingly.

The `WhisperKitConfig` struct is mutable (it is a `var`-based struct), so direct property assignment after construction is valid.

### Step 2 — Update `ASRManager`

Rename `updateWhisperKitModel(_:)` to `updateWhisperKit(variant:customRepoID:)`. Update the method body to pass both parameters to `WhisperKitBackend.init`. Update all call sites — there is currently one call site in `AppState.whisperKitModel.didSet`.

### Step 3 — Add `whisperKitCustomRepo` to `AppState`

Add the property with a `didSet` that persists to `UserDefaults` and calls `asrManager.updateWhisperKit(variant:customRepoID:)`. Add the load line in `init()`. Handle the initial population of `WhisperKitBackend` as described above (one-time Task at end of `init()` if the repo is non-empty).

Update the `whisperKitModel.didSet` to also forward the current `whisperKitCustomRepo`.

### Step 4 — Settings UI

Inside the `if appState.selectedBackend == .whisperKit` branch in `GeneralSettingsView`, after the existing `Picker("Model Quality", ...)` and its caption, add:

```swift
HStack {
    TextField(
        "Custom HuggingFace repo (e.g. distil-whisper/distil-large-v3)",
        text: $state.whisperKitCustomRepo
    )
    .textFieldStyle(.roundedBorder)

    if !appState.whisperKitCustomRepo.isEmpty {
        Button {
            state.whisperKitCustomRepo = ""
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Clear custom repo")
    }
}

if !appState.whisperKitCustomRepo.isEmpty {
    Text("Custom repo overrides the model quality selection. The repo must contain a WhisperKit-compatible CoreML bundle. Model files are downloaded from HuggingFace on first use.")
        .font(.caption)
        .foregroundStyle(.orange)
}
```

The `TextField` is bound directly to `$state.whisperKitCustomRepo`. On every character change the `didSet` fires, calling `updateWhisperKit` — this is intentional because `updateWhisperKit` only marks the backend as needing reload; actual download happens at `prepare()` time (when recording starts). No debounce is strictly required, but a debounce can be added with `onChange(of:)` + a `Task.sleep` if live-typing causes concern.

### Step 5 — Validation (lightweight)

WhisperKit will fail at `prepare()` time with a descriptive error if the repo ID is invalid or the model format is incompatible. The existing error path in `startRecording()` already surfaces this as `state = .error(...)`. No additional validation UI is required for the MVP.

An optional enhancement: add a "Verify Repo" button that calls `asrManager.loadModel()` in a task and shows a spinner, displaying the error inline if it fails. This is deferred to a follow-up.

## Testing Strategy

1. **Default behavior unchanged**: With `whisperKitCustomRepo` empty, WhisperKit loads exactly as before. Confirm by verifying `WhisperKitConfig.modelRepo` is not set in this code path.

2. **Valid custom repo**: Set `whisperKitCustomRepo` to `"distil-whisper/distil-large-v3"` (a real WhisperKit-compatible HuggingFace repo). Switch to WhisperKit backend and start recording. Verify the model downloads (network activity) and transcription succeeds.

3. **Invalid repo**: Set `whisperKitCustomRepo` to `"notarealorg/notarealrepo"`. Start recording. Verify the error state is shown in the menu bar / overlay with a legible message rather than a crash.

4. **Clear button**: Enter a custom repo, click the X button. Verify the field clears, the property resets to `""`, and the next recording uses the standard model variant.

5. **Persistence**: Enter a custom repo, quit, relaunch. The `TextField` should show the same value. The backend should use that repo on the next recording.

6. **Model variant + custom repo interaction**: With a custom repo set, change the "Model Quality" picker. Verify the picker selection is ignored (custom repo overrides it) and the caption text explains this.

7. **Backend switch**: Switch to Parakeet. Custom repo field should not be visible. Switch back to WhisperKit — field reappears with the previously entered value intact.

## Risks & Considerations

- Option B adds significant complexity (new dependency, new backend)
- GGML models don't use Neural Engine — slower on Apple Silicon than CoreML
- Model validation: need to verify format before attempting to load — addressed by surfacing WhisperKit's own error
- Storage: custom models could be very large — WhisperKit caches downloads in `~/Library/Caches/huggingface/`; no special cleanup is provided in this feature
- The `modelRepo` property name on `WhisperKitConfig` must be verified against the pinned WhisperKit version in `Package.swift` before implementation
- HuggingFace downloads require internet connectivity; the app should handle offline gracefully via the existing error path
