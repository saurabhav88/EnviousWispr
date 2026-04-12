import Foundation

/// Storage shape for confidence-tiered, language-aware prompt injection
/// (see Multilingual v1 spec § Prompt injection rearchitecture).
///
/// `global` entries are always safe to inject regardless of detected language
/// (product names, URLs, truly cross-lingual tokens). `perLanguage[code]`
/// entries are only injected when the detected language matches the key AND
/// the confidence tier is `.locked` or `.highAuto`.
///
/// At v1 this is populated via the migration helper
/// (`fromLegacy(_:)`) which drops all existing `CustomWord` entries into
/// `global`. This is the safe default since most are product names and proper nouns.
/// A per-entry language tag in the UI is a v2 enhancement.
public struct PromptVocabulary: Sendable, Equatable, Codable {
    /// Cross-lingual entries: always safe to inject.
    public var global: [String]
    /// ISO 639-1 code -> terms specific to that language.
    public var perLanguage: [String: [String]]

    public init(global: [String] = [], perLanguage: [String: [String]] = [:]) {
        self.global = global
        self.perLanguage = perLanguage
    }

    /// True when both buckets are empty. Planner skips vocab injection entirely
    /// in this case (formatting-only prompt).
    public var isEmpty: Bool {
        global.isEmpty && perLanguage.values.allSatisfy(\.isEmpty)
    }

    /// Migration: convert the legacy flat `[CustomWord]` list into a
    /// `PromptVocabulary` with every canonical form tagged as `global`. This is
    /// the safe default on first launch after the Multilingual v1 upgrade.
    /// Aliases are NOT copied into the vocabulary (only canonical spellings);
    /// CustomWord alias metadata is still preserved on the legacy `customWords`
    /// field for rollback safety.
    public static func fromLegacy(_ words: [CustomWord]) -> PromptVocabulary {
        PromptVocabulary(global: words.map(\.canonical), perLanguage: [:])
    }

    /// Filtered view of the vocabulary for a specific confidence tier + detected
    /// language, applying the script guardrail (see spec § Layer 4).
    ///
    /// Returns the list of terms the prompt layer should inject. An empty list
    /// means no lexical injection for this call (formatting-only).
    ///
    /// Policy:
    /// - `.locked` or `.highAuto`: global + perLanguage[detected]
    /// - `.mediumAuto`: global only (NO perLanguage lexicon)
    /// - `.lowAuto` or `.abstain`: empty (no lexical prompt)
    ///
    /// Script guardrail: if `detectedLang` is non-Latin script, perLanguage
    /// entries whose characters are entirely Latin ASCII are dropped. `global`
    /// entries survive regardless (they are tagged cross-lingual).
    ///
    /// Defensive: perLanguage keys that are not Whisper-supported are skipped.
    public func effectiveTerms(
        detectedLang: String?,
        tier: LanguageConfidenceTier
    ) -> [String] {
        switch tier {
        case .lowAuto, .abstain:
            return []
        case .mediumAuto:
            return global
        case .locked, .highAuto:
            var out = global
            if let lang = detectedLang?.lowercased(),
               LanguageTypes.isSupported(lang),
               let perLang = perLanguage[lang] {
                let filtered: [String]
                if LanguageTypes.isNonLatinScript(lang) {
                    filtered = perLang.filter { !Self.isAllLatinScript($0) }
                } else {
                    filtered = perLang
                }
                out.append(contentsOf: filtered)
            }
            return out
        }
    }

    /// True when every letter in the term lies in the ASCII range (A-Z, a-z).
    /// Used by the script guardrail to strip Latin-script-only terms from the
    /// perLanguage bucket when the detected language is non-Latin-script.
    ///
    /// Checks each letter scalar against the Latin Unicode blocks (Basic Latin,
    /// Latin-1 Supplement, Latin Extended-A/B, IPA Extensions, combining
    /// diacritics, and Latin Extended Additional). This correctly recognizes
    /// German ß, French é, Spanish ñ, Turkish ı, Vietnamese ế etc. as Latin.
    /// Non-letter characters (digits, punctuation, whitespace) are ignored so
    /// alphanumeric Latin terms like "claude3" still qualify. A term with zero
    /// letters (pure punctuation or digits) does not qualify as "a Latin term"
    /// and therefore passes the guardrail (safe default).
    static func isAllLatinScript(_ term: String) -> Bool {
        var hasLetter = false
        for scalar in term.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else { continue }
            hasLetter = true
            if !Self.isLatinScriptScalar(scalar) {
                return false
            }
        }
        return hasLetter
    }

    /// True if the scalar is in one of the Latin Unicode blocks used for
    /// natural language text. See:
    /// https://en.wikipedia.org/wiki/Latin_script_in_Unicode
    private static func isLatinScriptScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        switch v {
        case 0x0041...0x005A,        // Basic Latin: A-Z
             0x0061...0x007A,        // Basic Latin: a-z
             0x00C0...0x00D6,        // Latin-1 Supplement: À-Ö (skips × at 0xD7)
             0x00D8...0x00F6,        // Latin-1 Supplement: Ø-ö (skips ÷ at 0xF7)
             0x00F8...0x00FF,        // Latin-1 Supplement: ø-ÿ
             0x0100...0x017F,        // Latin Extended-A
             0x0180...0x024F,        // Latin Extended-B
             0x0250...0x02AF,        // IPA Extensions
             0x1E00...0x1EFF,        // Latin Extended Additional (Vietnamese etc.)
             0x0300...0x036F:        // Combining Diacritical Marks
            return true
        default:
            return false
        }
    }
}
