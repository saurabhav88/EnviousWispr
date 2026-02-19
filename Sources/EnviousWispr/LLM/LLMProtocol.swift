import Foundation

/// Protocol for LLM-based transcript polishing.
protocol TranscriptPolisher: Sendable {
    /// Polish a transcript using the configured LLM provider.
    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig
    ) async throws -> LLMResult
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
            return "Apple Intelligence requires macOS 26+ on Apple Silicon."
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
