---
name: wispr-scaffold-asr-backend
description: >
  Use when adding a new speech recognition backend to EnviousWispr — e.g., adding
  a new CoreML model, a cloud ASR provider, or any type that must conform to
  ASRBackend and be selectable from Settings.
---

# Scaffold a New ASR Backend

## Step 1 — Create the actor file

Create `Sources/EnviousWispr/ASR/<Name>Backend.swift`.
Use `@preconcurrency import` only if the new SDK is not fully Sendable-annotated.

```swift
import AVFoundation
// @preconcurrency import YourSDK  // only if needed

actor <Name>Backend: ASRBackend {
    private(set) var isReady = false
    let supportsStreamingPartials = false

    func modelInfo() -> ASRModelInfo {
        ASRModelInfo(
            name: "<Display Name>",
            backendType: .<caseName>,
            modelSize: "<size>",
            supportedLanguages: ["en"],
            supportsStreaming: false,
            hasBuiltInPunctuation: false
        )
    }

    func prepare() async throws {
        // Load / download model here
        isReady = true
    }

    func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady else { throw ASRError.notReady }
        let startTime = CFAbsoluteTimeGetCurrent()
        // ... call SDK ...
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        return ASRResult(text: "", segments: [], language: "en",
                         duration: 0, processingTime: elapsed,
                         confidence: nil, backendType: .<caseName>)
    }

    func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady else { throw ASRError.notReady }
        // convert samples to URL or pass directly, then call transcribe(audioURL:)
        throw ASRError.unsupportedFormat // replace with real impl
    }

    func transcribeStream(
        audioBufferStream: AsyncStream<AVAudioPCMBuffer>,
        options: TranscriptionOptions
    ) -> AsyncStream<PartialTranscript> {
        AsyncStream { $0.finish() } // stub — implement if supportsStreamingPartials = true
    }

    func unload() async {
        isReady = false
    }
}
```

## Step 2 — Add case to ASRBackendType enum

File: `Sources/EnviousWispr/Models/ASRResult.swift`

```swift
enum ASRBackendType: String, Codable, CaseIterable, Sendable {
    case parakeet
    case whisperKit
    case <caseName>   // ADD THIS
}
```

## Step 3 — Wire into ASRManager

File: `Sources/EnviousWispr/ASR/ASRManager.swift`

1. Add a private property alongside the existing backends:
   ```swift
   private var <caseName>Backend = <Name>Backend()
   ```

2. Extend the `activeBackend` computed property switch:
   ```swift
   case .<caseName>: return <caseName>Backend
   ```

## Step 4 — Add to GeneralSettingsView picker

File: `Sources/EnviousWispr/Views/Settings/SettingsView.swift`

Inside the `Picker("Backend", ...)` block, add:
```swift
Text("<Display Name>").tag(ASRBackendType.<caseName>)
```
Add a matching caption `Text(...)` in the `if/else` below.

## Step 5 — Verify

```bash
swift build
```

Check for actor isolation errors (see `audit-actor-isolation` skill) and
FluidAudio naming collisions (see `resolve-naming-collisions` skill) if applicable.
