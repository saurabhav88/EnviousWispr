# Feature: Chinese Traditional/Simplified Conversion

**ID:** 016
**Category:** Localization & i18n
**Priority:** Low
**Inspired by:** Handy — OpenCC via `ferrous-opencc` for Tw2sp / S2twp conversion
**Status:** Ready for Implementation

## Problem

Whisper models output Chinese text in one variant (typically Simplified). Users who need Traditional Chinese (Taiwan, Hong Kong) or vice versa have no way to convert automatically.

## Proposed Solution

Add a post-transcription conversion step for Chinese text using a pure-Swift character dictionary lookup. No C++ bridge, no new SPM dependencies — conversion tables are vendored as Swift `[Character: Character]` literals derived from OpenCC's MIT-licensed data. The conversion runs between the ASR result and `Transcript` creation in `TranscriptionPipeline.stopAndTranscribe()`. The setting is hidden when Parakeet is selected (English-only backend).

## Files to Modify

- `Sources/EnviousWispr/App/AppState.swift` — add `chineseConversionMode: ChineseConversionMode` persisted setting
- `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` — add `chineseConversionMode` property, call `ChineseConverter` between ASR result and `Transcript` creation
- `Sources/EnviousWispr/Views/Settings/SettingsView.swift` — add Chinese conversion picker inside `GeneralSettingsView`, visible only when WhisperKit backend is selected

## New Files

- `Sources/EnviousWispr/Utilities/ChineseConversionMode.swift` — enum definition
- `Sources/EnviousWispr/Utilities/ChineseConverter.swift` — converter actor with lookup logic
- `Sources/EnviousWispr/Utilities/ChineseConversionTables.swift` — vendored character mapping dictionaries (generated from OpenCC MIT data)

## Implementation Plan

### Step 1: Define ChineseConversionMode enum

```swift
// Sources/EnviousWispr/Utilities/ChineseConversionMode.swift

/// Post-ASR Chinese character conversion mode.
/// Only relevant when the ASR backend outputs Chinese (WhisperKit with zh language).
enum ChineseConversionMode: String, CaseIterable, Codable, Sendable {
    /// No conversion — output as-is from ASR.
    case none = "none"
    /// Simplified → Traditional (Taiwan standard, OpenCC STW mapping).
    case simplifiedToTraditionalTW = "s2tw"
    /// Simplified → Traditional (Hong Kong standard, OpenCC STHK mapping).
    case simplifiedToTraditionalHK = "s2hk"
    /// Traditional → Simplified (OpenCC T2S mapping).
    case traditionalToSimplified = "t2s"

    var displayName: String {
        switch self {
        case .none:                      return "None (as-is)"
        case .simplifiedToTraditionalTW: return "Simplified → Traditional (TW)"
        case .simplifiedToTraditionalHK: return "Simplified → Traditional (HK)"
        case .traditionalToSimplified:   return "Traditional → Simplified"
        }
    }
}
```

### Step 2: Implement ChineseConverter

The converter uses dictionary lookup — each character in the input is looked up in the relevant mapping table. Unmapped characters pass through unchanged. The tables are `[Character: Character]` Swift dictionaries compiled at build time, giving O(1) per-character lookup with no runtime I/O.

```swift
// Sources/EnviousWispr/Utilities/ChineseConverter.swift
import Foundation

/// Converts Chinese text between Simplified and Traditional variants.
///
/// Uses pure-Swift character dictionary lookup from vendored OpenCC tables.
/// No C++ bridge, no external dependencies.
/// Thread-safe: all methods are nonisolated and operate on value types.
struct ChineseConverter {

    /// Convert `text` using the given mode. Returns `text` unchanged if mode is `.none`
    /// or if `text` contains no characters in the relevant table.
    static func convert(_ text: String, mode: ChineseConversionMode) -> String {
        guard mode != .none else { return text }
        let table = ChineseConversionTables.table(for: mode)
        return String(text.map { table[$0] ?? $0 })
    }

    /// Returns true if the detected language code indicates Chinese output.
    /// WhisperKit returns BCP-47 codes like "zh", "zh-CN", "zh-TW".
    static func isChinese(language: String?) -> Bool {
        guard let lang = language else { return false }
        return lang.lowercased().hasPrefix("zh")
    }
}
```

### Step 3: Generate ChineseConversionTables.swift

The conversion tables are derived from OpenCC's MIT-licensed STCharacters.txt, TWVariants.txt, HKVariants.txt data files. To keep the bundle small, only single-character mappings are included in Phase 1 (covering ~90% of practical cases). Multi-character phrase mappings (e.g. "軟件" → "软件") are deferred to Phase 2.

The tables are encoded as Swift dictionary literals so they compile into the binary with no file I/O at runtime:

```swift
// Sources/EnviousWispr/Utilities/ChineseConversionTables.swift
// AUTO-GENERATED from OpenCC data (MIT License). Do not edit manually.
// Regenerate with: scripts/generate-chinese-tables.py

enum ChineseConversionTables {

    /// Simplified → Traditional (Taiwan). ~7,000 character mappings.
    static let simplifiedToTW: [Character: Character] = [
        "爱": "愛", "罢": "罷", "备": "備", "边": "邊", "标": "標",
        "别": "別", "补": "補", "财": "財", "层": "層", "产": "產",
        // ... (full table generated by script) ...
    ]

    /// Simplified → Traditional (Hong Kong). ~5,500 character mappings.
    static let simplifiedToHK: [Character: Character] = [
        "爱": "愛", "罢": "罷", "备": "備", "边": "邊", "标": "標",
        // ... (HK variant mappings differ from TW in ~300 characters) ...
    ]

    /// Traditional → Simplified. ~7,000 character mappings (inverse of s2tw).
    static let traditionalToSimplified: [Character: Character] = [
        "愛": "爱", "罷": "罢", "備": "备", "邊": "边", "標": "标",
        // ...
    ]

    static func table(for mode: ChineseConversionMode) -> [Character: Character] {
        switch mode {
        case .none:                      return [:]
        case .simplifiedToTraditionalTW: return simplifiedToTW
        case .simplifiedToTraditionalHK: return simplifiedToHK
        case .traditionalToSimplified:   return traditionalToSimplified
        }
    }
}
```

A Python script `scripts/generate-chinese-tables.py` downloads or reads the OpenCC source data files and emits the Swift literal. Run it once during development; commit the generated file. The generated file is ~500KB of Swift source, compiling to ~200KB of binary data (dictionary hash tables).

### Step 4: Wire into TranscriptionPipeline

Add the conversion step immediately after `asrManager.transcribe()` returns, before `Transcript` creation:

```swift
// TranscriptionPipeline.swift — add property:
var chineseConversionMode: ChineseConversionMode = .none

// In stopAndTranscribe(), after:
//   let result = try await asrManager.transcribe(audioSamples: samples)
// Add:
let convertedText: String
if ChineseConverter.isChinese(language: result.language),
   chineseConversionMode != .none {
    convertedText = ChineseConverter.convert(result.text, mode: chineseConversionMode)
} else {
    convertedText = result.text
}

// Then use convertedText in Transcript creation:
let transcript = Transcript(
    text: convertedText,          // was: result.text
    polishedText: polishedText,
    language: result.language,
    duration: result.duration,
    processingTime: result.processingTime,
    backendType: result.backendType
)
```

Also apply conversion in `polishExistingTranscript(_:)` if the transcript's language is Chinese and conversion mode is set — the raw `transcript.text` field should be converted before polishing. This ensures the LLM receives Traditional if the user prefers it.

### Step 5: Persist setting in AppState

```swift
// AppState.swift — add property:
var chineseConversionMode: ChineseConversionMode {
    didSet {
        UserDefaults.standard.set(chineseConversionMode.rawValue, forKey: "chineseConversionMode")
        pipeline.chineseConversionMode = chineseConversionMode
    }
}

// In init():
chineseConversionMode = ChineseConversionMode(
    rawValue: defaults.string(forKey: "chineseConversionMode") ?? ""
) ?? .none
pipeline.chineseConversionMode = chineseConversionMode
```

### Step 6: Add UI in SettingsView

The picker is hidden when Parakeet is selected (English-only). It appears only under WhisperKit:

```swift
// In GeneralSettingsView, inside Section("ASR Backend"), after the WhisperKit model picker:
if appState.selectedBackend == .whisperKit {
    Picker("Chinese Conversion", selection: $state.chineseConversionMode) {
        ForEach(ChineseConversionMode.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
        }
    }
    Text("Converts ASR output between Simplified and Traditional Chinese variants. Only active when the spoken language is Chinese.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

### Table generation script (outline)

```python
#!/usr/bin/env python3
# scripts/generate-chinese-tables.py
# Downloads OpenCC character tables and emits ChineseConversionTables.swift

import urllib.request, json, sys

# OpenCC data URLs (MIT License)
STW_URL = "https://raw.githubusercontent.com/BYVoid/OpenCC/master/data/character/STCharacters.txt"
TWV_URL = "https://raw.githubusercontent.com/BYVoid/OpenCC/master/data/character/TWVariants.txt"
HKV_URL = "https://raw.githubusercontent.com/BYVoid/OpenCC/master/data/character/HKVariants.txt"

def load_table(url):
    """Parse OpenCC character table: each line is 'source\ttarget1 target2 ...'"""
    with urllib.request.urlopen(url) as r:
        lines = r.read().decode("utf-8").splitlines()
    table = {}
    for line in lines:
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 2 and len(parts[0]) == 1:
            targets = parts[1].split()
            if targets and len(targets[0]) == 1:
                table[parts[0]] = targets[0]  # Take first variant
    return table

# ... emit Swift literal ...
```

## Testing Strategy

1. **Unit test the converter:** Create test cases with known Simplified→Traditional pairs:
   - "爱情" → "愛情" (s2tw)
   - "软件" passes through unchanged in single-char mode (no mapping for "软" in s2tw? verify)
   - Unmapped characters (ASCII, punctuation, numbers) pass through unchanged
   - Empty string input returns empty string
   - `.none` mode returns input unchanged regardless of language

2. **Language detection test:** `ChineseConverter.isChinese(language:)` returns true for "zh", "zh-CN", "zh-TW", "zh-Hans", "zh-Hant" and false for "en", "ja", "ko", nil.

3. **Pipeline integration test:** Record a short Chinese phrase with WhisperKit, verify the stored `Transcript.text` matches the expected Traditional form when mode is set to `simplifiedToTraditionalTW`.

4. **Parakeet hide test:** Switch to Parakeet backend in Settings. The Chinese Conversion picker must not be visible.

5. **Persistence test:** Set conversion mode to "Simplified → Traditional (TW)", quit and relaunch app, verify the picker still shows that selection.

6. **Performance:** The single-character dictionary lookup should complete in under 1ms for a 500-character transcript. No async work needed.

## Risks & Considerations

- OpenCC is a C++ library — needs a Swift bridge or SPM wrapper — **mitigated by using pure-Swift dictionary lookup; no C++ bridge**
- Conversion tables add to bundle size — **~200KB binary overhead, acceptable**
- Only relevant for Chinese-language users — should be hidden/disabled for others — **mitigated by showing picker only when WhisperKit is selected**
- Niche feature — low priority unless targeting Chinese market
- Single-character lookup misses multi-character phrase conversions (e.g. "軟件"/"软件") — phrase table support is Phase 2
- OpenCC data license is Apache 2.0 / MIT — compatible with the project. Attribution required in NOTICES file.
