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
  /// which shares the same `runRawSuggestion` core but wraps a 5s timeout
  /// and returns `WordSuggestions?` after running the degeneration filter.
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
  // Style: Restored exp4 baseline (prose + per-category examples, no MUST
  // language). This is the proven 18.2% configuration. All three minimal
  // styles (JSON-only, Bare Schema, Wrong/Right Contrast) regressed below
  // this; AFM needs both task definition and concrete examples for this
  // task. Examples use IN-CORPUS words intentionally so AFM's prior
  // knowledge of those words helps; the corpus is intentionally distinct
  // from the example words for unfamiliar items.
  private static func aliasInstructions(for category: WordCategory) -> String {
    switch category {
    case .acronym:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write an \
        ACRONYM wrong. The acronym is spelled letter-by-letter aloud. Each \
        letter is heard as a syllable.

        Output 3 to 5 phonetic mistranscriptions, ONE PER LINE, no numbering, \
        no quotes, no JSON, no surrounding brackets. Each output must be \
        SUBSTANTIVELY different from the input. Never echo the input. \
        Example for "OKR":
        okay are
        oh K R
        okayer
        Example for "PR":
        pee are
        peer
        pee R
        Example for "HIPAA":
        hippa
        hip ah
        hipper

        Never return the same line twice. If you cannot produce 3 \
        substantively different mistranscriptions, return an empty response.
        """
    case .domain:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write a \
        TECHNICAL TERM wrong. The term mixes letters and words; ASR splits \
        it into chunks or letter-syllables.

        Output 3 to 5 phonetic mistranscriptions, ONE PER LINE, no numbering, \
        no quotes, no JSON, no surrounding brackets. Each output must be \
        SUBSTANTIVELY different from the canonical -- NOT just a space \
        inserted, NOT just casing changed. Example for "gRPC":
        gee R P C
        jee R P C
        gee are pee see
        Example for "GraphQL":
        graph Q L
        graf Q L
        graph queue ell
        Example for "WebSocket":
        wep sock it
        wep socket
        web sok it

        Never output the canonical term with only added or removed spaces. \
        If you cannot produce 3 distinct mistranscriptions, return empty.
        """
    case .person:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write a \
        PERSON'S NAME wrong. ASR mishears via vowel and consonant swaps and \
        word-boundary errors.

        Output 3 to 5 phonetic mistranscriptions, ONE PER LINE, no numbering, \
        no quotes, no JSON, no surrounding brackets. Never output honorifics, \
        relatives, last names, or alternate identities. Example for "Parvati":
        par vati
        poor vati
        pavathi
        Example for "Saurabh":
        Sourabh
        Sorab
        Sarab
        Example for "Miyamoto":
        me ya moto
        mia motto
        miyomoto

        If you cannot produce 3 substantively different mistranscriptions, \
        return empty.
        """
    case .brand:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write a \
        BRAND NAME wrong. ASR splits the brand into phonetic chunks of how \
        it is pronounced.

        Output 3 to 5 phonetic mistranscriptions, ONE PER LINE, no numbering, \
        no quotes, no JSON, no surrounding brackets. Each must be \
        SUBSTANTIVELY different from the canonical -- NOT a suffix-strip, \
        NOT just a space. Example for "Kubernetes":
        kuber netties
        cube ernetes
        cooper nettys
        Example for "Postgres":
        post grass
        post gress
        post grease
        Example for "Tailwind":
        tail wind
        tail ind
        tale wynd

        If you cannot produce 3 distinct mistranscriptions, return empty.
        """
    case .general:
      return """
        You predict how speech-to-text engines (Whisper, Parakeet) write a \
        REGULAR WORD wrong. ASR splits at word boundaries or swaps vowels \
        and consonants.

        Output 3 to 5 phonetic mistranscriptions, ONE PER LINE, no numbering, \
        no quotes, no JSON, no surrounding brackets. Example for "webhook":
        web hook
        web hooke
        wuh book
        Example for "async":
        a sync
        a sink
        ay sync
        Example for "middleware":
        middle ware
        middle wear
        midware

        If you cannot produce 3 distinct mistranscriptions, return empty.
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

  /// Parse plain-string AFM output into an array of alias candidates.
  /// Accepts numbered, dashed, or newline-separated outputs. Strips leading
  /// numbering, surrounding quotes (straight or curly), bracket artifacts,
  /// and whitespace. Drops obvious meta-commentary lines (model often
  /// produces "Note:", "Example for X:", "If you cannot..." etc.).
  /// Used by the plain-string alias-generation path (mirroring the polish
  /// path's plain-string + post-filter pattern).
  static func parsePlainStringAliases(_ raw: String) -> [String] {
    var aliases: [String] = []
    let metaTokens = [
      "note:", "example for", "example:", "if you", "the input", "forbidden",
      "mistranscription", "cannot produce", "phonetic", "speech-to-text",
      "asr", "i have ", "i did not", "no mistranscript", "no aliases",
      "return empty", "explanation",
    ]
    for line in raw.components(separatedBy: .newlines) {
      var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if s.isEmpty { continue }
      s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
      s = s.trimmingCharacters(in: .whitespacesAndNewlines)
      if s.isEmpty { continue }
      if let regex = try? NSRegularExpression(
        pattern: #"^(?:\d+[.)]\s*|[-*•]\s*)"#
      ) {
        let range = NSRange(s.startIndex..., in: s)
        s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
      }
      s = s.trimmingCharacters(
        in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019},."))
      s = s.trimmingCharacters(in: .whitespacesAndNewlines)
      if s.isEmpty { continue }
      // Drop meta-commentary by token match.
      let lower = s.lowercased()
      var isMeta = false
      for tok in metaTokens where lower.contains(tok) {
        isMeta = true
        break
      }
      if isMeta { continue }
      // Drop any line containing a colon (sentence/header/JSON-key guard).
      // Aliases are short tokens; a colon is a strong signal of meta text.
      if s.contains(":") { continue }
      // Drop very long lines (aliases are short).
      if s.count > 40 { continue }
      aliases.append(s)
    }
    return aliases
  }

  /// Deterministic classification by syntax. Returns nil when AFM should
  /// classify (proper-noun shapes and CamelCase compounds, where brand
  /// vs person vs domain vs general needs semantic judgment).
  /// Catches obvious all-caps acronyms (CRM, JSON, SQL, API) and obvious
  /// domains with digits/dots/symbols (S3, OAuth2, github.com, K8s,
  /// C++, C#, F#, R&D) and lowercase-start-with-uppercase patterns
  /// (gRPC, iOS).
  static func classifyByHeuristic(_ word: String) -> WordCategory? {
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let hasUpper = trimmed.contains(where: { $0.isUppercase })
    let hasLower = trimmed.contains(where: { $0.isLowercase })
    let allLetters = trimmed.allSatisfy({ $0.isLetter })

    // All-letters all-uppercase (no lowercase, no digits, no punctuation,
    // no symbols of any kind) and 2-8 long -> acronym. CRM, JSON, SQL.
    if allLetters && hasUpper && !hasLower && trimmed.count >= 2 && trimmed.count <= 8 {
      return .acronym
    }

    // Anything containing a non-letter character (digit, dot, slash, dash,
    // underscore, plus, hash, ampersand, etc.) -> domain. Covers S3,
    // OAuth2, github.com, K8s, multi-word-handle, C++, C#, F#, R&D.
    if !allLetters {
      return .domain
    }

    // Pure letters at this point. Lowercase-first with internal uppercase
    // -> domain (gRPC, iOS).
    if let first = trimmed.first, first.isLowercase, hasUpper {
      return .domain
    }

    // CamelCase starting uppercase, all-lowercase, or capitalized first +
    // lowercase rest: ambiguous between person, brand, general, even
    // domain (WebSocket vs Kubernetes vs DigitalOcean). Let AFM decide.
    return nil
  }

  /// Pool aliases from multiple AFM calls, preserving order, deduplicating
  /// by normalized lowercase form. Returns up to `max` unique aliases.
  static func dedupePool(_ lists: [[String]], max: Int) -> [String] {
    var seen = Set<String>()
    var pooled: [String] = []
    for list in lists {
      for s in list {
        let key =
          s
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
        if key.isEmpty { continue }
        if seen.contains(key) { continue }
        seen.insert(key)
        pooled.append(s)
        if pooled.count >= max { return pooled }
      }
    }
    return pooled
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
      @Guide(
        description:
          "3 to 5 distinct phonetic mistranscriptions of the input. Each must differ from the input."
      )
      var suggestedAliases: [String]
    }

    @available(macOS 26, *)
    private func runRawSuggestion(
      for word: String,
      knownCategory: WordCategory? = nil
    ) async throws -> (category: WordCategory, aliases: [String]) {
      // A caller that already knows the category (contacts import pins .person)
      // skips both the heuristic and the AFM classifier call. Otherwise:
      // heuristic classification first — skips one AFM call for clear-cut cases
      // (all-caps short = acronym; mixed-case or digits/dots = domain). The AFM
      // classifier has been observed to misclassify obvious acronyms like CRM,
      // JSON, SQL, API as brand/general/domain.
      let category: WordCategory
      if let knownCategory {
        category = knownCategory
      } else if let heuristic = Self.classifyByHeuristic(word) {
        category = heuristic
      } else {
        let classificationSession = LanguageModelSession(
          model: SystemLanguageModel.default,
          instructions: Self.classificationInstructions
        )
        let classificationResponse = try await classificationSession.respond(
          to: "Word: \(word)",
          generating: ClassificationResult.self
        )
        category =
          WordCategory(rawValue: classificationResponse.category.lowercased()) ?? .general
      }

      // Multi-call pooling: 3 sequential AFM calls with the same prompt,
      // dedup by normalized form, take up to 8 unique outputs. AFM
      // single-call mode-collapses on hard inputs; pooling rescues those.
      // 3 calls was the empirical sweet spot; 4 calls regressed brand.
      let aliasUserPrompt = """
        Word: \(word)
        Forbidden: "\(word)", "\(word.lowercased())".
        """
      var pooled: [[String]] = []
      for _ in 0..<3 {
        let aliases = await Self.singleAliasCall(
          instructions: Self.aliasInstructions(for: category),
          prompt: aliasUserPrompt
        )
        pooled.append(aliases)
      }
      return (category, Self.dedupePool(pooled, max: 8))
    }

    @available(macOS 26, *)
    private static func singleAliasCall(
      instructions: String,
      prompt: String
    ) async -> [String] {
      let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: instructions
      )
      do {
        let response = try await session.respond(
          to: prompt,
          options: GenerationOptions(maximumResponseTokens: 120)
        )
        return parsePlainStringAliases(response.content)
      } catch {
        return []
      }
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
      for word: String,
      knownCategory: WordCategory? = nil
    ) async throws -> (category: WordCategory, aliases: [String]) {
      // Step 1 — classification. A caller that already knows the category
      // (contacts import pins .person) skips it; otherwise heuristic first, AFM
      // as fallback.
      let category: WordCategory
      if let knownCategory {
        category = knownCategory
      } else if let heuristic = Self.classifyByHeuristic(word) {
        category = heuristic
      } else {
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
        category = WordCategory(rawValue: categoryStr.lowercased()) ?? .general
      }

      // Step 2 — alias generation (plain-string output, 3-call pooling).
      let aliasUserPrompt = """
        Word: \(word)
        Forbidden: "\(word)", "\(word.lowercased())".
        """
      var pooled: [[String]] = []
      for _ in 0..<3 {
        let aliases = await Self.singleAliasCallDynamic(
          instructions: Self.aliasInstructions(for: category),
          prompt: aliasUserPrompt
        )
        pooled.append(aliases)
      }
      return (category, Self.dedupePool(pooled, max: 8))
    }

    @available(macOS 26, *)
    private static func singleAliasCallDynamic(
      instructions: String,
      prompt: String
    ) async -> [String] {
      let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: instructions
      )
      do {
        let response = try await session.respond(
          to: prompt,
          options: GenerationOptions(maximumResponseTokens: 120)
        )
        return parsePlainStringAliases(response.content)
      } catch {
        return []
      }
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

// MARK: - AliasSuggesting (contacts-import enrichment, #636 follow-up)

extension WordSuggestionService: AliasSuggesting {
  /// On-device alias generation for an already-classified word. Mirrors
  /// `suggest(for:)`'s availability gate, 5-second timeout, and degeneration
  /// filter, but skips classification (the caller pins the category) and returns
  /// the bare alias list. nil when unavailable, timed out, or the model
  /// degenerated to self-echoes.
  package func suggestAliases(for word: String, category: WordCategory) async -> [String]? {
    #if canImport(FoundationModels)
      guard #available(macOS 26, *),
        case .available = SystemLanguageModel.default.availability
      else { return nil }
      do {
        return try await withThrowingTimeout(seconds: 5) {
          let raw = try await self.runRawSuggestion(for: word, knownCategory: category)
          let filtered = Self.filterDegeneratedAliases(raw.aliases, canonical: word)
          return filtered.isEmpty ? nil : filtered
        }
      } catch {
        return nil
      }
    #else
      return nil
    #endif
  }
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
