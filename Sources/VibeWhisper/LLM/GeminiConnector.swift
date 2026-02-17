import Foundation

/// Google Gemini API connector for transcript polishing.
struct GeminiConnector: TranscriptPolisher {
    private let keychainManager: KeychainManager

    init(keychainManager: KeychainManager = KeychainManager()) {
        self.keychainManager = keychainManager
    }

    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig
    ) async throws -> LLMResult {
        // TODO: M3 — Implement URLSession POST to Gemini generateContent endpoint
        throw LLMError.providerUnavailable
    }

    func validateCredentials(config: LLMProviderConfig) async throws -> Bool {
        // TODO: M3 — Validate API key
        false
    }
}
