---
name: wispr-manage-model-loading
description: "Use when implementing prepare(), unload(), or isReady logic for ASR backends, adding a new backend, or debugging issues where transcription fails because a model was not loaded or was loaded twice."
---

# Manage Model Loading

## Backend Lifecycle Contract

Every `ASRBackend` actor must implement this lifecycle:

```
prepare()  →  [model in memory, isReady = true]
transcribe()  →  [uses loaded model]
unload()   →  [model freed, isReady = false]
```

Only one backend may be prepared at a time. Always `unload()` the current backend before `prepare()`-ing another.

## ParakeetBackend — prepare()

```swift
@preconcurrency import FluidAudio

actor ParakeetBackend: ASRBackend {
    private var fluidModels: AsrModels?
    private var fluidAsrManager: AsrManager?
    private(set) var isReady = false

    func prepare() async throws {
        guard !isReady else { return }
        // Downloads on first run; cached to ~/Library/Caches on subsequent runs
        fluidModels = try await AsrModels.downloadAndLoad(version: .v3)
        fluidAsrManager = AsrManager(config: .default)
        try await fluidAsrManager!.initialize(models: fluidModels!)
        isReady = true
    }

    func unload() async {
        fluidAsrManager = nil
        fluidModels = nil
        isReady = false
    }
}
```

## WhisperKitBackend — prepare()

```swift
@preconcurrency import WhisperKit

actor WhisperKitBackend: ASRBackend {
    private let modelVariant = "base"
    private var whisperKit: WhisperKit?
    private(set) var isReady = false

    func prepare() async throws {
        guard !isReady else { return }
        whisperKit = try await WhisperKit(model: modelVariant)
        isReady = true
    }

    func unload() async {
        whisperKit = nil
        isReady = false
    }
}
```

## Guard Pattern in transcribe()

```swift
func transcribe(audioURL: URL) async throws -> ASRResult {
    guard isReady, let mgr = fluidAsrManager else {
        throw ASRError.notReady   // or ASRError.modelNotLoaded
    }
    // ...
}
```

## Key Rules

- `prepare()` must be idempotent — check `isReady` at entry and return early.
- `unload()` must nil out all model references so ARC can reclaim memory.
- Model download is implicit in `AsrModels.downloadAndLoad` and `WhisperKit(model:)` — no separate download step.
- WhisperKit caches to `~/Library/Caches/huggingface/`; FluidAudio caches to its own path. Neither needs manual cache management.

## Checklist

- [ ] `prepare()` guards on `isReady` and returns early if already prepared
- [ ] `unload()` nils all model references and sets `isReady = false`
- [ ] `transcribe()` guards on `isReady` and throws if not ready
- [ ] Caller (ASRManager/TranscriptionPipeline) calls `unload()` on old backend before `prepare()` on new one
