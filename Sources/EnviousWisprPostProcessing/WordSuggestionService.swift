import EnviousWisprCore
import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

public final class WordSuggestionService: Sendable {
  public var isAvailable: Bool {
    #if canImport(FoundationModels)
      guard #available(macOS 26, *) else { return false }
      return SystemLanguageModel.default.availability == .available
    #else
      return false
    #endif
  }

  public init() {}

  public func suggest(for word: String) async -> WordSuggestions? {
    #if canImport(FoundationModels)
      guard #available(macOS 26, *),
        case .available = SystemLanguageModel.default.availability
      else { return nil }

      // Hard 5s timeout — FM can hang on some inputs
      do {
        return try await withThrowingTimeout(seconds: 5) {
          await self.runSuggestion(for: word)
        }
      } catch {
        return nil
      }
    #else
      return nil
    #endif
  }

  private static let suggestionInstructions = """
    You predict how speech-to-text engines (Whisper, Parakeet) misrecognize a spoken word.
    Focus on: wrong word boundaries ("par vati"), vowel/consonant swaps ("pavathi"), \
    phonetic spellings ("poor vati"), and homophones ("partee").
    Do NOT suggest honorifics, suffixes, or cultural variants — only ASR errors.
    Examples:
    - "Kubernetes" → category: brand, aliases: ["kuber netties", "cube ernetes", "cooper nettys"]
    - "Miyamoto" → category: person, aliases: ["me ya moto", "mia motto", "me amoto", "miyomoto"]
    - "Parvati" → category: person, aliases: ["par vati", "poor vati", "pavathi", "par vathy"]
    - "Gemini" → category: brand, aliases: ["jeh meh nee", "jamini", "gemenai"]
    Always provide 3-5 realistic ASR misrecognitions.
    If you cannot produce at least 3 distinct misrecognitions different from the input, return an empty list.
    """

  // MARK: - Degeneration filter (Phase 1 #637)

  /// Drops AFM responses that degenerate into echoes of the canonical word.
  /// Filter rules:
  /// - Drop empty entries (after trim).
  /// - Drop entries equal to canonical (case + whitespace insensitive).
  /// - Drop near-duplicates of canonical (`WordCorrector.score >= 0.95`).
  /// - De-dupe (case + whitespace insensitive).
  ///
  /// Returns the surviving aliases. Callers should treat an empty result
  /// from a non-empty input as model degeneration (return nil).
  ///
  /// Threshold 0.95 sits inside bible §17 R1 tunable range (0.85-0.99).
  static func filterDegeneratedAliases(_ raw: [String], canonical: String) -> [String] {
    let canonicalNormalized = canonical.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !canonicalNormalized.isEmpty else { return [] }
    var seen = Set<String>()
    var kept: [String] = []
    let scorer = WordCorrector()
    for alias in raw {
      let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let normalized = trimmed.lowercased()
      if normalized == canonicalNormalized { continue }
      if seen.contains(normalized) { continue }
      if scorer.score(trimmed, against: canonical) >= 0.95 { continue }
      seen.insert(normalized)
      kept.append(trimmed)
    }
    return kept
  }

  // MARK: - Guided generation with @Generable (full Xcode toolchain)

  #if canImport(FoundationModels) && hasAttribute(Generable)
    @Generable
    @available(macOS 26.0, *)
    struct WordSuggestionsResult {
      @Guide(description: "Category: general, person, brand, acronym, or domain")
      var category: String
      @Guide(description: "3 to 5 ways speech recognition might mishear this word")
      var suggestedAliases: [String]
    }

    @available(macOS 26, *)
    private func runSuggestion(for word: String) async -> WordSuggestions? {
      let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: Self.suggestionInstructions
      )

      do {
        let response = try await session.respond(
          to: "Word: \(word)",
          generating: WordSuggestionsResult.self
        )
        let category = WordCategory(rawValue: response.category.lowercased()) ?? .general
        let raw = response.suggestedAliases
        let filtered = Self.filterDegeneratedAliases(raw, canonical: word)
        // Empty after filter (with non-empty raw) means AFM degenerated into self-echoes.
        // Treat as model failure so the UI can render "No suggestions available" instead
        // of zero or duplicate chips.
        guard !filtered.isEmpty else { return nil }
        return WordSuggestions(category: category, suggestedAliases: filtered)
      } catch {
        return nil
      }
    }

  // MARK: - Dynamic schema fallback (CLT-only builds without macro plugin)

  #elseif canImport(FoundationModels)
    @available(macOS 26, *)
    private func runSuggestion(for word: String) async -> WordSuggestions? {
      let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: Self.suggestionInstructions
      )

      do {
        let dynamicSchema = DynamicGenerationSchema(
          name: "WordSuggestion",
          properties: [
            DynamicGenerationSchema.Property(
              name: "category",
              schema: DynamicGenerationSchema(type: String.self)
            ),
            DynamicGenerationSchema.Property(
              name: "suggestedAliases",
              schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
            ),
          ]
        )
        let schema = try GenerationSchema(root: dynamicSchema, dependencies: [])

        let response = try await session.respond(
          to: "Word: \(word)",
          schema: schema
        )
        let categoryStr = try response.content.value(String.self, forProperty: "category")
        let raw = try response.content.value([String].self, forProperty: "suggestedAliases")

        let category = WordCategory(rawValue: categoryStr.lowercased()) ?? .general
        let filtered = Self.filterDegeneratedAliases(raw, canonical: word)
        guard !filtered.isEmpty else { return nil }
        return WordSuggestions(category: category, suggestedAliases: filtered)
      } catch {
        return nil
      }
    }
  #endif
}

public struct WordSuggestions: Sendable {
  public let category: WordCategory
  public let suggestedAliases: [String]
}
