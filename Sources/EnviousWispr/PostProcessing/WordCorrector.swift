import Foundation

/// Pure, Sendable word correction engine.
///
/// Compares each word in the input text against a custom word list using a
/// composite score of Levenshtein edit distance, bigram Dice coefficient,
/// and Soundex phonetic matching. Words scoring above the threshold are replaced.
struct WordCorrector: Sendable {
    static let threshold: Double = 0.82

    private static let levenshteinWeight = 0.40
    private static let bigramWeight      = 0.40
    private static let soundexWeight     = 0.20

    func correct(_ text: String, against wordList: [String]) -> (corrected: String, replacements: Int) {
        guard !wordList.isEmpty else { return (text, 0) }

        var replacements = 0
        let words = text.components(separatedBy: .whitespaces)
        let corrected = words.map { token -> String in
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
