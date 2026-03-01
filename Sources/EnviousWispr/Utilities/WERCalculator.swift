import Foundation

/// Calculates Word Error Rate (WER) between a reference transcript and a hypothesis.
///
/// Uses the standard edit-distance formula:
///   WER = (Substitutions + Insertions + Deletions) / ReferenceWordCount
enum WERCalculator {
    struct Result: Sendable {
        let wer: Double
    }

    /// Compute WER between reference and hypothesis text.
    /// Both strings are lowercased and split on whitespace before comparison.
    static func calculate(reference: String, hypothesis: String) -> Result {
        let refWords = reference.lowercased().split(separator: " ").map(String.init)
        let hypWords = hypothesis.lowercased().split(separator: " ").map(String.init)

        guard !refWords.isEmpty else {
            return Result(wer: hypWords.isEmpty ? 0.0 : Double(hypWords.count))
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

        let wer = Double(dp[n][m]) / Double(n)
        return Result(wer: wer)
    }
}
