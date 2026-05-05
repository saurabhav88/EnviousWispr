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

  /// Benchmark-only entry point for the alias-eval harness (#637).
  ///
  /// Returns BOTH raw (pre-filter) and filtered aliases plus timing/error
  /// metadata so the eval scorer can grade the degeneration axis. When
  /// `disableTimeout=true`, the 5-second wrapper is omitted so the harness
  /// can measure true latency without censoring slow responses.
  ///
  /// NEVER call from production code. Production reads `suggest(for:)`,
  /// which is byte-identical in behavior to the pre-#637 ship.
  public func benchmarkSuggest(
    for word: String,
    disableTimeout: Bool = false
  ) async -> WordSuggestionBenchmarkRecord {
    let startTime = Date()
    #if canImport(FoundationModels)
      guard #available(macOS 26, *),
        case .available = SystemLanguageModel.default.availability
      else {
        return WordSuggestionBenchmarkRecord(
          category: .general,
          rawAliases: [],
          filteredAliases: [],
          timedOut: false,
          errorDescription: "framework_unavailable",
          latencyMs: Self.elapsedMs(since: startTime)
        )
      }
      let raw: (category: WordCategory, aliases: [String])?
      var timedOut = false
      var errorDescription: String?
      if disableTimeout {
        do {
          raw = try await self.runRawSuggestion(for: word)
        } catch {
          raw = nil
          errorDescription = "\(error)"
        }
      } else {
        do {
          raw = try await withThrowingTimeout(seconds: 5) {
            try await self.runRawSuggestion(for: word)
          }
        } catch is TimeoutError {
          raw = nil
          timedOut = true
        } catch {
          raw = nil
          errorDescription = "\(error)"
        }
      }
      guard let resolved = raw else {
        return WordSuggestionBenchmarkRecord(
          category: .general,
          rawAliases: [],
          filteredAliases: [],
          timedOut: timedOut,
          errorDescription: errorDescription,
          latencyMs: Self.elapsedMs(since: startTime)
        )
      }
      let filtered = Self.filterDegeneratedAliases(resolved.aliases, canonical: word)
      return WordSuggestionBenchmarkRecord(
        category: resolved.category,
        rawAliases: resolved.aliases,
        filteredAliases: filtered,
        timedOut: false,
        errorDescription: nil,
        latencyMs: Self.elapsedMs(since: startTime)
      )
    #else
      return WordSuggestionBenchmarkRecord(
        category: .general,
        rawAliases: [],
        filteredAliases: [],
        timedOut: false,
        errorDescription: "framework_unavailable",
        latencyMs: Self.elapsedMs(since: startTime)
      )
    #endif
  }

  private static func elapsedMs(since start: Date) -> Int {
    Int((Date().timeIntervalSince(start) * 1000.0).rounded())
  }

  // Step 1 — classification only.
  private static let classificationInstructions = """
    Classify the input word into ONE of these categories. Return only the \
    category name. Pick the FIRST rule that matches.

    1. acronym  -- the input is ALL CAPITAL LETTERS only, no lowercase, no \
    digits, no punctuation. Examples: OKR, PR, KPI, RSI, AWS, NATO, HIPAA, CRM.
    2. domain   -- the input mixes lowercase and uppercase letters OR contains \
    a digit, dot, or other symbol. Examples: gRPC, GraphQL, OAuth2, WebSocket, \
    WebRTC, S3, github.com.
    3. person   -- the input is a human name (capitalized first letter, \
    otherwise lowercase). Examples: Parvati, Saurabh, Miyamoto, Aiyana.
    4. brand    -- the input is a product, company, or framework name. \
    Examples: Kubernetes, Postgres, Tailwind, Linear, DigitalOcean, Slack.
    5. general  -- everything else (regular vocabulary). Examples: webhook, \
    async, middleware.

    Output exactly one of: acronym, domain, person, brand, general.
    """

  // Step 2 — generation, given a known category.
  private static func aliasInstructions(for category: WordCategory) -> String {
    switch category {
    case .acronym:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write an \
        ACRONYM wrong. The acronym is spelled letter-by-letter aloud. Each \
        letter is heard as a syllable.

        Output 3-5 phonetic mistranscriptions. Each output must be \
        SUBSTANTIVELY different from the input -- never echo the input, never \
        just lowercase it. Examples of the pattern (do not copy these tokens):
        - OKR -> ["okay are", "oh K R", "okayer"]
        - PR -> ["pee are", "peer"]
        - RSI -> ["are S I", "arr S I"]
        - HIPAA -> ["hippa", "hip ah", "hipper"]

        Vary your outputs; never return the same string twice. If you cannot \
        produce 3 substantively different mistranscriptions, return [].
        """
    case .domain:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write a \
        TECHNICAL TERM wrong. The term mixes letters and words; ASR splits it \
        into chunks or letter-syllables.

        Output 3-5 phonetic mistranscriptions. Each output must be \
        SUBSTANTIVELY different from the canonical -- NOT just a space \
        inserted, NOT just casing changed. Examples of the pattern (do not \
        copy these tokens):
        - gRPC -> ["gee R P C", "jee R P C"]
        - GraphQL -> ["graph Q L", "graf Q L"]
        - OAuth2 -> ["oh auth two", "O auth 2"]
        - WebSocket -> ["wep sock it", "wep socket"]

        Never output the canonical term with only added or removed spaces. \
        If you cannot produce 3 substantively different mistranscriptions, \
        return [].
        """
    case .person:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write a \
        PERSON'S NAME wrong. ASR mishears via vowel and consonant swaps and \
        word-boundary errors.

        Output 3-5 phonetic mistranscriptions. Never output honorifics, \
        relatives, last names, or alternate identities. Examples of the \
        pattern (do not copy these tokens):
        - Parvati -> ["par vati", "poor vati", "pavathi"]
        - Saurabh -> ["Sourabh", "Sorab", "Sarab"]
        - Miyamoto -> ["me ya moto", "mia motto", "miyomoto"]

        If you cannot produce 3 substantively different mistranscriptions, \
        return [].
        """
    case .brand:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write a \
        BRAND NAME wrong. ASR splits the brand into phonetic chunks of how \
        it is pronounced.

        Output 3-5 phonetic mistranscriptions. Each must be SUBSTANTIVELY \
        different from the canonical -- NOT a suffix-strip, NOT just a space. \
        Examples of the pattern (do not copy these tokens):
        - Kubernetes -> ["kuber netties", "cube ernetes"]
        - Postgres -> ["post grass", "post gress"]
        - Tailwind -> ["tail wind", "tail ind"]

        If you cannot produce 3 substantively different mistranscriptions, \
        return [].
        """
    case .general:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write a \
        REGULAR WORD wrong. ASR splits at word boundaries or swaps vowels \
        and consonants.

        Output 3-5 phonetic mistranscriptions. Examples of the pattern (do \
        not copy these tokens):
        - webhook -> ["web hook", "web hooke"]
        - async -> ["a sync", "a sink"]
        - middleware -> ["middle ware", "middle wear"]

        If you cannot produce 3 substantively different mistranscriptions, \
        return [].
        """
    }
  }

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
    struct ClassificationResult {
      @Guide(description: "One of: acronym, domain, person, brand, general")
      var category: String
    }

    @Generable
    @available(macOS 26.0, *)
    struct AliasesResult {
      @Guide(description: "3 to 5 phonetic mistranscriptions of the input")
      var suggestedAliases: [String]
    }

    @available(macOS 26, *)
    private func runRawSuggestion(
      for word: String
    ) async throws -> (category: WordCategory, aliases: [String]) {
      let classificationSession = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: Self.classificationInstructions
      )
      let classificationResponse = try await classificationSession.respond(
        to: "Word: \(word)",
        generating: ClassificationResult.self
      )
      let category =
        WordCategory(rawValue: classificationResponse.category.lowercased()) ?? .general

      let aliasSession = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: Self.aliasInstructions(for: category)
      )
      let aliasResponse = try await aliasSession.respond(
        to: "Word: \(word)",
        generating: AliasesResult.self
      )
      return (category, aliasResponse.suggestedAliases)
    }

    @available(macOS 26, *)
    private func runSuggestion(for word: String) async -> WordSuggestions? {
      do {
        let raw = try await runRawSuggestion(for: word)
        let filtered = Self.filterDegeneratedAliases(raw.aliases, canonical: word)
        // Empty after filter (with non-empty raw) means AFM degenerated into self-echoes.
        // Treat as model failure so the UI can render "No suggestions available" instead
        // of zero or duplicate chips.
        // Phase 8 (#620) telemetry hook deferred — PostProcessing module cannot
        // import EnviousWisprServices per the dep-direction guard. Phase 8 proper
        // will inject a telemetry callback at the call site.
        guard !filtered.isEmpty else { return nil }
        return WordSuggestions(category: raw.category, suggestedAliases: filtered)
      } catch {
        return nil
      }
    }

  // MARK: - Dynamic schema fallback (CLT-only builds without macro plugin)

  #elseif canImport(FoundationModels)
    @available(macOS 26, *)
    private func runRawSuggestion(
      for word: String
    ) async throws -> (category: WordCategory, aliases: [String]) {
      // Step 1 — classification.
      let classificationSession = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: Self.classificationInstructions
      )
      let classificationDynamic = DynamicGenerationSchema(
        name: "Classification",
        properties: [
          DynamicGenerationSchema.Property(
            name: "category",
            schema: DynamicGenerationSchema(type: String.self)
          )
        ]
      )
      let classificationSchema = try GenerationSchema(
        root: classificationDynamic, dependencies: []
      )
      let classificationResponse = try await classificationSession.respond(
        to: "Word: \(word)",
        schema: classificationSchema
      )
      let categoryStr = try classificationResponse.content.value(
        String.self, forProperty: "category"
      )
      let category = WordCategory(rawValue: categoryStr.lowercased()) ?? .general

      // Step 2 — alias generation.
      let aliasSession = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: Self.aliasInstructions(for: category)
      )
      let aliasDynamic = DynamicGenerationSchema(
        name: "Aliases",
        properties: [
          DynamicGenerationSchema.Property(
            name: "suggestedAliases",
            schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
          )
        ]
      )
      let aliasSchema = try GenerationSchema(root: aliasDynamic, dependencies: [])
      let aliasResponse = try await aliasSession.respond(
        to: "Word: \(word)",
        schema: aliasSchema
      )
      let raw = try aliasResponse.content.value([String].self, forProperty: "suggestedAliases")
      return (category, raw)
    }

    @available(macOS 26, *)
    private func runSuggestion(for word: String) async -> WordSuggestions? {
      do {
        let raw = try await runRawSuggestion(for: word)
        let filtered = Self.filterDegeneratedAliases(raw.aliases, canonical: word)
        guard !filtered.isEmpty else { return nil }
        return WordSuggestions(category: raw.category, suggestedAliases: filtered)
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

/// Benchmark-only carrier for the alias-eval harness (#637). Returned by
/// `WordSuggestionService.benchmarkSuggest(for:disableTimeout:)`. NEVER
/// persisted, NEVER consumed by production code.
public struct WordSuggestionBenchmarkRecord: Sendable {
  public let category: WordCategory
  public let rawAliases: [String]
  public let filteredAliases: [String]
  public let timedOut: Bool
  public let errorDescription: String?
  public let latencyMs: Int

  public init(
    category: WordCategory,
    rawAliases: [String],
    filteredAliases: [String],
    timedOut: Bool,
    errorDescription: String?,
    latencyMs: Int
  ) {
    self.category = category
    self.rawAliases = rawAliases
    self.filteredAliases = filteredAliases
    self.timedOut = timedOut
    self.errorDescription = errorDescription
    self.latencyMs = latencyMs
  }
}
