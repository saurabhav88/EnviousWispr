import EnviousWisprCore

/// Analyzes a transcript to determine the appropriate PolishMode.
/// Pure function. Deterministic heuristics, never delegated to the LLM.
public struct TranscriptAnalyzer: Sendable {

    /// Analyze transcript text and return the appropriate polish mode.
    ///
    /// Routing logic (from eval-validated thresholds):
    /// - <= 35 words, no list cues: .inline
    /// - <= 35 words, has list cues: .message (cues override length)
    /// - 36-110 words: .message
    /// - > 70 words AND has list cues: .structured (cues lower the threshold)
    /// - > 110 words: .structured
    ///
    /// Conservative nil-app routing: when appName is nil, bias toward .message,
    /// never produce .structured without strong signals.
    public static func analyzeMode(
        transcript: String,
        appName: String?
    ) -> PolishMode {
        let wordCount = transcript.split(whereSeparator: \.isWhitespace).count
        let hasListCues = detectListCues(in: transcript)

        // Short text
        if wordCount <= 35 {
            if hasListCues {
                return .message
            }
            return .inline
        }

        // Medium text with list cues lowers the structured threshold
        if wordCount > 70 && hasListCues {
            if appName == nil {
                // Conservative: require both length AND cues when no app context
                return wordCount > 110 ? .structured : .message
            }
            return .structured
        }

        // Long text
        if wordCount > 110 {
            if appName == nil && !hasListCues {
                // Conservative nil-app: need cues to go structured
                return .message
            }
            return .structured
        }

        // Default medium range
        return .message
    }

    /// Detect list/structure cues in the transcript. Case-insensitive.
    ///
    /// Validated cues (eval-tested): first+second/third/finally/then/next/also/lastly,
    /// "three things"/"few things"/"couple things", "number one"/"number two",
    /// "pros and cons"/"pros are"/"cons are", "action items"/"next steps"/"to do"/"todo", "agenda".
    static func detectListCues(in text: String) -> Bool {
        let lower = text.lowercased()

        // Sequence markers: "first" paired with a continuation word
        if lower.contains("first") {
            let continuations = ["second", "third", "finally", "then", "next", "also", "lastly"]
            if continuations.contains(where: { lower.contains($0) }) {
                return true
            }
        }

        // Quantity phrases
        let quantityPhrases = [
            "three things", "few things", "couple things",
            "number one", "number two",
        ]
        if quantityPhrases.contains(where: { lower.contains($0) }) {
            return true
        }

        // Structure phrases
        let structurePhrases = [
            "pros and cons", "pros are", "cons are",
            "action items", "next steps",
            "things to do", "to do list", "to-do",
            "todo",
            "agenda",
        ]
        if structurePhrases.contains(where: { lower.contains($0) }) {
            return true
        }

        return false
    }
}
