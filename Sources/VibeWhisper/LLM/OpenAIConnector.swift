import Foundation

/// OpenAI Chat Completions API connector for transcript polishing.
struct OpenAIConnector: TranscriptPolisher {
    private let keychainManager: KeychainManager

    init(keychainManager: KeychainManager = KeychainManager()) {
        self.keychainManager = keychainManager
    }

    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig
    ) async throws -> LLMResult {
        // TODO: M3 — Implement URLSession POST to /v1/chat/completions
        throw LLMError.providerUnavailable
    }

    func validateCredentials(config: LLMProviderConfig) async throws -> Bool {
        // TODO: M3 — Validate API key with a lightweight API call
        false
    }
}
