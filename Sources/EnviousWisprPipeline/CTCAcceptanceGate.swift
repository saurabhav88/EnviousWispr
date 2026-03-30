import EnviousWisprCore
import Foundation

/// Decides whether a CTC rescore result should replace the heart transcript.
///
/// CTC runs a full batch re-transcription with vocabulary boosting. This means
/// it can change ANY part of the text, not just custom vocabulary matches.
/// The acceptance gate filters out broad rewrites and only accepts narrow,
/// vocabulary-related corrections.
///
/// Rules (all must pass):
/// 1. At least one custom term appears in a changed region
/// 2. Total token edits are small (max 3 changed tokens)
/// 3. Changes are localized (max 2 changed spans)
/// 4. No broad rewrite (>40% of tokens changed)
/// 5. Utterance not too short (min 3 tokens in heart)
enum CTCAcceptanceGate {

    struct Decision: Sendable {
        let accepted: Bool
        let reason: String
        let changedSpans: Int
        let changedTokens: Int
        let totalTokens: Int
        let vocabTermsInChanges: [String]
    }

    /// Evaluate whether the CTC result should replace the heart result.
    static func evaluate(
        heartText: String,
        ctcText: String,
        vocabularyTerms: [String]
    ) -> Decision {
        let heartTokens = tokenize(heartText)
        let ctcTokens = tokenize(ctcText)

        // Rule 5: utterance too short
        guard heartTokens.count >= 3 else {
            return Decision(
                accepted: false,
                reason: "utterance too short (\(heartTokens.count) tokens)",
                changedSpans: 0, changedTokens: 0,
                totalTokens: heartTokens.count, vocabTermsInChanges: []
            )
        }

        // Compute token-level diff
        let diff = computeDiff(heartTokens, ctcTokens)

        // Rule 4: no broad rewrite
        let changeRatio = Double(diff.changedTokenCount) / Double(max(heartTokens.count, 1))
        guard changeRatio <= 0.40 else {
            return Decision(
                accepted: false,
                reason: "broad rewrite (\(Int(changeRatio * 100))% changed)",
                changedSpans: diff.spans.count, changedTokens: diff.changedTokenCount,
                totalTokens: heartTokens.count, vocabTermsInChanges: []
            )
        }

        // Rule 2: max changed tokens
        guard diff.changedTokenCount <= 3 else {
            return Decision(
                accepted: false,
                reason: "too many changed tokens (\(diff.changedTokenCount))",
                changedSpans: diff.spans.count, changedTokens: diff.changedTokenCount,
                totalTokens: heartTokens.count, vocabTermsInChanges: []
            )
        }

        // Rule 3: max changed spans
        guard diff.spans.count <= 2 else {
            return Decision(
                accepted: false,
                reason: "too many changed spans (\(diff.spans.count))",
                changedSpans: diff.spans.count, changedTokens: diff.changedTokenCount,
                totalTokens: heartTokens.count, vocabTermsInChanges: []
            )
        }

        // Rule 1: at least one custom term in a changed region
        let lowerVocab = Set(vocabularyTerms.map { $0.lowercased() })
        var vocabTermsFound: [String] = []

        for span in diff.spans {
            // Check CTC tokens in this span for vocabulary matches
            let ctcSpanText = span.ctcTokens.joined(separator: " ").lowercased()
            for term in vocabularyTerms {
                if ctcSpanText.contains(term.lowercased()) {
                    vocabTermsFound.append(term)
                }
            }
            // Also check individual CTC tokens
            for token in span.ctcTokens {
                if lowerVocab.contains(token.lowercased()) {
                    if !vocabTermsFound.contains(where: { $0.lowercased() == token.lowercased() }) {
                        vocabTermsFound.append(token)
                    }
                }
            }
        }

        guard !vocabTermsFound.isEmpty else {
            return Decision(
                accepted: false,
                reason: "no custom term in changed region",
                changedSpans: diff.spans.count, changedTokens: diff.changedTokenCount,
                totalTokens: heartTokens.count, vocabTermsInChanges: []
            )
        }

        return Decision(
            accepted: true,
            reason: "accepted: \(vocabTermsFound.joined(separator: ", ")) corrected",
            changedSpans: diff.spans.count, changedTokens: diff.changedTokenCount,
            totalTokens: heartTokens.count, vocabTermsInChanges: vocabTermsFound
        )
    }

    // MARK: - Tokenization

    /// Simple whitespace tokenizer. Strips punctuation for comparison.
    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { String($0) }
    }

    // MARK: - Diff

    struct DiffSpan {
        let heartTokens: [String]
        let ctcTokens: [String]
        let heartRange: Range<Int>
    }

    struct DiffResult {
        let spans: [DiffSpan]
        let changedTokenCount: Int
    }

    /// Compute changed spans between heart and CTC token sequences.
    /// Uses a simple linear scan comparing tokens case-insensitively.
    private static func computeDiff(_ heart: [String], _ ctc: [String]) -> DiffResult {
        // LCS-based diff is overkill for short dictation. Use simple alignment:
        // Walk both sequences, find contiguous regions where they differ.
        var spans: [DiffSpan] = []
        var changedTokens = 0

        let minLen = min(heart.count, ctc.count)
        var i = 0

        while i < minLen {
            if !tokensMatch(heart[i], ctc[i]) {
                // Start of a changed span
                let spanStart = i
                var heartSpanTokens: [String] = []
                var ctcSpanTokens: [String] = []

                while i < minLen && !tokensMatch(heart[i], ctc[i]) {
                    heartSpanTokens.append(heart[i])
                    ctcSpanTokens.append(ctc[i])
                    i += 1
                }

                changedTokens += heartSpanTokens.count
                spans.append(DiffSpan(
                    heartTokens: heartSpanTokens,
                    ctcTokens: ctcSpanTokens,
                    heartRange: spanStart..<i
                ))
            } else {
                i += 1
            }
        }

        // Handle length differences as a changed span
        if heart.count != ctc.count {
            let extra = abs(heart.count - ctc.count)
            changedTokens += extra
            if heart.count > ctc.count {
                spans.append(DiffSpan(
                    heartTokens: Array(heart[minLen...]),
                    ctcTokens: [],
                    heartRange: minLen..<heart.count
                ))
            } else {
                spans.append(DiffSpan(
                    heartTokens: [],
                    ctcTokens: Array(ctc[minLen...]),
                    heartRange: minLen..<minLen
                ))
            }
        }

        return DiffResult(spans: spans, changedTokenCount: changedTokens)
    }

    /// Compare tokens, ignoring case and trailing punctuation.
    private static func tokensMatch(_ a: String, _ b: String) -> Bool {
        stripPunctuation(a).lowercased() == stripPunctuation(b).lowercased()
    }

    /// Remove trailing punctuation for comparison purposes.
    private static func stripPunctuation(_ s: String) -> String {
        var result = s
        while let last = result.last, last.isPunctuation {
            result.removeLast()
        }
        return result
    }
}
