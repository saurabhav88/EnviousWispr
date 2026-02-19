import Foundation

/// Ollama local LLM connector. Uses Ollama's OpenAI-compatible endpoint.
/// Requires Ollama to be running: https://ollama.com
struct OllamaConnector: TranscriptPolisher {
    private let baseURL: String

    init(baseURL: String = "http://localhost:11434") {
        self.baseURL = baseURL
    }

    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig
    ) async throws -> LLMResult {
        let endpointURL = "\(baseURL)/v1/chat/completions"
        guard let url = URL(string: endpointURL) else {
            throw LLMError.requestFailed("Invalid Ollama URL: \(endpointURL)")
        }

        var messages: [[String: String]] = [
            ["role": "system", "content": instructions.systemPrompt],
        ]
        if !text.isEmpty {
            messages.append(["role": "user", "content": text])
        }

        let body: [String: Any] = [
            "model":       config.model,
            "messages":    messages,
            "max_tokens":  config.maxTokens,
            "temperature": config.temperature,
            "stream":      false,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .cannotConnectToHost, .timedOut, .cannotFindHost,
                 .networkConnectionLost, .notConnectedToInternet:
                throw LLMError.providerUnavailable
            default:
                throw LLMError.requestFailed("Network error: \(urlError.localizedDescription)")
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.requestFailed("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 404:
            throw LLMError.modelNotFound(config.model)
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

        return LLMResult(
            polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: .ollama,
            model: config.model
        )
    }
}
