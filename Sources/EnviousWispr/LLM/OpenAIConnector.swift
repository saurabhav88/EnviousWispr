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
        config: LLMProviderConfig,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
        let apiKey = try getAPIKey(config: config)

        let messages: [[String: String]] = [
            ["role": "system", "content": instructions.systemPrompt],
            ["role": "user", "content": text],
        ]

        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "max_completion_tokens": config.maxTokens,
            "temperature": config.temperature,
        ]
        if let reasoningEffort = config.reasoningEffort {
            body["reasoning_effort"] = reasoningEffort
        }

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await LLMNetworkSession.shared.session.data(for: request)

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

        if let finishReason = choices.first?["finish_reason"] as? String,
           finishReason == "length" {
            Task { await AppLogger.shared.log(
                "WARNING: OpenAI response truncated (finish_reason=length, model=\(config.model), max_tokens=\(config.maxTokens))",
                level: .info, category: "LLM"
            ) }
        }

        return LLMResult(
            polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines)
                .strippingLLMPreamble()
        )
    }

    private func getAPIKey(config: LLMProviderConfig) throws -> String {
        guard let keychainId = config.apiKeyKeychainId else {
            throw LLMError.invalidAPIKey
        }
        do {
            return try keychainManager.retrieve(key: keychainId)
        } catch {
            throw LLMError.invalidAPIKey
        }
    }
}
