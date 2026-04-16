import EnviousWisprCore

/// Renders custom vocabulary entries into a prompt-safe string block.
/// Single source of truth for vocab formatting. Extracted from LLMPolishStep.renderCustomWordsForPrompt().
///
/// Accepts either the legacy rich `[CustomWord]` list (with aliases + priority)
/// or the Multilingual v1 `PromptVocabulary` shape (flat `[String]` per bucket).
/// The `[CustomWord]` path preserves alias hints for builders that render them
/// (OpenAI/Gemini). The `PromptVocabulary` path is for new callsites that want
/// the confidence-tiered, language-aware filter applied before rendering.
public struct CustomVocabularyFormatter: Sendable {
  private static let maxWords = 50
  private static let maxChars = 2000

  private static let fullHeader =
    "CUSTOM VOCABULARY: The following are the user's preferred spellings. "
    + "When the transcript contains similar-sounding words, use these exact spellings:"

  /// Render custom words in full format (for OpenAI and Gemini builders).
  /// Returns nil if the word list is empty.
  public static func render(_ words: [CustomWord]) -> String? {
    guard !words.isEmpty else { return nil }
    let sorted = words.sorted { ($0.priority, $0.canonical) < ($1.priority, $1.canonical) }
    let capped = Array(sorted.prefix(maxWords))
    var lines: [String] = []
    var charCount = fullHeader.count
    for word in capped {
      let clean = sanitize(word.canonical)
      let line: String
      if word.aliases.isEmpty {
        line = "- \(clean)"
      } else {
        let cleanAliases = word.aliases.map { sanitize($0) }.joined(separator: ", ")
        line = "- \(clean) (may be misheard as: \(cleanAliases))"
      }
      if charCount + line.count > maxChars { break }
      lines.append(line)
      charCount += line.count
    }
    return fullHeader + "\n" + lines.joined(separator: "\n")
  }

  /// Render custom words in simplified format (for Gemma builder).
  /// Just a comma-separated list of canonical spellings.
  /// Returns nil if the word list is empty.
  public static func renderSimplified(_ words: [CustomWord]) -> String? {
    guard !words.isEmpty else { return nil }
    let sorted = words.sorted { ($0.priority, $0.canonical) < ($1.priority, $1.canonical) }
    let capped = Array(sorted.prefix(maxWords))
    let names = capped.map { sanitize($0.canonical) }.joined(separator: ", ")
    return "Preferred spellings: \(names)"
  }

  // MARK: - Multilingual v1 (W3): PromptVocabulary entry points

  /// Render a `PromptVocabulary` to a full-format prompt block, applying the
  /// confidence-tiered + script-guardrail policy for the detected language.
  /// Returns nil if no terms survive the filter (caller should emit a
  /// formatting-only prompt in that case).
  public static func render(
    vocabulary: PromptVocabulary,
    detectedLang: String?,
    tier: LanguageConfidenceTier
  ) -> String? {
    let terms = vocabulary.effectiveTerms(detectedLang: detectedLang, tier: tier)
    return renderStrings(terms)
  }

  /// Render a `PromptVocabulary` to a simplified comma-separated block (for
  /// Gemma). Applies the same tier + script-guardrail policy.
  public static func renderSimplified(
    vocabulary: PromptVocabulary,
    detectedLang: String?,
    tier: LanguageConfidenceTier
  ) -> String? {
    let terms = vocabulary.effectiveTerms(detectedLang: detectedLang, tier: tier)
    return renderStringsSimplified(terms)
  }

  /// Render a raw flat `[String]` list in full format. Used when a callsite
  /// already has a pre-filtered list of terms.
  public static func renderStrings(_ terms: [String]) -> String? {
    guard !terms.isEmpty else { return nil }
    let capped = Array(terms.prefix(maxWords))
    var lines: [String] = []
    var charCount = fullHeader.count
    for term in capped {
      let clean = sanitize(term)
      let line = "- \(clean)"
      if charCount + line.count > maxChars { break }
      lines.append(line)
      charCount += line.count
    }
    guard !lines.isEmpty else { return nil }
    return fullHeader + "\n" + lines.joined(separator: "\n")
  }

  /// Render a raw flat `[String]` list in simplified (comma-separated) form.
  public static func renderStringsSimplified(_ terms: [String]) -> String? {
    guard !terms.isEmpty else { return nil }
    let capped = Array(terms.prefix(maxWords))
    let names = capped.map { sanitize($0) }.joined(separator: ", ")
    return "Preferred spellings: \(names)"
  }

  /// Strip injection-risky characters from custom word text.
  static func sanitize(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "`", with: "'")
      .replacingOccurrences(of: "<", with: "")
      .replacingOccurrences(of: ">", with: "")
      .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
  }
}
