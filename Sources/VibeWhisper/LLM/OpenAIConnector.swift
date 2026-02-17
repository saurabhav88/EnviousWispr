import Foundation

/// OpenAI Chat Completions API connector for transcript polishing.
struct OpenAIConnector: TranscriptPolisher {
    private let keychainManager: KeychainManager
    private let baseURL = "https://api.openai.com/v1/chat/completions"

    init(keychainManager: KeychainManager = KeychainManager()) {
        self.keychainManager = keychainManager
    }

    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig
    ) async throws -> LLMResult {
        let apiKey = try getAPIKey(config: config)

        let messages: [[String: String]] = [
            ["role": "system", "content": instructions.systemPrompt],
            ["role": "user", "content": text],
        ]

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
        ]

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        case 401: throw LLMError.invalidAPIKey
        case 429: throw LLMError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else {
            throw LLMError.emptyResponse
        }

        let usage = json?["usage"] as? [String: Any]
        let totalTokens = usage?["total_tokens"] as? Int

        return LLMResult(
            originalText: text,
            polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: .openAI,
            model: config.model,
            tokensUsed: totalTokens,
            latency: elapsed
        )
    }

    func validateCredentials(config: LLMProviderConfig) async throws -> Bool {
        let apiKey = try getAPIKey(config: config)

        // Use the models endpoint as a lightweight health check
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
