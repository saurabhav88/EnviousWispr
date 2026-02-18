import Foundation

/// Google Gemini API connector for transcript polishing.
struct GeminiConnector: TranscriptPolisher {
    private let keychainManager: KeychainManager
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    init(keychainManager: KeychainManager = KeychainManager()) {
        self.keychainManager = keychainManager
    }

    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig
    ) async throws -> LLMResult {
        let apiKey = try getAPIKey(config: config)

        guard let url = URL(string: "\(baseURL)/\(config.model):generateContent?key=\(apiKey)") else {
            throw LLMError.requestFailed("Invalid URL for model: \(config.model)")
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": "\(instructions.systemPrompt)\n\n---\n\n\(text)"]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": config.temperature,
                "maxOutputTokens": config.maxTokens,
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let startTime = CFAbsoluteTimeGetCurrent()
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.requestFailed("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 400:
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("API_KEY_INVALID") { throw LLMError.invalidAPIKey }
            throw LLMError.requestFailed("Bad request: \(body)")
        case 429: throw LLMError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let responseText = parts.first?["text"] as? String,
              !responseText.isEmpty else {
            throw LLMError.emptyResponse
        }

        // Extract token count from usageMetadata
        let usageMetadata = json?["usageMetadata"] as? [String: Any]
        let totalTokens = usageMetadata?["totalTokenCount"] as? Int

        return LLMResult(
            originalText: text,
            polishedText: responseText.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: .gemini,
            model: config.model,
            tokensUsed: totalTokens,
            latency: elapsed
        )
    }

    func validateCredentials(config: LLMProviderConfig) async throws -> Bool {
        let apiKey = try getAPIKey(config: config)

        // List models as a lightweight health check
        guard let url = URL(string: "\(baseURL)?key=\(apiKey)") else {
            throw LLMError.requestFailed("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return httpResponse.statusCode == 200
    }

    private func getAPIKey(config: LLMProviderConfig) throws -> String {
        do {
            return try keychainManager.retrieve(key: config.apiKeyKeychainId)
        } catch {
            throw LLMError.invalidAPIKey
        }
    }
}
