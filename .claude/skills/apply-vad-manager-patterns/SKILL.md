---
name: apply-vad-manager-patterns
description: "Use when implementing or modifying VAD (Voice Activity Detection) logic, silence detection, auto-stop behaviour, or any code that touches VadManager, VadStreamState, VadSegmentationConfig, or SilenceDetector."
---

# Apply VadManager Patterns

## Setup

```swift
@preconcurrency import FluidAudio
import Foundation  // required for TimeInterval alongside FluidAudio

actor SilenceDetector {
    private var vadManager = VadManager(
        config: VadConfig(defaultThreshold: 0.5)
    )
    private var streamState: VadStreamState = .initial()
    private let segConfig = VadSegmentationConfig(
        minSpeechDuration: 0.3,
        minSilenceDuration: 1.5,
        speechPadding: 0.1
    )
}
```

## Chunk Processing

Chunk size is fixed at **4096 samples = 256ms at 16kHz**.

```swift
func process(samples: [Float]) async throws -> Bool {
    // Returns true when speech has ended (auto-stop signal)
    let chunkSize = 4096
    var speechEndDetected = false

    for chunkStart in stride(from: 0, to: samples.count, by: chunkSize) {
        let end = min(chunkStart + chunkSize, samples.count)
        let chunk = Array(samples[chunkStart..<end])

        let result = try await vadManager.processStreamingChunk(
            chunk,
            state: streamState,
            config: segConfig
        )

        streamState = result.state

        if let event = result.event {
            if event.isStart { /* speech began */ }
            if event.isEnd   { speechEndDetected = true }
        }
    }
    return speechEndDetected
}
```

## Session Reset

Call `reset()` before every new recording session to clear internal state.

```swift
func reset() {
    streamState = .initial()
    // VadManager itself is stateless across sessions; only streamState needs reset
}
```

## Speech Boundary Detection

- `result.event?.isStart` — user started speaking
- `result.event?.isEnd`   — silence threshold exceeded after speech; trigger auto-stop

## Key Constants

| Parameter | Value | Notes |
|---|---|---|
| Chunk size | 4096 samples | 256ms at 16kHz — do not change |
| VAD threshold | 0.5 | Balanced sensitivity |
| minSpeechDuration | 0.3s | Ignore very short sounds |
| minSilenceDuration | 1.5s | Configurable; maps to UI slider |
| speechPadding | 0.1s | Extra audio kept around speech |

## Import Note

Always import `Foundation` alongside `FluidAudio` — `TimeInterval` (used by VAD configs)
lives in Foundation and is not re-exported by FluidAudio.
