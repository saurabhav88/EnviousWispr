---
name: wispr-configure-language-settings
description: "Use when adding language selection to the UI, mapping TranscriptionOptions to backend-specific decode options, handling the Parakeet English-only constraint, or passing language codes through the pipeline to WhisperKit."
---

# Configure Language Settings

## TranscriptionOptions Model

```swift
struct TranscriptionOptions {
    var language: String?         // nil = auto-detect; BCP-47 code e.g. "fr", "de", "ja"
    var enableTimestamps: Bool = false
}
```

## Parakeet (English-only)

ParakeetBackend ignores `language`; always produces English output. Validate at call site:

```swift
// In TranscriptionPipeline or ASRManager
if options.language != nil && options.language != "en" && activeBackend == .parakeet {
    // Warn user or silently fall back — do NOT crash
}
```

Do not pass language to FluidAudio — `AsrManager` has no language parameter.

## WhisperKit Language Mapping

WhisperKit accepts a language code in `DecodingOptions`. Map from `TranscriptionOptions`:

```swift
@preconcurrency import WhisperKit

func makeDecodingOptions(from options: TranscriptionOptions) -> DecodingOptions {
    var decoding = DecodingOptions()
    decoding.language = options.language     // nil = auto-detect (multilingual model)
    decoding.withoutTimestamps = !options.enableTimestamps
    return decoding
}
```

Usage in `WhisperKitBackend.transcribe()`:

```swift
func transcribe(audioURL: URL) async throws -> ASRResult {
    guard let kit = whisperKit else { throw ASRError.notReady }
    let decodingOptions = makeDecodingOptions(from: currentOptions)
    let results = try await kit.transcribe(audioPath: audioURL.path,
                                           decodeOptions: decodingOptions)
    let text = results.map(\.text).joined(separator: " ")
    return ASRResult(text: text, language: currentOptions.language ?? "auto", duration: 0)
}
```

## Supported Language Codes (WhisperKit)

WhisperKit supports 99+ languages using ISO 639-1 codes: `"en"`, `"fr"`, `"de"`, `"es"`, `"zh"`, `"ja"`, `"ko"`, `"ar"`, `"ru"`, `"pt"`, etc. Pass `nil` to use auto-detection (recommended for multilingual content).

## Settings Persistence

```swift
// Save
UserDefaults.standard.set(options.language, forKey: "transcriptionLanguage")

// Load
let lang = UserDefaults.standard.string(forKey: "transcriptionLanguage")  // nil if unset
```

## Checklist

- [ ] `language: nil` means auto-detect — never default to `"en"` for WhisperKit
- [ ] Parakeet usage with non-English language triggers a user-visible warning, not a crash
- [ ] `DecodingOptions.language` is set from `TranscriptionOptions.language` (not hardcoded)
- [ ] Language setting is persisted to `UserDefaults` and restored on launch
