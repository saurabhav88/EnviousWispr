import Foundation

extension CustomWord {
    /// Render a list of custom words for injection into LLM/FM prompts.
    ///
    /// Sorts by priority (lower value = higher priority), truncates to `max`,
    /// and applies render-time sanitization (trim + strip newlines + collapse whitespace).
    /// Never mutates stored CustomWord values.
    static func renderForPrompt(_ words: [CustomWord], max: Int = 50) -> String {
        guard !words.isEmpty else { return "" }

        // Lower value = higher priority
        let sorted = words.sorted { ($0.priority, $0.canonical) < ($1.priority, $1.canonical) }
        let truncated = Array(sorted.prefix(max))

        if words.count > max {
            Task { @MainActor in
                await AppLogger.shared.log(
                    "Custom word list truncated from \(words.count) to \(max) for prompt injection",
                    level: .info, category: "CustomWords"
                )
            }
        }

        let lines = truncated.map { word -> String in
            let clean = sanitize(word.canonical)
            if word.aliases.isEmpty {
                return "- \(clean)"
            } else {
                let cleanAliases = word.aliases.map { sanitize($0) }.joined(separator: ", ")
                return "- \(clean) (may be misheard as: \(cleanAliases))"
            }
        }

        return """
            --- BEGIN CUSTOM WORDS ---
            \(lines.joined(separator: "\n"))
            --- END CUSTOM WORDS ---
            """
    }

    /// Render-time sanitization: trim + strip newlines + collapse whitespace.
    /// Never mutates stored values.
    private static func sanitize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
    }
}
