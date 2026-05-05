import EnviousWisprCore
import Foundation
import os

/// Pure, Sendable word correction engine.
///
/// Six-pass replacement:
/// 0. **N-gram compound match** -- concatenate 1-3 adjacent words, match against canonicals
///    with spaces removed. Catches "Chat G P T" -> "ChatGPT", "Open A I" -> "OpenAI".
/// 1. **Exact multi-word alias** -- O(1) lookup for multi-word aliases (longest match first).
/// 2. **Fuzzy multi-word alias** -- score phrase against same-token-count aliases when exact misses.
/// 3. **Exact single-word alias** -- O(1) lookup including canonical self-entries for casing fixes.
/// 4. **Fuzzy single-word alias** -- score token against all single-word aliases (error surfaces).
/// 5. **Fuzzy canonical fallback** -- score token against canonicals for words with no aliases.
///
/// Replacement acceptance requires: score >= threshold, ambiguity margin over second-best,
/// stricter threshold for short tokens (<= 4 chars).
public struct WordCorrector: Sendable {
  public static let threshold: Double = 0.82
  /// Curated packs are an explicit install signal. Keep short-token safety,
  /// ambiguity margin, and per-term overrides, but do not let large pack size
  /// erase known ASR-near-miss corrections like "Viper" -> "Vyper".
  public static let packSourceThreshold: Double = 0.70
  public static let multiWordThreshold: Double = 0.85
  public static let shortTokenThreshold: Double = 0.90
  public static let ambiguityMargin: Double = 0.05
  public static let shortTokenMaxLength = 4

  private static let levenshteinWeight = 0.40
  private static let bigramWeight = 0.40
  private static let soundexWeight = 0.20

  private static let logger = Logger(subsystem: "com.enviouswispr", category: "WordCorrector")

  public init() {}

  // MARK: - Phase 2 (#638) hardening helpers — bible §8.2

  /// Common stopwords that lift the multi-word fuzzy threshold by +0.05 when
  /// they appear in a candidate span. Prevents "and we said" → "Andre",
  /// "at this" → "Matthew", "or who" → "Orhul" type degeneration as vocab
  /// grows past 100 terms.
  static let stopwords: Set<String> = [
    "the", "and", "or", "is", "to", "for", "in",
    "a", "at", "on", "of", "we", "you", "it",
  ]

  /// Lift threshold in proportion to candidate-pool density. The chance of a
  /// coincidental near-match grows roughly linearly with candidate density;
  /// this penalty restores precision-at-scale without changing the scoring
  /// shape. Bible §8.2 item 2.
  ///
  /// Pool size ≤ 100 → no penalty.
  /// Pool size 101-600 → +0.02.
  /// Pool size 601-1100 → +0.04.
  /// Pool size 1101+ → +0.06 (capped).
  public static func largeVocabPenalty(poolSize: Int) -> Double {
    guard poolSize > 100 else { return 0 }
    let bumps = (poolSize - 100) / 500
    return min(0.06, Double(bumps) * 0.02)
  }

  /// Loosen threshold for longer candidates. A one-character edit in a 5-char
  /// term costs 20% similarity; the same edit in a 20-char phrase costs 5%.
  /// Subtracts up to 0.04 from the threshold for terms longer than 8 chars.
  /// Bible §8.2 item 3.
  public static func lengthAwareAdjustment(candidateLength: Int) -> Double {
    return min(0.04, 0.005 * Double(max(0, candidateLength - 8)))
  }

  private static func fuzzyThreshold(
    for word: CustomWord?,
    baseThreshold: Double,
    vocabPenalty: Double,
    lengthAdjustment: Double
  ) -> Double {
    if let override = word?.minSimilarityOverride {
      return override
    }

    let defaultThreshold = baseThreshold + vocabPenalty - lengthAdjustment
    if word?.source == .pack, baseThreshold == Self.threshold {
      return min(defaultThreshold, Self.packSourceThreshold)
    }
    return defaultThreshold
  }

  // MARK: - Phase 2b (#638) lookup-map cache

  /// Pre-built lookup structures for one `WordCorrector.correct(...)` call.
  /// Phase 2b (#638) extracts what was previously rebuilt on every call so
  /// `WordCorrectionStep` can cache it across calls of the same vocabulary
  /// generation. Bible §17 R19 (matcher rebuild risk).
  ///
  /// Sendable so callers can hop the value across actors (e.g. running
  /// `correct(...)` off MainActor inside the heart-path 10ms timeout).
  public struct Lookups: Sendable {
    public struct SurfaceCanonical: Sendable {
      public let surface: String
      public let canonical: String
    }
    public struct AliasCanonical: Sendable {
      public let alias: String
      public let canonical: String
    }
    public let singleAliasMap: [String: String]
    public let multiAliasMap: [String: String]
    public let nospaceCanonicalMap: [String: String]
    public let canonicalToID: [String: UUID]
    public let canonicalToWord: [String: CustomWord]
    public let canonicals: [String]
    public let lowercasedCanonicals: [String]
    public let singleFuzzyCandidates: [SurfaceCanonical]
    public let multiAliasByCount: [Int: [AliasCanonical]]
  }

  /// Build the lookup structures for a given vocabulary. Pure function.
  /// `WordCorrectionStep` calls this once per generation change and reuses
  /// the result across many `correct(...)` calls.
  public static func buildLookups(words: [CustomWord]) -> Lookups {
    var singleAliasMap: [String: String] = [:]
    var multiAliasMap: [String: String] = [:]
    var collisionCount = 0
    var canonicalToID: [String: UUID] = [:]
    var canonicalToWord: [String: CustomWord] = [:]
    for word in words {
      canonicalToID[word.canonical.lowercased()] = word.id
      canonicalToWord[word.canonical.lowercased()] = word
    }

    for word in words {
      for alias in word.aliases {
        let key = alias.lowercased()
        if alias.contains(" ") {
          if let existing = multiAliasMap[key], existing != word.canonical {
            collisionCount += 1
            #if DEBUG
              Self.logger.debug(
                "Alias collision #\(collisionCount): '\(key)' claimed by '\(existing)' and '\(word.canonical)', using '\(word.canonical)'"
              )
            #endif
          }
          multiAliasMap[key] = word.canonical
        } else {
          if let existing = singleAliasMap[key], existing != word.canonical {
            collisionCount += 1
            #if DEBUG
              Self.logger.debug(
                "Alias collision #\(collisionCount): '\(key)' claimed by '\(existing)' and '\(word.canonical)', using '\(word.canonical)'"
              )
            #endif
          }
          singleAliasMap[key] = word.canonical
        }
      }
    }

    for word in words {
      let key = word.canonical.lowercased()
      if !key.contains(" ") {
        if let existing = singleAliasMap[key] {
          if existing != word.canonical {
            #if DEBUG
              Self.logger.debug(
                "Canonical '\(word.canonical)' skipped: key '\(key)' already maps to '\(existing)'")
            #endif
          }
        } else {
          singleAliasMap[key] = word.canonical
        }
      }
    }

    let canonicals = words.map(\.canonical)
    let lowercasedCanonicals = canonicals.map { $0.lowercased() }
    let singleFuzzyCandidates = singleAliasMap.map {
      Lookups.SurfaceCanonical(surface: $0.key, canonical: $0.value)
    }
    var multiAliasByCount: [Int: [Lookups.AliasCanonical]] = [:]
    for (alias, canonical) in multiAliasMap {
      let count = alias.components(separatedBy: " ").count
      multiAliasByCount[count, default: []].append(
        Lookups.AliasCanonical(alias: alias, canonical: canonical))
    }

    var nospaceCanonicalMap: [String: String] = [:]
    for word in words {
      let nospace = word.canonical.replacingOccurrences(of: " ", with: "").lowercased()
      nospaceCanonicalMap[nospace] = word.canonical
      for alias in word.aliases {
        let aliasNospace = alias.replacingOccurrences(of: " ", with: "").lowercased()
        if nospaceCanonicalMap[aliasNospace] == nil {
          nospaceCanonicalMap[aliasNospace] = word.canonical
        }
      }
    }

    return Lookups(
      singleAliasMap: singleAliasMap,
      multiAliasMap: multiAliasMap,
      nospaceCanonicalMap: nospaceCanonicalMap,
      canonicalToID: canonicalToID,
      canonicalToWord: canonicalToWord,
      canonicals: canonicals,
      lowercasedCanonicals: lowercasedCanonicals,
      singleFuzzyCandidates: singleFuzzyCandidates,
      multiAliasByCount: multiAliasByCount
    )
  }

  // MARK: - Replacement attribution (Phase 3a #631)

  /// Per-replacement attribution: which `CustomWord.id` this replacement
  /// originated from. Phase 3b consumes the list to bump `frequencyUsed` /
  /// `lastUsed` on each source. Phase 7 may extend with `pass: Int, span:
  /// Range<String.Index>` if needed (currently unused per bible §13).
  public struct Replacement: Sendable, Equatable {
    public let sourceID: UUID
    public init(sourceID: UUID) { self.sourceID = sourceID }
  }

  // MARK: - Main Correction

  /// Convenience overload — builds lookups inline. Use this when you only
  /// call `correct` once per vocabulary (legacy callers, tests).
  public func correct(_ text: String, against words: [CustomWord]) -> (
    corrected: String, replacements: [Replacement]
  ) {
    guard !words.isEmpty else { return (text, []) }
    let lookups = Self.buildLookups(words: words)
    return correct(text, using: lookups)
  }

  /// Phase 2b (#638) primary entry point. Accepts pre-built lookups so
  /// `WordCorrectionStep` can cache the build cost across calls of the same
  /// vocabulary generation. Pure function — safe to call off any actor.
  public func correct(_ text: String, using lookups: Lookups) -> (
    corrected: String, replacements: [Replacement]
  ) {
    let singleAliasMap = lookups.singleAliasMap
    let multiAliasMap = lookups.multiAliasMap
    let nospaceCanonicalMap = lookups.nospaceCanonicalMap
    let canonicalToID = lookups.canonicalToID
    let canonicalToWord = lookups.canonicalToWord
    let canonicals = lookups.canonicals
    let lowercasedCanonicals = lookups.lowercasedCanonicals
    let singleFuzzyCandidates = lookups.singleFuzzyCandidates
    let multiAliasByCount = lookups.multiAliasByCount

    var replacements: [Replacement] = []
    var tokens = text.components(separatedBy: .whitespaces)
    // Phase 3a (#631) helper: append a Replacement for the given canonical.
    // Falls through silently if the canonical lookup misses (shouldn't happen
    // with valid input — defensive only).
    func appendReplacement(forCanonical canonical: String) {
      if let id = canonicalToID[canonical.lowercased()] {
        replacements.append(Replacement(sourceID: id))
      }
    }

    // Pass 0: N-gram compound matching
    // Concatenate 1-3 adjacent words (stripped of punctuation, lowercased, spaces removed)
    // and check against nospace canonical/alias map.
    // "Chat G P T" -> "chatgpt" matches "ChatGPT"
    if !nospaceCanonicalMap.isEmpty {
      var i = 0
      while i < tokens.count {
        var matched = false

        for n in (1...min(3, tokens.count - i)).reversed() {
          let slice = tokens[i..<(i + n)]
          let ngram =
            slice
            .map { stripPunctuation($0).lowercased() }
            .joined()  // No separator: concatenate directly

          guard ngram.count >= 3 else { continue }

          // Length ratio check: ngram must be within 25% of candidate length
          if let canonical = nospaceCanonicalMap[ngram] {
            let canonicalNospace = canonical.replacingOccurrences(of: " ", with: "")
            // Check it's not already correct
            let rawConcat = slice.map { stripPunctuation($0) }.joined()
            if rawConcat == canonicalNospace { break }

            let (firstPrefix, _, _) = splitPunctuation(tokens[i])
            let (_, _, lastSuffix) = splitPunctuation(tokens[i + n - 1])
            tokens.replaceSubrange(i..<(i + n), with: [firstPrefix + canonical + lastSuffix])
            appendReplacement(forCanonical: canonical)
            matched = true
            #if DEBUG
              Self.logger.debug(
                "WordCorrector: type=ngram-compound source='\(rawConcat)' target='\(canonical)' n=\(n)"
              )
            #endif
            break
          }
        }

        i += 1
        if matched { continue }
      }
    }

    // Pass 1 + 2: multi-word (exact then fuzzy)
    if !multiAliasMap.isEmpty {
      let maxSpan = multiAliasMap.keys.reduce(0) { max($0, $1.components(separatedBy: " ").count) }
      var i = 0
      while i < tokens.count {
        var matched = false

        for span in stride(from: min(maxSpan, tokens.count - i), through: 2, by: -1) {
          let slice = tokens[i..<(i + span)]
          let phrase = slice.map { stripPunctuation($0).lowercased() }.joined(separator: " ")
          let rawPhrase = slice.map { stripPunctuation($0) }.joined(separator: " ")

          // Pass 1: exact multi-word alias
          if let canonical = multiAliasMap[phrase], rawPhrase != canonical {
            let (firstPrefix, _, _) = splitPunctuation(tokens[i])
            let (_, _, lastSuffix) = splitPunctuation(tokens[i + span - 1])
            tokens.replaceSubrange(i..<(i + span), with: [firstPrefix + canonical + lastSuffix])
            appendReplacement(forCanonical: canonical)
            matched = true
            #if DEBUG
              Self.logger.debug(
                "WordCorrector: type=multi-word-exact source='\(rawPhrase)' target='\(canonical)'")
            #endif
            break
          }
        }

        // Pass 2: fuzzy multi-word fallback (only if exact missed for all spans)
        if !matched {
          for span in stride(from: min(maxSpan, tokens.count - i), through: 2, by: -1) {
            let slice = tokens[i..<(i + span)]
            let phrase = slice.map { stripPunctuation($0).lowercased() }.joined(separator: " ")
            let rawPhrase = slice.map { stripPunctuation($0) }.joined(separator: " ")

            if let candidates = multiAliasByCount[span] {
              var bestScore = 0.0
              var secondBest = 0.0
              var bestCanonical = ""
              var bestAlias = ""

              for entry in candidates {
                let alias = entry.alias
                let canonical = entry.canonical
                let s = score(phrase, against: alias)
                if s > bestScore {
                  if bestCanonical != canonical { secondBest = bestScore }
                  bestScore = s
                  bestCanonical = canonical
                  bestAlias = alias
                } else if s > secondBest && canonical != bestCanonical {
                  secondBest = s
                }
              }

              let margin = bestScore - secondBest
              // Phase 2 (#638) §8.2 item 1: lift multi-word threshold by +0.05
              // when the candidate span includes any common stopword. Prevents
              // "and we said" → "Andre" type degeneration.
              let phraseTokens = Set(phrase.components(separatedBy: " "))
              let hasStopword = !phraseTokens.isDisjoint(with: Self.stopwords)
              let stopwordPenalty = hasStopword ? 0.05 : 0.0
              // Phase 2 (#638) §8.2 item 4: per-term override for the matched
              // canonical, if any. Override is the absolute bar.
              let multiOverride = canonicalToWord[bestCanonical.lowercased()]?
                .minSimilarityOverride
              let multiThreshold = multiOverride ?? (Self.multiWordThreshold + stopwordPenalty)
              if bestScore >= multiThreshold,
                margin >= Self.ambiguityMargin,
                rawPhrase != bestCanonical
              {
                let (firstPrefix, _, _) = splitPunctuation(tokens[i])
                let (_, _, lastSuffix) = splitPunctuation(tokens[i + span - 1])
                tokens.replaceSubrange(
                  i..<(i + span), with: [firstPrefix + bestCanonical + lastSuffix])
                appendReplacement(forCanonical: bestCanonical)
                matched = true
                #if DEBUG
                  Self.logger.debug(
                    "WordCorrector: type=multi-word-fuzzy source='\(rawPhrase)' target='\(bestCanonical)' alias='\(bestAlias)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(margin, format: .fixed(precision: 3)) stopword=\(hasStopword) override=\(multiOverride.map { String($0) } ?? "nil")"
                  )
                #endif
                break
              } else if bestScore > 0 {
                #if DEBUG
                  let reason: String
                  if bestScore < multiThreshold {
                    reason = "below_threshold"
                  } else if margin < Self.ambiguityMargin {
                    reason = "below_margin"
                  } else {
                    reason = "same_as_input"
                  }
                  Self.logger.debug(
                    "WordCorrector: REJECT pass=multi-word-fuzzy source='\(rawPhrase)' best_target='\(bestCanonical)' alias='\(bestAlias)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(margin, format: .fixed(precision: 3)) threshold=\(multiThreshold, format: .fixed(precision: 3)) stopword=\(hasStopword) reason=\(reason)"
                  )
                #endif
              }
            }
          }
        }

        i += 1
      }
    }

    // Passes 3-5: single-word (per token)
    let corrected = tokens.map { token -> String in
      let (prefix, core, suffix) = splitPunctuation(token)
      guard !core.isEmpty, core.count >= 2 else { return token }

      let coreLower = core.lowercased()

      // Pass 3: exact single-word alias (includes canonical self-entries)
      if let canonical = singleAliasMap[coreLower], core != canonical {
        appendReplacement(forCanonical: canonical)
        #if DEBUG
          Self.logger.debug("WordCorrector: type=alias source='\(core)' target='\(canonical)'")
        #endif
        return prefix + canonical + suffix
      }

      // Skip fuzzy for very short tokens
      guard core.count >= 3 else { return token }

      // Determine threshold based on token length
      let effectiveThreshold =
        core.count <= Self.shortTokenMaxLength
        ? Self.shortTokenThreshold
        : Self.threshold

      // Pass 4: fuzzy single-word against aliases + canonical self-entries
      let coreLen = coreLower.count
      var bestScore = 0.0
      var secondBest = 0.0
      var bestMatch = ""

      for entry in singleFuzzyCandidates {
        let surface = entry.surface
        let canonical = entry.canonical
        // Length-ratio pruning: skip if lengths differ too much for threshold
        let surfLen = surface.count
        let lenRatio = Double(min(coreLen, surfLen)) / Double(max(coreLen, surfLen))
        if lenRatio < 0.5 { continue }

        let s = score(coreLower, against: surface)
        if s > bestScore {
          if bestMatch != canonical { secondBest = bestScore }
          bestScore = s
          bestMatch = canonical
        } else if s > secondBest && canonical != bestMatch {
          secondBest = s
        }
      }

      // Phase 2 (#638) §8.2: vocab-size penalty + length-aware adjustment
      // applied per-candidate. Per-term override wins absolutely if set.
      let pass4VocabPenalty = Self.largeVocabPenalty(poolSize: singleFuzzyCandidates.count)
      let pass4LengthAdj = Self.lengthAwareAdjustment(candidateLength: bestMatch.count)
      let pass4Word = canonicalToWord[bestMatch.lowercased()]
      let pass4Threshold = Self.fuzzyThreshold(
        for: pass4Word,
        baseThreshold: effectiveThreshold,
        vocabPenalty: pass4VocabPenalty,
        lengthAdjustment: pass4LengthAdj
      )
      if bestScore >= pass4Threshold,
        bestScore - secondBest >= Self.ambiguityMargin,
        core != bestMatch
      {
        appendReplacement(forCanonical: bestMatch)
        #if DEBUG
          Self.logger.debug(
            "WordCorrector: type=alias-fuzzy source='\(core)' target='\(bestMatch)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(bestScore - secondBest, format: .fixed(precision: 3)) threshold=\(pass4Threshold, format: .fixed(precision: 3))"
          )
        #endif
        return prefix + bestMatch + suffix
      } else if bestScore > 0 {
        #if DEBUG
          let pass4Margin = bestScore - secondBest
          let reason: String
          if bestScore < pass4Threshold {
            reason = "below_threshold"
          } else if pass4Margin < Self.ambiguityMargin {
            reason = "below_margin"
          } else {
            reason = "same_as_input"
          }
          Self.logger.debug(
            "WordCorrector: REJECT pass=alias-fuzzy source='\(core)' best_target='\(bestMatch)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(pass4Margin, format: .fixed(precision: 3)) threshold=\(pass4Threshold, format: .fixed(precision: 3)) reason=\(reason)"
          )
        #endif
      }

      // Pass 5: fuzzy single-word against canonicals as fallback
      bestScore = 0.0
      secondBest = 0.0
      bestMatch = ""

      for (idx, targetLower) in lowercasedCanonicals.enumerated() {
        let targetLen = targetLower.count
        let lenRatio = Double(min(coreLen, targetLen)) / Double(max(coreLen, targetLen))
        if lenRatio < 0.5 { continue }

        let s = score(coreLower, against: targetLower)
        if s > bestScore {
          secondBest = bestScore
          bestScore = s
          bestMatch = canonicals[idx]
        } else if s > secondBest {
          secondBest = s
        }
      }

      // Phase 2 (#638) §8.2: same hardening for Pass 5.
      let pass5VocabPenalty = Self.largeVocabPenalty(poolSize: lowercasedCanonicals.count)
      let pass5LengthAdj = Self.lengthAwareAdjustment(candidateLength: bestMatch.count)
      let pass5Word = canonicalToWord[bestMatch.lowercased()]
      let pass5Threshold = Self.fuzzyThreshold(
        for: pass5Word,
        baseThreshold: effectiveThreshold,
        vocabPenalty: pass5VocabPenalty,
        lengthAdjustment: pass5LengthAdj
      )
      if bestScore >= pass5Threshold,
        bestScore - secondBest >= Self.ambiguityMargin,
        core != bestMatch
      {
        appendReplacement(forCanonical: bestMatch)
        #if DEBUG
          Self.logger.debug(
            "WordCorrector: type=canonical-fuzzy source='\(core)' target='\(bestMatch)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(bestScore - secondBest, format: .fixed(precision: 3)) threshold=\(pass5Threshold, format: .fixed(precision: 3))"
          )
        #endif
        return prefix + bestMatch + suffix
      } else if bestScore > 0 {
        #if DEBUG
          let pass5Margin = bestScore - secondBest
          let reason: String
          if bestScore < pass5Threshold {
            reason = "below_threshold"
          } else if pass5Margin < Self.ambiguityMargin {
            reason = "below_margin"
          } else {
            reason = "same_as_input"
          }
          Self.logger.debug(
            "WordCorrector: REJECT pass=canonical-fuzzy source='\(core)' best_target='\(bestMatch)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(pass5Margin, format: .fixed(precision: 3)) threshold=\(pass5Threshold, format: .fixed(precision: 3)) reason=\(reason)"
          )
        #endif
      }

      return token
    }

    return (corrected.joined(separator: " "), replacements)
  }

  // MARK: - Scoring

  public func score(_ candidate: String, against target: String) -> Double {
    let lev = levenshteinSimilarity(candidate, target) * Self.levenshteinWeight
    let bigram = bigramDice(candidate, target) * Self.bigramWeight
    let sdx = soundexScore(candidate, target) * Self.soundexWeight
    return lev + bigram + sdx
  }

  // MARK: - Levenshtein

  private func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
    let a = Array(a)
    let b = Array(b)
    let m = a.count
    let n = b.count
    if m == 0 { return n == 0 ? 1.0 : 0.0 }
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 0...m { dp[i][0] = i }
    for j in 0...n { dp[0][j] = j }
    for i in 1...m {
      for j in 1...n {
        dp[i][j] =
          a[i - 1] == b[j - 1]
          ? dp[i - 1][j - 1]
          : 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
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
      return Set((0..<chars.count - 1).map { String([chars[$0], chars[$0 + 1]]) })
    }
    let ba = bigrams(a)
    let bb = bigrams(b)
    guard !ba.isEmpty || !bb.isEmpty else { return a == b ? 1.0 : 0.0 }
    let intersection = ba.intersection(bb).count
    return 2.0 * Double(intersection) / Double(ba.count + bb.count)
  }

  // MARK: - Soundex

  private func soundexScore(_ a: String, _ b: String) -> Double {
    soundex(a) == soundex(b) ? 1.0 : 0.0
  }

  private static let soundexMap: [Character: Character] = [
    "b": "1", "f": "1", "p": "1", "v": "1",
    "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
    "d": "3", "t": "3", "e": "0", "i": "0", "o": "0", "u": "0", "y": "0", "h": "0", "w": "0",
    "l": "4", "m": "5", "n": "5", "r": "6",
  ]

  private func soundex(_ s: String) -> String {
    let lower = s.lowercased()
    guard let first = lower.first else { return "0000" }

    var code = String(first.uppercased())
    var last = Self.soundexMap[first] ?? "0"

    for ch in lower.dropFirst() {
      guard let digit = Self.soundexMap[ch] else { continue }
      if digit != "0" && digit != last {
        code.append(digit)
        if code.count == 4 { break }
      }
      last = digit
    }

    while code.count < 4 { code.append("0") }
    return code
  }

  // MARK: - Helpers

  private func stripPunctuation(_ token: String) -> String {
    splitPunctuation(token).core
  }

  private func splitPunctuation(_ token: String) -> (prefix: String, core: String, suffix: String) {
    var prefix = ""
    var core = token
    var suffix = ""
    while let first = core.first, !first.isLetter && !first.isNumber {
      prefix.append(first)
      core = String(core.dropFirst())
    }
    while let last = core.last, !last.isLetter && !last.isNumber {
      suffix = String(last) + suffix
      core = String(core.dropLast())
    }
    return (prefix, core, suffix)
  }
}
