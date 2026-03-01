import Foundation

/// Protocol for LLM-based transcript polishing.
protocol TranscriptPolisher: Sendable {
    /// Polish a transcript using the configured LLM provider.
    /// - Parameters:
    ///   - onToken: Optional streaming callback invoked with each text fragment as it arrives.
    ///              Pass `nil` for batch (non-streaming) behavior.
    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult
}

extension TranscriptPolisher {
    /// Convenience overload without streaming callback — preserves backward compatibility.
    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig
    ) async throws -> LLMResult {
        try await polish(text: text, instructions: instructions, config: config, onToken: nil)
    }
}

// MARK: - Preamble Stripping

extension String {
    /// Strip common LLM preamble/acknowledgment patterns from polished transcript output.
    ///
    /// Strategy:
    /// 1. Strip a leading single-word/phrase acknowledgment (e.g. "Certainly!", "Sure,", "Got it.")
    /// 2. If the (remaining) first line is short (<100 chars) and ends with ":", treat it as a
    ///    preamble line (e.g. "Here is the corrected version of the speech transcript:") and strip it.
    func strippingLLMPreamble() -> String {
        var result = self.trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 1: Strip a leading acknowledgment word/phrase if present.
        let acknowledgments = [
            "Certainly!",
            "Sure!",
            "Sure,",
            "Of course!",
            "Got it.",
            "Got it!",
            "Absolutely!",
            "Here you go:",
        ]
        for ack in acknowledgments {
            if result.hasPrefix(ack) {
                result = String(result.dropFirst(ack.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // Step 2: If the first line is short and ends with ":", it's likely a preamble line.
        // e.g. "Here is the corrected version of the speech transcript:"
        // Also catches "Here's the cleaned-up transcript:" etc.
        let firstNewline = result.firstIndex(of: "\n") ?? result.endIndex
        let firstLine = result[result.startIndex..<firstNewline]
        if firstLine.count < 100,
           firstLine.hasSuffix(":"),
           !firstLine.isEmpty {
            // Additional guard: only strip if it looks like a preamble, not legitimate content.
            // Preamble lines typically start with "Here" or are very short introductions.
            let trimmedFirst = firstLine.trimmingCharacters(in: .whitespaces).lowercased()
            let isPreambleLike = trimmedFirst.hasPrefix("here")
                || trimmedFirst.hasPrefix("below")
                || trimmedFirst.hasPrefix("the corrected")
                || trimmedFirst.hasPrefix("the cleaned")
                || trimmedFirst.hasPrefix("the polished")
                || trimmedFirst.hasPrefix("the rewritten")
                || trimmedFirst.hasPrefix("corrected version")
                || trimmedFirst.hasPrefix("cleaned")
                || trimmedFirst.hasPrefix("polished")
            if isPreambleLike {
                result = String(result[firstNewline...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return result
    }
}

/// Errors that can occur during LLM operations.
enum LLMError: LocalizedError, Sendable, Equatable {
    case invalidAPIKey
    case requestFailed(String)
    case rateLimited
    case emptyResponse
    case providerUnavailable
    case modelNotFound(String)
    case frameworkUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "Invalid API key."
        case .requestFailed(let msg): return "LLM request failed: \(msg)"
        case .rateLimited: return "Rate limited. Please try again later."
        case .emptyResponse: return "LLM returned an empty response."
        case .providerUnavailable: return "LLM provider is unavailable."
        case .modelNotFound(let model):
            return "Ollama model '\(model)' is not pulled. Run: ollama pull \(model)"
        case .frameworkUnavailable:
            return "Apple Intelligence requires macOS 26+ with Apple Intelligence support."
        }
    }

    static func == (lhs: LLMError, rhs: LLMError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidAPIKey, .invalidAPIKey),
             (.rateLimited, .rateLimited),
             (.emptyResponse, .emptyResponse),
             (.providerUnavailable, .providerUnavailable),
             (.frameworkUnavailable, .frameworkUnavailable):
            return true
        case (.requestFailed(let a), .requestFailed(let b)),
             (.modelNotFound(let a), .modelNotFound(let b)):
            return a == b
        default:
            return false
        }
    }
}
