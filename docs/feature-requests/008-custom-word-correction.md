# Feature: Custom Word Correction

**ID:** 008
**Category:** AI & Post-Processing
**Priority:** Medium
**Inspired by:** Handy — Levenshtein + Soundex phonetic matching + n-gram comparison
**Status:** Ready for Implementation

## Problem

ASR engines sometimes misrecognize proper nouns, technical jargon, product names, or uncommon words. There is no way for users to teach the system their vocabulary (e.g., "EnviousWispr" might be transcribed as "envious whisper").

## Proposed Solution

Add a user-maintained custom word list. After transcription, run a post-processing pass that compares each word against the custom list using:

1. Levenshtein edit distance (40% weight)
2. Bigram Dice coefficient for n-gram similarity (40% weight)
3. Soundex phonetic matching (20% weight)

Replace words that score above a threshold of 0.82. The corrector runs between ASR output and LLM polish so the LLM sees already-corrected vocabulary.

## Architecture Decisions

- Pure `struct WordCorrector: Sendable` — no actors, no side effects, safe to call from any context
- New directory `Sources/EnviousWispr/PostProcessing/` to house all post-ASR, pre-LLM processing
- `CustomWordStore` handles persistence to `~/Library/Application Support/EnviousWispr/custom-words.json`
- New "Word Fix" settings tab added to `SettingsView`
- Pipeline integration: correction runs inside `TranscriptionPipeline.stopAndTranscribe()` after ASR, before LLM

## Files to Modify

### Existing Files

| File | Change |
| ---- | ------ |
| `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` | Add `wordCorrector` property; call `WordCorrector.correct()` after ASR result, before LLM polish |
| `Sources/EnviousWispr/App/AppState.swift` | Add `customWordStore: CustomWordStore`; add `wordCorrectionEnabled: Bool` persisted setting; wire to pipeline |
| `Sources/EnviousWispr/Views/Settings/SettingsView.swift` | Add `WordFixSettingsView` tab to the `TabView` in `SettingsView`; increase frame height if needed |

### New Files

| File | Purpose |
| ---- | ------- |
| `Sources/EnviousWispr/PostProcessing/WordCorrector.swift` | Core correction algorithm — `struct WordCorrector: Sendable` |
| `Sources/EnviousWispr/PostProcessing/CustomWordStore.swift` | Persistence layer — load/save custom word list to JSON |
| `Sources/EnviousWispr/Views/Settings/WordFixSettingsView.swift` | SwiftUI settings tab for managing the custom word list |

## New Types and Properties

### `WordCorrector` (new file)

```swift
/// Pure, Sendable word correction engine.
struct WordCorrector: Sendable {
    /// Minimum composite score to trigger a replacement (0.0–1.0).
    static let threshold: Double = 0.82

    /// Weights for each scoring component.
    private static let levenshteinWeight = 0.40
    private static let bigramWeight      = 0.40
    private static let soundexWeight     = 0.20

    /// Correct all words in `text` against the provided custom word list.
    /// Returns the corrected string and a count of replacements made.
    func correct(_ text: String, against wordList: [String]) -> (corrected: String, replacements: Int)

    // MARK: - Scoring

    /// Composite similarity score between two strings (0.0 = no match, 1.0 = identical).
    func score(_ candidate: String, against target: String) -> Double

    /// Levenshtein edit distance similarity (1 - normalizedDistance).
    private func levenshteinSimilarity(_ a: String, _ b: String) -> Double

    /// Bigram Dice coefficient.
    private func bigramDice(_ a: String, _ b: String) -> Double

    /// Soundex code equality (1.0 match, 0.0 no match).
    private func soundexScore(_ a: String, _ b: String) -> Double

    /// Compute Soundex code for a string.
    private func soundex(_ s: String) -> String
}
```

### `CustomWordStore` (new file)

```swift
/// Persists the user's custom word list to disk.
final class CustomWordStore: Sendable {
    private let fileURL: URL

    init()

    /// Load words from disk. Returns empty array if file doesn't exist.
    func load() throws -> [String]

    /// Persist words to disk (atomic write).
    func save(_ words: [String]) throws

    /// Add a single word if not already present.
    func add(_ word: String) throws

    /// Remove a word by value.
    func remove(_ word: String) throws
}
```

Storage path: `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("EnviousWispr/custom-words.json")`

### AppState additions

```swift
// In AppState:
let customWordStore = CustomWordStore()
var customWords: [String] = []          // in-memory list, loaded on init

var wordCorrectionEnabled: Bool {
    didSet {
        UserDefaults.standard.set(wordCorrectionEnabled, forKey: "wordCorrectionEnabled")
        pipeline.wordCorrectionEnabled = wordCorrectionEnabled
    }
}
```

### TranscriptionPipeline additions

```swift
// In TranscriptionPipeline:
var wordCorrectionEnabled: Bool = false
var customWords: [String] = []          // kept in sync by AppState
```

### LLMProvider / LLMResult — no changes needed

## Implementation Plan

### Step 1 — Create `Sources/EnviousWispr/PostProcessing/` directory and `WordCorrector.swift`

```swift
// Sources/EnviousWispr/PostProcessing/WordCorrector.swift
import Foundation

struct WordCorrector: Sendable {
    static let threshold: Double = 0.82

    private static let levenshteinWeight = 0.40
    private static let bigramWeight      = 0.40
    private static let soundexWeight     = 0.20

    func correct(_ text: String, against wordList: [String]) -> (corrected: String, replacements: Int) {
        guard !wordList.isEmpty else { return (text, 0) }

        // Tokenize while preserving whitespace boundaries
        var replacements = 0
        let words = text.components(separatedBy: .whitespaces)
        let corrected = words.map { token -> String in
            // Strip leading/trailing punctuation for matching, then re-attach
            let (prefix, core, suffix) = splitPunctuation(token)
            guard !core.isEmpty, core.count >= 3 else { return token }

            var bestScore = 0.0
            var bestMatch = ""
            for target in wordList {
                let s = score(core.lowercased(), against: target.lowercased())
                if s > bestScore {
                    bestScore = s
                    bestMatch = target
                }
            }

            // Only replace if score exceeds threshold AND the casing differs
            // (avoid replacing exact matches with differently-cased versions pointlessly)
            if bestScore >= Self.threshold, core.lowercased() != bestMatch.lowercased() {
                replacements += 1
                return prefix + bestMatch + suffix
            }
            return token
        }
        return (corrected.joined(separator: " "), replacements)
    }

    func score(_ candidate: String, against target: String) -> Double {
        let lev    = levenshteinSimilarity(candidate, target) * Self.levenshteinWeight
        let bigram = bigramDice(candidate, target)            * Self.bigramWeight
        let sdx    = soundexScore(candidate, target)          * Self.soundexWeight
        return lev + bigram + sdx
    }

    // MARK: - Levenshtein

    private func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        let m = a.count, n = b.count
        if m == 0 { return n == 0 ? 1.0 : 0.0 }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                dp[i][j] = a[i-1] == b[j-1]
                    ? dp[i-1][j-1]
                    : 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
            }
        }
        let dist = dp[m][n]
        return 1.0 - Double(dist) / Double(max(m, n))
    }

    // MARK: - Bigram Dice

    private func bigramDice(_ a: String, _ b: String) -> Double {
        func bigrams(_ s: String) -> Set<String> {
            guard s.count >= 2 else { return [] }
            let chars = Array(s)
            return Set((0..<chars.count - 1).map { String([chars[$0], chars[$0+1]]) })
        }
        let ba = bigrams(a), bb = bigrams(b)
        guard !ba.isEmpty || !bb.isEmpty else { return a == b ? 1.0 : 0.0 }
        let intersection = ba.intersection(bb).count
        return 2.0 * Double(intersection) / Double(ba.count + bb.count)
    }

    // MARK: - Soundex

    private func soundexScore(_ a: String, _ b: String) -> Double {
        soundex(a) == soundex(b) ? 1.0 : 0.0
    }

    private func soundex(_ s: String) -> String {
        let map: [Character: Character] = [
            "b":"1","f":"1","p":"1","v":"1",
            "c":"2","g":"2","j":"2","k":"2","q":"2","s":"2","x":"2","z":"2",
            "d":"3","t":"3","e":"0","i":"0","o":"0","u":"0","y":"0","h":"0","w":"0",
            "l":"4","m":"5","n":"5","r":"6",
        ]
        let upper = s.uppercased()
        guard let first = upper.first else { return "0000" }
        var code = String(first)
        var last = map[Character(String(first).lowercased())] ?? "0"
        for ch in upper.dropFirst() {
            let lch = Character(String(ch).lowercased())
            guard let digit = map[lch] else { continue }
            if digit != "0" && digit != last {
                code.append(digit)
                if code.count == 4 { break }
            }
            last = digit
        }
        while code.count < 4 { code.append("0") }
        return String(code.prefix(4))
    }

    // MARK: - Helpers

    private func splitPunctuation(_ token: String) -> (prefix: String, core: String, suffix: String) {
        var prefix = "", core = token, suffix = ""
        while let first = core.first, !first.isLetter && !first.isNumber {
            prefix.append(first); core = String(core.dropFirst())
        }
        while let last = core.last, !last.isLetter && !last.isNumber {
            suffix = String(last) + suffix; core = String(core.dropLast())
        }
        return (prefix, core, suffix)
    }
}
```

### Step 2 — Create `CustomWordStore.swift`

```swift
// Sources/EnviousWispr/PostProcessing/CustomWordStore.swift
import Foundation

final class CustomWordStore: Sendable {
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("EnviousWispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        fileURL = appSupport.appendingPathComponent("custom-words.json")
    }

    func load() throws -> [String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String].self, from: data)
    }

    func save(_ words: [String]) throws {
        let data = try JSONEncoder().encode(words.sorted())
        try data.write(to: fileURL, options: .atomic)
    }

    func add(_ word: String, to words: inout [String]) throws {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !words.contains(trimmed) else { return }
        words.append(trimmed)
        try save(words)
    }

    func remove(_ word: String, from words: inout [String]) throws {
        words.removeAll { $0 == word }
        try save(words)
    }
}
```

### Step 3 — Wire into `TranscriptionPipeline`

In `TranscriptionPipeline.swift`, add properties and integrate the corrector call:

```swift
// New properties on TranscriptionPipeline:
var wordCorrectionEnabled: Bool = false
var customWords: [String] = []

// In stopAndTranscribe(), after ASR result and before LLM polish:
let asrText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

// Word correction pass
let correctedText: String
if wordCorrectionEnabled && !customWords.isEmpty {
    let corrector = WordCorrector()
    let (fixed, count) = corrector.correct(asrText, against: customWords)
    if count > 0 {
        print("[WordCorrector] Applied \(count) correction(s)")
    }
    correctedText = fixed
} else {
    correctedText = asrText
}

// (then LLM polish uses correctedText instead of result.text)
var polishedText: String?
if llmProvider != .none {
    state = .polishing
    do {
        polishedText = try await polishTranscript(correctedText)
    } catch {
        print("LLM polish failed: \(error.localizedDescription)")
    }
}

let transcript = Transcript(
    text: correctedText,   // store corrected ASR text as the "raw" text
    polishedText: polishedText,
    ...
)
```

Also update `polishExistingTranscript` to accept a pre-corrected text path (it already takes `transcript.text`, which by this point is already corrected).

### Step 4 — Extend `AppState`

```swift
// In AppState:
let customWordStore = CustomWordStore()
var customWords: [String] = []

var wordCorrectionEnabled: Bool {
    didSet {
        UserDefaults.standard.set(wordCorrectionEnabled, forKey: "wordCorrectionEnabled")
        pipeline.wordCorrectionEnabled = wordCorrectionEnabled
    }
}

// In init(), after loading other defaults:
wordCorrectionEnabled = defaults.object(forKey: "wordCorrectionEnabled") as? Bool ?? true
customWords = (try? customWordStore.load()) ?? []
pipeline.wordCorrectionEnabled = wordCorrectionEnabled
pipeline.customWords = customWords

// Helper called from WordFixSettingsView:
func addCustomWord(_ word: String) {
    try? customWordStore.add(word, to: &customWords)
    pipeline.customWords = customWords
}

func removeCustomWord(_ word: String) {
    try? customWordStore.remove(word, from: &customWords)
    pipeline.customWords = customWords
}
```

### Step 5 — Create `WordFixSettingsView.swift`

```swift
// Sources/EnviousWispr/Views/Settings/WordFixSettingsView.swift
import SwiftUI

struct WordFixSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var newWord: String = ""
    @State private var errorMessage: String = ""

    var body: some View {
        @Bindable var state = appState

        Form {
            Section {
                Toggle("Enable word correction", isOn: $state.wordCorrectionEnabled)
                Text("After transcription, each word is scored against your custom list using edit distance, n-gram similarity, and phonetic matching. Words scoring above 0.82 are replaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Word Correction")
            }

            Section {
                HStack {
                    TextField("Add word (e.g. EnviousWispr)", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addWord() }

                    Button("Add") { addWord() }
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if appState.customWords.isEmpty {
                    Text("No custom words yet. Add proper nouns, product names, or technical terms the ASR frequently misrecognizes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(appState.customWords.sorted(), id: \.self) { word in
                            HStack {
                                Text(word)
                                Spacer()
                                Button {
                                    appState.removeCustomWord(word)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .frame(minHeight: 80, maxHeight: 200)
                }
            } header: {
                Text("Custom Word List (\(appState.customWords.count) words)")
            }

            Section {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Matching is case-insensitive during scoring but the replacement preserves the casing of the word in your list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count >= 2 else {
            errorMessage = "Word must be at least 2 characters."
            return
        }
        errorMessage = ""
        appState.addCustomWord(trimmed)
        newWord = ""
    }
}
```

### Step 6 — Register the new tab in `SettingsView`

```swift
// In SettingsView.body TabView, add after the existing AI Polish tab:
WordFixSettingsView()
    .tabItem {
        Label("Word Fix", systemImage: "text.word.spacing")
    }
```

Also increase the frame height slightly to accommodate the taller content:

```swift
.frame(width: 520, height: 520)  // was 480
```

## Testing Strategy

### Unit Tests (manual Swift script, no XCTest)

Create a standalone `swift` script at `scripts/test-word-corrector.swift` that exercises:

1. **Exact-match bypass**: `"EnviousWispr"` in list, input `"EnviousWispr"` → no replacement (already correct)
2. **Levenshtein substitution**: list `["EnviousWispr"]`, input `"envious whisper"` → corrected
3. **Soundex phonetic match**: list `["Knuth"]`, input `"Nuth"` → corrected
4. **Threshold enforcement**: list `["Anthropic"]`, input `"entropy"` → NOT corrected (score below 0.82)
5. **Punctuation preservation**: `"EnviousWispr,"` → `"EnviousWispr,"` (trailing comma retained)
6. **Short word exclusion**: `"of"`, `"is"` → never matched (length < 3)
7. **Multiple replacements**: two words in one sentence both corrected
8. **Empty word list**: no-op, returns original text

Run: `swift scripts/test-word-corrector.swift`

### Integration Test (smoke test)

Add to the existing `run-smoke-test` skill steps:

- Enable word correction in settings
- Add `"EnviousWispr"` to the custom word list
- Dictate "envious whisper is the best"
- Verify transcript shows "EnviousWispr is the best"

### UI Verification

- Open Settings → Word Fix tab
- Add a word, verify it appears in list
- Remove a word, verify list updates
- Toggle "Enable word correction" off, verify pipeline skips correction

## Risks and Considerations

- **False positives**: threshold 0.82 is conservative. Expose it as an advanced setting in a future iteration if users report false replacements.
- **Performance**: O(n * m) where n = word count in transcript, m = custom list size. For a 500-word transcript and 100 custom words, ~50 000 comparisons — well under 10ms on Apple Silicon.
- **Short words**: words under 3 characters are skipped to avoid spurious phonetic matches (e.g., "of" matching "or").
- **LLM interaction**: correction runs before LLM, so the LLM sees corrected text. This is intentional — LLM can further clean up without fighting ASR artifacts.
- **Case sensitivity**: scoring is lowercased; replacement uses the list's original casing to preserve proper noun capitalization.
