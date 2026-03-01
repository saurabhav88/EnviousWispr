import Foundation

/// Ollama local LLM connector. Uses Ollama's OpenAI-compatible endpoint.
/// Requires Ollama to be running: https://ollama.com
struct OllamaConnector: TranscriptPolisher {
    private let baseURL: String

    /// Simplified prompt for weak/small models that struggle with complex instructions.
    private static let weakModelSystemPrompt = "Fix grammar and punctuation. Return only the corrected text."

    init(baseURL: String = "http://localhost:11434") {
        self.baseURL = baseURL
    }

    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
        let endpointURL = "\(baseURL)/v1/chat/completions"
        guard let url = URL(string: endpointURL) else {
            throw LLMError.requestFailed("Invalid Ollama URL: \(endpointURL)")
        }

        // Use a simplified prompt for weak/small models; full prompt for capable models.
        let systemPrompt = OllamaSetupService.isWeakModel(config.model)
            ? Self.weakModelSystemPrompt
            : instructions.systemPrompt

        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
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

        let (data, _) = try await performWithRetry(request: request, config: config)

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
                "WARNING: Ollama response truncated (finish_reason=length, model=\(config.model), max_tokens=\(config.maxTokens))",
                level: .info, category: "LLM"
            ) }
        }

        return LLMResult(
            polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines)
                .strippingLLMPreamble()
        )
    }

    // MARK: - Retry

    private func performWithRetry(
        request: URLRequest,
        config: LLMProviderConfig,
        maxRetries: Int = 2,
        delays: [UInt64] = [1_000_000_000, 3_000_000_000]
    ) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?
        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delay = delays[min(attempt - 1, delays.count - 1)]
                Task { await AppLogger.shared.log(
                    "Ollama retry \(attempt)/\(maxRetries) after \(delay / 1_000_000_000)s (model=\(config.model))",
                    level: .verbose, category: "LLM"
                ) }
                try await Task.sleep(nanoseconds: delay)
            }

            do {
                let (data, response): (Data, URLResponse)
                do {
                    (data, response) = try await LLMNetworkSession.shared.session.data(for: request)
                } catch let urlError as URLError {
                    switch urlError.code {
                    case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet:
                        throw LLMError.providerUnavailable
                    case .timedOut, .networkConnectionLost:
                        throw urlError  // retryable — will be caught below
                    default:
                        throw LLMError.requestFailed("Network error: \(urlError.localizedDescription)")
                    }
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw LLMError.requestFailed("Invalid response")
                }

                switch httpResponse.statusCode {
                case 200:
                    return (data, httpResponse)
                case 404:
                    throw LLMError.modelNotFound(config.model)
                default:
                    let body = String(data: data, encoding: .utf8) ?? ""
                    let truncated = String(body.prefix(200))
                    Task { await AppLogger.shared.log(
                        "Ollama HTTP \(httpResponse.statusCode): \(truncated)",
                        level: .verbose, category: "LLM"
                    ) }
                    throw LLMError.requestFailed(Self.friendlyMessage(for: httpResponse.statusCode))
                }
            } catch {
                lastError = error
                if !Self.isRetryable(error) { throw error }
            }
        }
        throw lastError!
    }

    private static func friendlyMessage(for statusCode: Int) -> String {
        switch statusCode {
        case 400: return "Ollama rejected the request. Check model name and parameters."
        case 500...599: return "Ollama server error (HTTP \(statusCode)). Try restarting Ollama."
        default: return "Ollama request failed (HTTP \(statusCode))."
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let llmError = error as? LLMError {
            switch llmError {
            case .rateLimited: return true
            case .requestFailed(let msg):
                return msg.contains("server error")
            default: return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost:
                return true
            default: return false
            }
        }
        return false
    }
}
