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
@preconcurrency import AVFoundation
// FluidAudio and WhisperKit MUST also use @preconcurrency — they are not fully Sendable-annotated:
// @preconcurrency import FluidAudio
// @preconcurrency import WhisperKit
// @preconcurrency import YourSDK  // apply to any other SDK that is not fully Sendable-annotated

/// <Name> ASR backend — <brief description>.
actor <Name>Backend: ASRBackend {
    private(set) var isReady = false

    // MARK: - Streaming support

    /// Set to `true` if this backend supports streaming transcription.
    var supportsStreaming: Bool { false }

    // MARK: - Lifecycle

    func prepare() async throws {
        // Load / download model here
        isReady = true
    }

    func unload() async {
        // Release model resources
        isReady = false
    }

    // MARK: - Batch transcription

    func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady else { throw ASRError.notReady }
        let startTime = CFAbsoluteTimeGetCurrent()
        // ... call SDK ...
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        return ASRResult(
            text: "",
            language: "en",
            duration: 0,
            processingTime: elapsed,
            backendType: .<caseName>
        )
    }

    func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady else { throw ASRError.notReady }
        let startTime = CFAbsoluteTimeGetCurrent()
        // ... convert samples or pass directly to SDK ...
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        return ASRResult(
            text: "",
            language: "en",
            duration: 0,
            processingTime: elapsed,
            backendType: .<caseName>
        )
    }

    // MARK: - Streaming ASR (implement if supportsStreaming = true)

    // Default protocol extensions throw ASRError.streamingNotSupported.
    // Override these if your backend supports streaming:

    // func startStreaming(options: TranscriptionOptions) async throws {
    //     guard isReady else { throw ASRError.notReady }
    //     // Initialize streaming session
    // }
    //
    // func feedAudio(_ buffer: AVAudioPCMBuffer) async throws {
    //     // Feed audio buffer to streaming session
    // }
    //
    // func finalizeStreaming() async throws -> ASRResult {
    //     // Finalize and return complete transcript
    // }
    //
    // func cancelStreaming() async {
    //     // Cancel session, discard partial results
    // }
}
```

### ASRBackend protocol reference

```swift
protocol ASRBackend: Actor {
    var isReady: Bool { get }
    func prepare() async throws
    func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> ASRResult
    func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult
    func unload() async

    // Streaming (optional — defaults throw ASRError.streamingNotSupported)
    var supportsStreaming: Bool { get }
    func startStreaming(options: TranscriptionOptions) async throws
    func feedAudio(_ buffer: AVAudioPCMBuffer) async throws
    func finalizeStreaming() async throws -> ASRResult
    func cancelStreaming() async
}
```

### TranscriptionOptions reference

```swift
struct TranscriptionOptions: Sendable {
    var language: String?               // nil = auto-detect
    var enableTimestamps: Bool = true
    var temperature: Float = 0.0
    var compressionRatioThreshold: Float = 2.4
    var logProbThreshold: Float = -1.0
    var noSpeechThreshold: Float = 0.6
    var skipSpecialTokens: Bool = true
    var usePrefixLanguageToken: Bool = true
    static let `default` = TranscriptionOptions()
}
```

### ASRResult reference

```swift
struct ASRResult: Sendable {
    let text: String
    let language: String?
    let duration: TimeInterval
    let processingTime: TimeInterval
    let backendType: ASRBackendType
}
```

## Step 2 — Add case to ASRBackendType enum

File: `Sources/EnviousWispr/Models/ASRResult.swift`

```swift
enum ASRBackendType: String, Codable, Sendable {
    case parakeet
    case whisperKit
    case <caseName>   // ADD THIS

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet v3"
        case .whisperKit: return "WhisperKit"
        case .<caseName>: return "<Display Name>"  // ADD THIS
        }
    }
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

## Step 4 — Add to SpeechEngineSettingsView picker

File: `Sources/EnviousWispr/Views/Settings/SpeechEngineSettingsView.swift`

Inside the `Picker("Backend", ...)` block, add:
```swift
Text("<Display Name>").tag(ASRBackendType.<caseName>)
```

## Step 5 — Verify

```bash
swift build
```

Check for actor isolation errors (see `audit-actor-isolation` skill) and
FluidAudio naming collisions (see `resolve-naming-collisions` skill) if applicable.

## Gotchas

- **FluidAudio collision**: Never qualify `FluidAudio.X` — use unqualified names (`AsrManager`, `AsrModels`)
- **ASRResult conflict**: Our `ASRResult` (in `Models/ASRResult.swift`) vs FluidAudio's. Use unqualified name — the return type resolves via protocol
- **@preconcurrency imports**: Required for FluidAudio, WhisperKit, AVFoundation
- **Audio format**: 16kHz mono Float32 always (`AudioConstants.sampleRate`, `AudioConstants.channels`)
- **Backend lifecycle**: One active at a time. `ASRManager.switchBackend()` calls `unload()` on the old one before switching
- **Streaming sessions**: If backend supports streaming, guard against double-session by cancelling any existing session in `startStreaming()`
