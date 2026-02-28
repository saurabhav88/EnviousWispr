import Foundation

/// Calculates Word Error Rate (WER) between a reference transcript and a hypothesis.
///
/// Uses the standard edit-distance formula:
///   WER = (Substitutions + Insertions + Deletions) / ReferenceWordCount
enum WERCalculator {
    struct Result: Sendable {
        let wer: Double
        let substitutions: Int
        let insertions: Int
        let deletions: Int
        let referenceWordCount: Int
        let hypothesisWordCount: Int
    }

    /// Compute WER between reference and hypothesis text.
    /// Both strings are lowercased and split on whitespace before comparison.
    static func calculate(reference: String, hypothesis: String) -> Result {
        let refWords = reference.lowercased().split(separator: " ").map(String.init)
        let hypWords = hypothesis.lowercased().split(separator: " ").map(String.init)

        guard !refWords.isEmpty else {
            return Result(
                wer: hypWords.isEmpty ? 0.0 : Double(hypWords.count),
                substitutions: 0,
                insertions: hypWords.count,
                deletions: 0,
                referenceWordCount: 0,
                hypothesisWordCount: hypWords.count
            )
        }

        let n = refWords.count
        let m = hypWords.count

        // DP table for edit distance
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)

        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }

        for i in 1...n {
            for j in 1...m {
                if refWords[i - 1] == hypWords[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(
                        dp[i - 1][j - 1],  // substitution
                        dp[i - 1][j],       // deletion
                        dp[i][j - 1]        // insertion
                    )
                }
            }
        }

        // Backtrace to count S, I, D
        var i = n, j = m
        var subs = 0, ins = 0, dels = 0

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && refWords[i - 1] == hypWords[j - 1] {
                i -= 1; j -= 1
            } else if i > 0 && j > 0 && dp[i][j] == dp[i - 1][j - 1] + 1 {
                subs += 1; i -= 1; j -= 1
            } else if j > 0 && dp[i][j] == dp[i][j - 1] + 1 {
                ins += 1; j -= 1
            } else {
                dels += 1; i -= 1
            }
        }

        let wer = Double(subs + ins + dels) / Double(n)

        return Result(
            wer: wer,
            substitutions: subs,
            insertions: ins,
            deletions: dels,
            referenceWordCount: n,
            hypothesisWordCount: m
        )
    }
}
