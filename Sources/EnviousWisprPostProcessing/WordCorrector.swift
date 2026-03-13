import Foundation
import EnviousWisprCore

/// Pure, Sendable word correction engine.
///
/// Two-pass replacement:
/// 1. **Alias match** — exact case-insensitive lookup against user-defined aliases.
///    Instant O(1) per token. Handles phonetic gaps the fuzzy scorer can't bridge
///    (e.g. "cloud" → "Claude").
/// 2. **Fuzzy match** — composite score of Levenshtein, bigram Dice, and Soundex
///    against canonicals. Catches typos and minor ASR drift.
public struct WordCorrector: Sendable {
    public static let threshold: Double = 0.82

    private static let levenshteinWeight = 0.40
    private static let bigramWeight      = 0.40
    private static let soundexWeight     = 0.20

    /// Alias-aware correction against full CustomWord entries.
    ///
    /// Three passes over the text:
    /// 1. **Multi-word alias match** — scan for 2- and 3-word spans that match
    ///    multi-word aliases (e.g. "envious whisper" → "EnviousWispr").
    /// 2. **Single-word alias match** — exact case-insensitive lookup per token.
    /// 3. **Fuzzy match** — composite scoring against canonicals.
    public init() {}

    public func correct(_ text: String, against words: [CustomWord]) -> (corrected: String, replacements: Int) {
        guard !words.isEmpty else { return (text, 0) }

        // Build alias lookups, partitioned by word count
        var singleAliasMap: [String: String] = [:]
        var multiAliasMap: [String: String] = [:]  // lowercased multi-word alias → canonical
        for word in words {
            for alias in word.aliases {
                let key = alias.lowercased()
                if alias.contains(" ") {
                    multiAliasMap[key] = word.canonical
                } else {
                    singleAliasMap[key] = word.canonical
                }
            }
        }

        // Pre-compute for fuzzy pass
        let canonicals = words.map(\.canonical)
        let lowercasedCanonicals = canonicals.map { $0.lowercased() }

        var replacements = 0
        var tokens = text.components(separatedBy: .whitespaces)

        // Pass 1: multi-word alias matching (longest match first)
        if !multiAliasMap.isEmpty {
            let maxSpan = multiAliasMap.keys.reduce(0) { max($0, $1.components(separatedBy: " ").count) }
            var i = 0
            while i < tokens.count {
                var matched = false
                // Try longest spans first for greedy matching
                for span in stride(from: min(maxSpan, tokens.count - i), through: 2, by: -1) {
                    let slice = tokens[i..<(i + span)]
                    let phrase = slice.map { stripPunctuation($0).lowercased() }.joined(separator: " ")
                    if let canonical = multiAliasMap[phrase], phrase != canonical.lowercased() {
                        // Preserve leading punctuation of first token and trailing punctuation of last
                        let (firstPrefix, _, _) = splitPunctuation(tokens[i])
                        let (_, _, lastSuffix) = splitPunctuation(tokens[i + span - 1])
                        tokens.replaceSubrange(i..<(i + span), with: [firstPrefix + canonical + lastSuffix])
                        replacements += 1
                        matched = true
                        break
                    }
                }
                if !matched { i += 1 } else { i += 1 }
            }
        }

        // Pass 2 & 3: single-word alias + fuzzy, per token
        let corrected = tokens.map { token -> String in
            let (prefix, core, suffix) = splitPunctuation(token)
            guard !core.isEmpty, core.count >= 2 else { return token }

            let coreLower = core.lowercased()

            // Pass 2: exact single-word alias match
            if let canonical = singleAliasMap[coreLower], coreLower != canonical.lowercased() {
                replacements += 1
                return prefix + canonical + suffix
            }

            // Pass 3: fuzzy match against canonicals (skip short tokens)
            guard core.count >= 3 else { return token }

            var bestScore = 0.0
            var bestMatch = ""

            for (idx, targetLower) in lowercasedCanonicals.enumerated() {
                let s = score(coreLower, against: targetLower)
                if s > bestScore {
                    bestScore = s
                    bestMatch = canonicals[idx]
                    if bestScore >= 1.0 { break }
                }
            }

            if bestScore >= Self.threshold, coreLower != bestMatch.lowercased() {
                replacements += 1
                return prefix + bestMatch + suffix
            }
            return token
        }
        return (corrected.joined(separator: " "), replacements)
    }

    /// Strip punctuation and return just the core text, lowercased.
    private func stripPunctuation(_ token: String) -> String {
        splitPunctuation(token).core
    }

    /// Legacy bridge: correct against plain string list (no alias support).
    public func correct(_ text: String, against wordList: [String]) -> (corrected: String, replacements: Int) {
        let words = wordList.map { CustomWord(canonical: $0) }
        return correct(text, against: words)
    }

    public func score(_ candidate: String, against target: String) -> Double {
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

    private static let soundexMap: [Character: Character] = [
        "b":"1","f":"1","p":"1","v":"1",
        "c":"2","g":"2","j":"2","k":"2","q":"2","s":"2","x":"2","z":"2",
        "d":"3","t":"3","e":"0","i":"0","o":"0","u":"0","y":"0","h":"0","w":"0",
        "l":"4","m":"5","n":"5","r":"6",
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
