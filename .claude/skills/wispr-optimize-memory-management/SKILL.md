---
name: wispr-optimize-memory-management
description: "Use when diagnosing high memory usage during or after transcription, implementing backend switching, managing capturedSamples growth during long recordings, or reviewing model caching behaviour for WhisperKit or FluidAudio."
---

# Optimize Memory Management

## Core Rule

Only one ASR backend may be in memory at a time. Violating this loads two large ML models simultaneously (~500 MB+).

## capturedSamples Growth

`AudioCaptureManager` accumulates Float32 samples in `capturedSamples: [Float]` during recording. Each second of audio at 16kHz = 64 KB. A 60-second recording = ~3.8 MB — acceptable. However, always clear after use:

```swift
// In AudioCaptureManager — call after handing samples to pipeline
func reset() {
    capturedSamples.removeAll(keepingCapacity: true)  // keeps buffer allocation
    // keepingCapacity avoids reallocation on next recording session
}
```

Never hold onto `capturedSamples` in multiple places. Pass a copy to the ASR backend, then reset.

## Backend Swap Memory Safety

```swift
// ASRManager.switchBackend(to:) — correct order
func switchBackend(to newType: ASRBackendType) async throws {
    // 1. Unload current — frees model memory FIRST
    await activeBackend.unload()

    // 2. Swap reference
    activeBackendType = newType
    activeBackend = newType == .parakeet
        ? ParakeetBackend()
        : WhisperKitBackend()

    // 3. Prepare new — loads into now-freed memory
    try await activeBackend.prepare()
}
```

## Model Caching (no manual management needed)

| Backend | Cache location | Cleared by |
|---|---|---|
| WhisperKit | `~/Library/Caches/huggingface/` | OS cache pressure or manual delete |
| FluidAudio | FluidAudio-internal path | OS cache pressure or manual delete |

Neither cache needs manual management. `downloadAndLoad` / `WhisperKit(model:)` use cached files on subsequent calls — `prepare()` is fast after first run.

## unload() Must Nil All References

```swift
// ParakeetBackend
func unload() async {
    fluidAsrManager = nil   // releases AsrManager
    fluidModels = nil       // releases AsrModels (large weights)
    isReady = false
}

// WhisperKitBackend
func unload() async {
    whisperKit = nil        // releases WhisperKit (large weights)
    isReady = false
}
```

If you hold a second reference anywhere (e.g. in a closure), ARC will NOT free the model. Audit captures in any Task or closure that references backend properties.

## Checklist

- [ ] `capturedSamples.removeAll(keepingCapacity: true)` called after pipeline consumes samples
- [ ] `unload()` called before `prepare()` on any backend switch
- [ ] No `Task { [self] in ... }` captures that retain a backend actor after `unload()`
- [ ] Only one backend actor exists in memory at a time (old one nilled before new one is `prepare()`-ed)
- [ ] LLM connectors (OpenAI/Gemini) are lightweight (URLSession-based) — no special memory management needed
