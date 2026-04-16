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
  public static let multiWordThreshold: Double = 0.85
  public static let shortTokenThreshold: Double = 0.90
  public static let ambiguityMargin: Double = 0.05
  public static let shortTokenMaxLength = 4

  private static let levenshteinWeight = 0.40
  private static let bigramWeight = 0.40
  private static let soundexWeight = 0.20

  private static let logger = Logger(subsystem: "com.enviouswispr", category: "WordCorrector")

  public init() {}

  // MARK: - Main Correction

  public func correct(_ text: String, against words: [CustomWord]) -> (
    corrected: String, replacements: Int
  ) {
    guard !words.isEmpty else { return (text, 0) }

    // --- Build lookup structures (once per call) ---

    var singleAliasMap: [String: String] = [:]
    var multiAliasMap: [String: String] = [:]
    var collisionCount = 0

    // 1. Build alias maps with collision detection
    for word in words {
      for alias in word.aliases {
        let key = alias.lowercased()
        if alias.contains(" ") {
          if let existing = multiAliasMap[key], existing != word.canonical {
            collisionCount += 1
            Self.logger.debug(
              "Alias collision #\(collisionCount): '\(key)' claimed by '\(existing)' and '\(word.canonical)', using '\(word.canonical)'"
            )
          }
          multiAliasMap[key] = word.canonical
        } else {
          if let existing = singleAliasMap[key], existing != word.canonical {
            collisionCount += 1
            Self.logger.debug(
              "Alias collision #\(collisionCount): '\(key)' claimed by '\(existing)' and '\(word.canonical)', using '\(word.canonical)'"
            )
          }
          singleAliasMap[key] = word.canonical
        }
      }
    }

    // 2. Add canonical self-entries (explicit aliases win)
    for word in words {
      let key = word.canonical.lowercased()
      if !key.contains(" ") {
        if let existing = singleAliasMap[key] {
          if existing != word.canonical {
            Self.logger.debug(
              "Canonical '\(word.canonical)' skipped: key '\(key)' already maps to '\(existing)'")
          }
        } else {
          singleAliasMap[key] = word.canonical
        }
      }
    }

    // 3. Pre-index for fuzzy passes
    let canonicals = words.map(\.canonical)
    let lowercasedCanonicals = canonicals.map { $0.lowercased() }

    // Single-word fuzzy candidates: all entries in singleAliasMap
    let singleFuzzyCandidates = singleAliasMap.map { (surface: $0.key, canonical: $0.value) }

    // Multi-word fuzzy candidates indexed by token count
    var multiAliasByCount: [Int: [(alias: String, canonical: String)]] = [:]
    for (alias, canonical) in multiAliasMap {
      let count = alias.components(separatedBy: " ").count
      multiAliasByCount[count, default: []].append((alias, canonical))
    }

    // --- Correction passes ---

    var replacements = 0
    var tokens = text.components(separatedBy: .whitespaces)

    // Build nospace lookup for Pass 0 (n-gram compound matching)
    // Maps lowercase-nospace canonical -> original canonical
    // e.g., "chatgpt" -> "ChatGPT", "openai" -> "OpenAI", "vscode" -> "VS Code"
    var nospaceCanonicalMap: [String: String] = [:]
    for word in words {
      let nospace = word.canonical.replacingOccurrences(of: " ", with: "").lowercased()
      nospaceCanonicalMap[nospace] = word.canonical
      // Also index aliases without spaces
      for alias in word.aliases {
        let aliasNospace = alias.replacingOccurrences(of: " ", with: "").lowercased()
        if nospaceCanonicalMap[aliasNospace] == nil {
          nospaceCanonicalMap[aliasNospace] = word.canonical
        }
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
            replacements += 1
            matched = true
            Self.logger.debug(
              "WordCorrector: type=ngram-compound source='\(rawConcat)' target='\(canonical)' n=\(n)"
            )
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
            replacements += 1
            matched = true
            Self.logger.debug(
              "WordCorrector: type=multi-word-exact source='\(rawPhrase)' target='\(canonical)'")
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

              for (alias, canonical) in candidates {
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
              if bestScore >= Self.multiWordThreshold,
                margin >= Self.ambiguityMargin,
                rawPhrase != bestCanonical
              {
                let (firstPrefix, _, _) = splitPunctuation(tokens[i])
                let (_, _, lastSuffix) = splitPunctuation(tokens[i + span - 1])
                tokens.replaceSubrange(
                  i..<(i + span), with: [firstPrefix + bestCanonical + lastSuffix])
                replacements += 1
                matched = true
                Self.logger.debug(
                  "WordCorrector: type=multi-word-fuzzy source='\(rawPhrase)' target='\(bestCanonical)' alias='\(bestAlias)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(margin, format: .fixed(precision: 3))"
                )
                break
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
        replacements += 1
        Self.logger.debug("WordCorrector: type=alias source='\(core)' target='\(canonical)'")
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

      for (surface, canonical) in singleFuzzyCandidates {
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

      if bestScore >= effectiveThreshold,
        bestScore - secondBest >= Self.ambiguityMargin,
        core != bestMatch
      {
        replacements += 1
        Self.logger.debug(
          "WordCorrector: type=alias-fuzzy source='\(core)' target='\(bestMatch)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(bestScore - secondBest, format: .fixed(precision: 3))"
        )
        return prefix + bestMatch + suffix
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

      if bestScore >= effectiveThreshold,
        bestScore - secondBest >= Self.ambiguityMargin,
        core != bestMatch
      {
        replacements += 1
        Self.logger.debug(
          "WordCorrector: type=canonical-fuzzy source='\(core)' target='\(bestMatch)' score=\(bestScore, format: .fixed(precision: 3)) margin=\(bestScore - secondBest, format: .fixed(precision: 3))"
        )
        return prefix + bestMatch + suffix
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
