import Foundation

/// Protocol for LLM-based transcript polishing.
protocol TranscriptPolisher: Sendable {
    /// Polish a transcript using the configured LLM provider.
    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig
    ) async throws -> LLMResult

    /// Check if the provider is reachable and the API key is valid.
    func validateCredentials(config: LLMProviderConfig) async throws -> Bool
}

/// Errors that can occur during LLM operations.
enum LLMError: LocalizedError, Sendable {
    case invalidAPIKey
    case requestFailed(String)
    case rateLimited
    case emptyResponse
    case providerUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey: return "Invalid API key."
        case .requestFailed(let msg): return "LLM request failed: \(msg)"
        case .rateLimited: return "Rate limited. Please try again later."
        case .emptyResponse: return "LLM returned an empty response."
        case .providerUnavailable: return "LLM provider is unavailable."
        }
    }
}
