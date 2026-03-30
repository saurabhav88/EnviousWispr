import EnviousWisprCore
import Foundation

/// Decides whether a CTC rescore result should replace the heart transcript.
///
/// CTC runs a full batch re-transcription with vocabulary boosting. This means
/// it can change ANY part of the text, not just custom vocabulary matches.
/// The acceptance gate filters out broad rewrites and only accepts narrow,
/// vocabulary-related corrections.
///
/// Rules (all must pass for structural changes):
/// 1. At least one custom term appears in or adjacent to a changed region
/// 2. Total token edits are small (max 4 changed heart tokens)
/// 3. Changes are localized (max 2 changed spans)
/// 4. No broad rewrite (>40% of tokens changed)
/// 5. Utterance not too short (min 3 tokens in heart)
///
/// Special path for casing-only corrections:
/// If the only differences are casing and they match vocab canonicals, accept.
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
            return reject("utterance too short (\(heartTokens.count) tokens)", heartTokens: heartTokens)
        }

        // Fast path: texts are identical (case-insensitive + punctuation-stripped)
        if normalizedEqual(heartText, ctcText) {
            // Check for casing-only corrections that match vocab canonicals
            return evaluateCasingOnly(
                heartTokens: heartTokens,
                ctcTokens: ctcTokens,
                vocabularyTerms: vocabularyTerms
            )
        }

        // Compute merge-aware token diff
        let diff = computeMergeAwareDiff(heartTokens, ctcTokens)

        // Rule 4: no broad rewrite
        let changeRatio = Double(diff.changedHeartTokens) / Double(max(heartTokens.count, 1))
        guard changeRatio <= 0.40 else {
            return reject(
                "broad rewrite (\(Int(changeRatio * 100))% changed)",
                spans: diff.spans.count, changed: diff.changedHeartTokens, total: heartTokens.count
            )
        }

        // Rule 2: max changed tokens
        guard diff.changedHeartTokens <= 4 else {
            return reject(
                "too many changed tokens (\(diff.changedHeartTokens))",
                spans: diff.spans.count, changed: diff.changedHeartTokens, total: heartTokens.count
            )
        }

        // Rule 3: max changed spans
        guard diff.spans.count <= 2 else {
            return reject(
                "too many changed spans (\(diff.spans.count))",
                spans: diff.spans.count, changed: diff.changedHeartTokens, total: heartTokens.count
            )
        }

        // Rule 1: at least one custom term in or adjacent to a changed region
        let vocabTermsFound = findVocabTermsInChanges(
            diff: diff,
            ctcTokens: ctcTokens,
            vocabularyTerms: vocabularyTerms
        )

        guard !vocabTermsFound.isEmpty else {
            return reject(
                "no custom term in changed region",
                spans: diff.spans.count, changed: diff.changedHeartTokens, total: heartTokens.count
            )
        }

        return Decision(
            accepted: true,
            reason: "accepted: \(vocabTermsFound.joined(separator: ", ")) corrected",
            changedSpans: diff.spans.count,
            changedTokens: diff.changedHeartTokens,
            totalTokens: heartTokens.count,
            vocabTermsInChanges: vocabTermsFound
        )
    }

    // MARK: - Casing-Only Path

    /// Handle the case where heart and CTC differ only in casing.
    /// Accept if the casing change matches a vocabulary term's canonical form.
    private static func evaluateCasingOnly(
        heartTokens: [String],
        ctcTokens: [String],
        vocabularyTerms: [String]
    ) -> Decision {
        guard heartTokens.count == ctcTokens.count else {
            return reject("casing check: token count mismatch", heartTokens: heartTokens)
        }

        // Build a set of canonical forms for fast lookup
        let canonicalSet = Set(vocabularyTerms)
        var casingFixTerms: [String] = []

        for i in 0..<heartTokens.count {
            let h = stripPunctuation(heartTokens[i])
            let c = stripPunctuation(ctcTokens[i])
            if h != c && h.lowercased() == c.lowercased() {
                // Casing differs. Check if the CTC version matches a canonical.
                if canonicalSet.contains(c) || canonicalSet.contains(ctcTokens[i]) {
                    casingFixTerms.append(c)
                }
                // Also check multi-token: build a window around this position
                let window = buildWindow(ctcTokens, around: i, size: 3)
                for term in vocabularyTerms {
                    if window.lowercased().contains(term.lowercased())
                        && !casingFixTerms.contains(where: { $0.lowercased() == term.lowercased() })
                    {
                        casingFixTerms.append(term)
                    }
                }
            }
        }

        if !casingFixTerms.isEmpty {
            return Decision(
                accepted: true,
                reason: "accepted: casing corrected for \(casingFixTerms.joined(separator: ", "))",
                changedSpans: casingFixTerms.count,
                changedTokens: casingFixTerms.count,
                totalTokens: heartTokens.count,
                vocabTermsInChanges: casingFixTerms
            )
        }

        return reject("casing differs but no vocab match", heartTokens: heartTokens)
    }

    // MARK: - Vocab Term Detection

    /// Find vocabulary terms in or adjacent to changed spans.
    /// Checks: span text, individual tokens, and a context window around each span.
    private static func findVocabTermsInChanges(
        diff: DiffResult,
        ctcTokens: [String],
        vocabularyTerms: [String]
    ) -> [String] {
        var found: [String] = []
        let lowerVocab = Set(vocabularyTerms.map { $0.lowercased() })

        for span in diff.spans {
            // Build a context window: span tokens + 1 adjacent token on each side
            let windowStart = max(0, span.ctcRange.lowerBound - 1)
            let windowEnd = min(ctcTokens.count, span.ctcRange.upperBound + 1)
            let windowTokens = Array(ctcTokens[windowStart..<windowEnd])
            let windowText = windowTokens.joined(separator: " ").lowercased()

            // Check multi-token terms against the window
            for term in vocabularyTerms {
                let lowerTerm = term.lowercased()
                if windowText.contains(lowerTerm) {
                    if !found.contains(where: { $0.lowercased() == lowerTerm }) {
                        found.append(term)
                    }
                }
            }

            // Check individual CTC span tokens
            for token in span.ctcTokens {
                let stripped = stripPunctuation(token).lowercased()
                if lowerVocab.contains(stripped) {
                    if !found.contains(where: { $0.lowercased() == stripped }) {
                        found.append(token)
                    }
                }
            }

            // Check concatenated span tokens (handles compound merges like ChatGPT)
            let concatenated = span.ctcTokens.joined().lowercased()
            for term in vocabularyTerms {
                let lowerTerm = term.lowercased()
                if concatenated == lowerTerm || concatenated.contains(lowerTerm) {
                    if !found.contains(where: { $0.lowercased() == lowerTerm }) {
                        found.append(term)
                    }
                }
            }
        }

        return found
    }

    // MARK: - Tokenization

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { String($0) }
    }

    // MARK: - Merge-Aware Diff

    struct DiffSpan {
        let heartTokens: [String]
        let ctcTokens: [String]
        let heartRange: Range<Int>
        let ctcRange: Range<Int>
    }

    struct DiffResult {
        let spans: [DiffSpan]
        let changedHeartTokens: Int
    }

    /// Compute changed spans with awareness of token merges/splits.
    ///
    /// Strategy: use greedy matching with merge detection.
    /// When tokens don't match at position (i,j), check if:
    /// - Merging heart[i]+heart[i+1] matches ctc[j] (split -> merge)
    /// - Merging ctc[j]+ctc[j+1] matches heart[i] (merge -> split)
    /// This handles "chat GPT" <-> "ChatGPT" type changes.
    private static func computeMergeAwareDiff(_ heart: [String], _ ctc: [String]) -> DiffResult {
        var spans: [DiffSpan] = []
        var changedHeartTokens = 0
        var hi = 0  // heart index
        var ci = 0  // ctc index

        while hi < heart.count && ci < ctc.count {
            if tokensMatch(heart[hi], ctc[ci]) {
                hi += 1
                ci += 1
                continue
            }

            // Mismatch: try to find the extent of the changed region
            let spanStartH = hi
            let spanStartC = ci

            // Check for merge: heart[hi]+heart[hi+1] matches ctc[ci]
            if hi + 1 < heart.count && mergeMatches(heart[hi], heart[hi + 1], ctc[ci]) {
                // Two heart tokens merged into one CTC token
                spans.append(DiffSpan(
                    heartTokens: [heart[hi], heart[hi + 1]],
                    ctcTokens: [ctc[ci]],
                    heartRange: hi..<(hi + 2),
                    ctcRange: ci..<(ci + 1)
                ))
                changedHeartTokens += 2
                hi += 2
                ci += 1
                continue
            }

            // Check for split: heart[hi] matches ctc[ci]+ctc[ci+1]
            if ci + 1 < ctc.count && mergeMatches(ctc[ci], ctc[ci + 1], heart[hi]) {
                // One heart token split into two CTC tokens
                spans.append(DiffSpan(
                    heartTokens: [heart[hi]],
                    ctcTokens: [ctc[ci], ctc[ci + 1]],
                    heartRange: hi..<(hi + 1),
                    ctcRange: ci..<(ci + 2)
                ))
                changedHeartTokens += 1
                hi += 1
                ci += 2
                continue
            }

            // Simple substitution: advance both until we find a match again
            var heartSpan: [String] = []
            var ctcSpan: [String] = []

            while hi < heart.count && ci < ctc.count && !tokensMatch(heart[hi], ctc[ci]) {
                // Check if advancing heart by 1 realigns
                if hi + 1 < heart.count && tokensMatch(heart[hi + 1], ctc[ci]) {
                    heartSpan.append(heart[hi])
                    hi += 1
                    break
                }
                // Check if advancing ctc by 1 realigns
                if ci + 1 < ctc.count && tokensMatch(heart[hi], ctc[ci + 1]) {
                    ctcSpan.append(ctc[ci])
                    ci += 1
                    break
                }
                // Neither realigns: both differ
                heartSpan.append(heart[hi])
                ctcSpan.append(ctc[ci])
                hi += 1
                ci += 1
            }

            if !heartSpan.isEmpty || !ctcSpan.isEmpty {
                changedHeartTokens += heartSpan.count
                spans.append(DiffSpan(
                    heartTokens: heartSpan,
                    ctcTokens: ctcSpan,
                    heartRange: spanStartH..<hi,
                    ctcRange: spanStartC..<ci
                ))
            }
        }

        // Handle remaining tokens
        if hi < heart.count {
            changedHeartTokens += heart.count - hi
            spans.append(DiffSpan(
                heartTokens: Array(heart[hi...]),
                ctcTokens: [],
                heartRange: hi..<heart.count,
                ctcRange: ci..<ci
            ))
        }
        if ci < ctc.count {
            spans.append(DiffSpan(
                heartTokens: [],
                ctcTokens: Array(ctc[ci...]),
                heartRange: hi..<hi,
                ctcRange: ci..<ctc.count
            ))
        }

        return DiffResult(spans: spans, changedHeartTokens: changedHeartTokens)
    }

    // MARK: - Token Comparison

    /// Compare tokens ignoring case and trailing punctuation.
    private static func tokensMatch(_ a: String, _ b: String) -> Bool {
        stripPunctuation(a).lowercased() == stripPunctuation(b).lowercased()
    }

    /// Check if concatenating two tokens (ignoring space/case) matches a third.
    /// Handles "chat" + "GPT" matching "ChatGPT".
    private static func mergeMatches(_ a: String, _ b: String, _ merged: String) -> Bool {
        let ab = stripPunctuation(a) + stripPunctuation(b)
        return ab.lowercased() == stripPunctuation(merged).lowercased()
    }

    /// Check if two texts are equal after normalization (case + punctuation).
    private static func normalizedEqual(_ a: String, _ b: String) -> Bool {
        let aNorm = a.lowercased().filter { !$0.isPunctuation }
        let bNorm = b.lowercased().filter { !$0.isPunctuation }
        return aNorm == bNorm
    }

    /// Remove trailing punctuation for comparison.
    private static func stripPunctuation(_ s: String) -> String {
        var result = s
        while let last = result.last, last.isPunctuation {
            result.removeLast()
        }
        return result
    }

    /// Build a text window around an index in a token array.
    private static func buildWindow(_ tokens: [String], around index: Int, size: Int) -> String {
        let start = max(0, index - size / 2)
        let end = min(tokens.count, index + size / 2 + 1)
        return tokens[start..<end].joined(separator: " ")
    }

    // MARK: - Helpers

    private static func reject(
        _ reason: String,
        spans: Int = 0,
        changed: Int = 0,
        total: Int = 0
    ) -> Decision {
        Decision(
            accepted: false, reason: reason,
            changedSpans: spans, changedTokens: changed,
            totalTokens: total, vocabTermsInChanges: []
        )
    }

    private static func reject(_ reason: String, heartTokens: [String]) -> Decision {
        reject(reason, total: heartTokens.count)
    }
}
