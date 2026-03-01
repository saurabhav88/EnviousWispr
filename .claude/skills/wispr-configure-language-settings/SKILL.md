---
name: wispr-configure-language-settings
description: "Use when adding language selection to the UI, mapping TranscriptionOptions to backend-specific decode options, handling the Parakeet English-only constraint, or passing language codes through the pipeline to WhisperKit."
---

# Configure Language Settings

## TranscriptionOptions Model

File: `Sources/EnviousWispr/Models/ASRResult.swift`

```swift
struct TranscriptionOptions: Sendable {
    var language: String?               // nil = auto-detect; BCP-47 code e.g. "fr", "de", "ja"
    var enableTimestamps: Bool = true

    // WhisperKit quality parameters
    var temperature: Float = 0.0
    var compressionRatioThreshold: Float = 2.4
    var logProbThreshold: Float = -1.0
    var noSpeechThreshold: Float = 0.6
    var skipSpecialTokens: Bool = true
    var usePrefixLanguageToken: Bool = true

    static let `default` = TranscriptionOptions()
}
```

## Parakeet (English-only)

ParakeetBackend ignores `language` and all quality parameters; always produces English output. Validate at call site:

```swift
// In TranscriptionPipeline or ASRManager
if options.language != nil && options.language != "en" && activeBackendType == .parakeet {
    // Warn user or silently fall back — do NOT crash
}
```

Do not pass language to FluidAudio — `AsrManager` has no language parameter.

## WhisperKit Language + Quality Mapping

WhisperKit accepts language and quality parameters in `DecodingOptions`. Map from `TranscriptionOptions` using `makeDecodeOptions()`:

File: `Sources/EnviousWispr/ASR/WhisperKitBackend.swift` (lines 65-88)

```swift
private func makeDecodeOptions(from options: TranscriptionOptions) -> DecodingOptions {
    var decodeOptions = DecodingOptions()

    // Language: nil enables auto-detection
    decodeOptions.language = options.language

    // Timestamps
    decodeOptions.wordTimestamps = options.enableTimestamps

    // Quality parameters
    decodeOptions.temperature = options.temperature
    decodeOptions.compressionRatioThreshold = options.compressionRatioThreshold
    decodeOptions.logProbThreshold = options.logProbThreshold
    decodeOptions.noSpeechThreshold = options.noSpeechThreshold
    decodeOptions.skipSpecialTokens = options.skipSpecialTokens

    // Temperature fallback: retry with higher temperature if quality filters trigger
    if options.temperature < 0.5 {
        decodeOptions.temperatureFallbackCount = 3
        decodeOptions.temperatureIncrementOnFallback = 0.2
    }

    return decodeOptions
}
```

## mapResults() Helper

WhisperKit returns `[TranscriptionResult]`. Use `mapResults()` to convert to our `ASRResult`:

```swift
private func mapResults(_ results: [TranscriptionResult], processingTime: TimeInterval) -> ASRResult {
    let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    let language = results.first?.language

    let duration: TimeInterval = if let lastSeg = results.last?.segments.last {
        TimeInterval(lastSeg.end)
    } else {
        0
    }

    return ASRResult(
        text: text,
        language: language,
        duration: duration,
        processingTime: processingTime,
        backendType: .whisperKit
    )
}
```

## Usage in transcribe()

Both transcribe overloads follow the same pattern:

```swift
func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> ASRResult {
    guard isReady, let kit = whisperKit else { throw ASRError.notReady }

    let decodeOptions = makeDecodeOptions(from: options)
    let startTime = CFAbsoluteTimeGetCurrent()
    let results: [TranscriptionResult]
    do {
        results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: decodeOptions)
    } catch {
        throw ASRError.transcriptionFailed(error.localizedDescription)
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - startTime

    return mapResults(results, processingTime: elapsed)
}
```

## Supported Language Codes (WhisperKit)

WhisperKit supports 99+ languages using ISO 639-1 codes: `"en"`, `"fr"`, `"de"`, `"es"`, `"zh"`, `"ja"`, `"ko"`, `"ar"`, `"ru"`, `"pt"`, etc. Pass `nil` to use auto-detection (recommended for multilingual content).

## Settings Persistence

Language is persisted via `AppSettings` (which uses `@AppStorage` / `UserDefaults`):

```swift
// In AppSettings
@AppStorage("transcriptionLanguage") var transcriptionLanguage: String?

// Build TranscriptionOptions from settings
var options = TranscriptionOptions.default
options.language = settings.transcriptionLanguage
```

## Checklist

- [ ] `language: nil` means auto-detect — never default to `"en"` for WhisperKit
- [ ] Parakeet usage with non-English language triggers a user-visible warning, not a crash
- [ ] `DecodingOptions.language` is set from `TranscriptionOptions.language` (not hardcoded)
- [ ] All 7 quality params mapped in `makeDecodeOptions()`: temperature, compressionRatioThreshold, logProbThreshold, noSpeechThreshold, skipSpecialTokens, wordTimestamps, temperatureFallback
- [ ] Use `mapResults()` to convert `[TranscriptionResult]` to `ASRResult` (handles text join, language extraction, duration from segments)
- [ ] Language setting is persisted via `AppSettings` and restored on launch
- [ ] Function name is `makeDecodeOptions` (NOT `makeDecodingOptions`)
