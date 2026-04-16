import EnviousWisprCore
import Foundation

/// Extracts the core logic of LLMPolishStep.enrichedInstructions() into a pure,
/// testable function in the LLM module. Used for characterization tests that freeze
/// the current prompt behavior before PR 2 replaces it with the new PromptPlanner.
///
/// This is NOT the new system. It exists solely to enable characterization testing.
public struct LegacyPromptEnricher: Sendable {
  /// Enrichment version. Matches LLMPolishStep.enrichmentVersion = 2.
  public static let enrichmentVersion = 2

  /// Minimum word count that gets polish enrichment (matches LLMPolishStep.minWordsForPolish threshold
  /// for the short-text guard, NOT the ultra-short skip in process()).
  /// The ultra-short skip (<=3 words) happens in process() before enrichment is called.
  /// The short-text guard (<=10 words) is prompt reinforcement for the gray zone.
  private static let shortTextGuardThreshold = 10

  /// Reproduce the exact logic of LLMPolishStep.enrichedInstructions().
  ///
  /// - Parameters:
  ///   - baseSystemPrompt: The base system prompt from SettingsManager.activePolishInstructions
  ///   - language: Language code from ASR (e.g., "es", "fr"). Nil or empty for English.
  ///   - transcript: The raw transcript text (used for word count).
  ///   - targetAppName: The app name where the user is dictating (e.g., "Slack").
  ///   - customWords: The user's custom vocabulary entries.
  /// - Returns: The enriched system prompt string.
  public static func enrich(
    baseSystemPrompt: String,
    language: String?,
    transcript: String,
    targetAppName: String?,
    customWords: [CustomWord]
  ) -> String {
    var systemPrompt = baseSystemPrompt

    // Language context for non-English transcripts
    if let language = language,
      !language.isEmpty,
      !language.lowercased().hasPrefix("en")
    {
      let languageName = Locale.current.localizedString(forLanguageCode: language) ?? language
      systemPrompt = """
        LANGUAGE: This transcript is in \(languageName) (\(language)). \
        Polish it in \(languageName) — do NOT translate to English. \
        Apply the same rules below but in the transcript's language.

        \(systemPrompt)
        """
    }

    // ASR-awareness clause + app context (enrichmentVersion >= 2)
    if enrichmentVersion >= 2 {
      systemPrompt += """

        This text was produced by speech recognition and may contain \
        phonetically similar but contextually incorrect words. When a \
        similar-sounding alternative clearly better matches the intended \
        meaning, replace only that mistaken word or phrase. Keep edits \
        minimal. Preserve tone, style, and intent. If unsure, leave it \
        unchanged. Examples: "their" misheard as "there", "cache" as \
        "cash", "new" as "nude".
        """

      if let appName = targetAppName, !appName.isEmpty {
        systemPrompt += "\nThe user is dictating in \(appName)."
      }
    }

    // Short-text guard (4-10 word gray zone)
    let wordCount = transcript.split(whereSeparator: \.isWhitespace).count
    if wordCount <= shortTextGuardThreshold {
      systemPrompt += """

        IMPORTANT: If the transcript is very short (just a few words or a single sentence), \
        return it as-is with only minimal punctuation/capitalization fixes. \
        Do NOT expand, elaborate, or generate new content. Short inputs are intentional.
        """
    }

    // Custom vocabulary
    if !customWords.isEmpty {
      let vocabBlock = LegacyCustomVocabularyFormatter.render(customWords)
      systemPrompt += "\n\n" + vocabBlock
    }

    return systemPrompt
  }
}

/// Reproduces the exact rendering logic of LLMPolishStep.renderCustomWordsForPrompt()
/// for characterization test parity. Uses the same header, format, and sanitization.
enum LegacyCustomVocabularyFormatter {
  private static let maxWords = 50
  private static let maxChars = 2000
  private static let header =
    "CUSTOM VOCABULARY: The following are the user's preferred spellings. "
    + "When the transcript contains similar-sounding words, use these exact spellings:"

  static func render(_ words: [CustomWord]) -> String {
    let sorted = words.sorted { ($0.priority, $0.canonical) < ($1.priority, $1.canonical) }
    let capped = Array(sorted.prefix(maxWords))
    var lines: [String] = []
    var charCount = header.count
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
    return header + "\n" + lines.joined(separator: "\n")
  }

  private static func sanitize(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "`", with: "'")
      .replacingOccurrences(of: "<", with: "")
      .replacingOccurrences(of: ">", with: "")
      .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
  }
}
