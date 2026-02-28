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

        guard let url = URL(string: "\(baseURL)/\(config.model):generateContent") else {
            throw LLMError.requestFailed("Invalid URL for model: \(config.model)")
        }

        // Use systemInstruction for the system prompt so Flash models follow
        // instructions precisely rather than treating the combined message as a
        // summarization task.
        var body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": instructions.systemPrompt]]
            ],
            "generationConfig": [
                "temperature": config.temperature,
                "maxOutputTokens": config.maxTokens,
            ],
        ]

        // When ${transcript} placeholder is used, LLMPolishStep resolves the full
        // prompt into systemPrompt and passes text as "". In that case we send a
        // minimal contents array; otherwise the transcript goes in contents.
        if text.isEmpty {
            body["contents"] = [["parts": [["text": " "]]]]
        } else {
            body["contents"] = [["parts": [["text": text]]]]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.requestFailed("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 400:
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            if responseBody.contains("API_KEY_INVALID") { throw LLMError.invalidAPIKey }
            throw LLMError.requestFailed("Bad request: \(responseBody)")
        case 403: throw LLMError.invalidAPIKey
        case 429: throw LLMError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let responseText = parts.first?["text"] as? String,
              !responseText.isEmpty else {
            throw LLMError.emptyResponse
        }

        // Detect output truncation so we can diagnose incomplete polishing
        if let finishReason = firstCandidate["finishReason"] as? String,
           finishReason == "MAX_TOKENS" {
            Task { await AppLogger.shared.log(
                "WARNING: Gemini response truncated (finishReason=MAX_TOKENS, model=\(config.model), maxOutputTokens=\(config.maxTokens))",
                level: .info, category: "LLM"
            ) }
        }

        return LLMResult(
            polishedText: responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                .strippingLLMPreamble(),
            provider: .gemini,
            model: config.model
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
