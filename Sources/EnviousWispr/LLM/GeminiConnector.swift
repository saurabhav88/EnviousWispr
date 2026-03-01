import Foundation

/// Google Gemini API connector for transcript polishing.
/// Uses Server-Sent Events (SSE) streaming for lower perceived latency.
struct GeminiConnector: TranscriptPolisher {
    private let keychainManager: KeychainManager
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

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

        // Use streaming endpoint when onToken callback is provided, batch otherwise
        let endpoint = onToken != nil ? "streamGenerateContent?alt=sse" : "generateContent"
        guard let url = URL(string: "\(baseURL)/\(config.model):\(endpoint)") else {
            throw LLMError.requestFailed("Invalid URL for model: \(config.model)")
        }

        // Use systemInstruction for the system prompt so Flash models follow
        // instructions precisely rather than treating the combined message as a
        // summarization task.
        var generationConfig: [String: Any] = [
            "temperature": config.temperature,
            "maxOutputTokens": config.maxTokens,
        ]
        if let budget = config.thinkingBudget {
            generationConfig["thinkingConfig"] = ["thinkingBudget": budget]
        }

        var body: [String: Any] = [
            "systemInstruction": [
                "parts": [["text": instructions.systemPrompt]]
            ],
            "generationConfig": generationConfig,
        ]

        // When ${transcript} placeholder is used, LLMPolishStep resolves the full
        // prompt into systemPrompt and passes text as "". In that case we send a
        // minimal contents array; otherwise the transcript goes in contents.
        if text.isEmpty {
            body["contents"] = [["parts": [["text": "Polish the transcript per the system instructions."]]]]
        } else {
            body["contents"] = [["parts": [["text": text]]]]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        if let onToken {
            return try await polishStreaming(request: request, config: config, onToken: onToken)
        } else {
            return try await polishBatch(request: request, config: config)
        }
    }

    // MARK: - SSE Streaming

    private func polishStreaming(
        request: URLRequest,
        config: LLMProviderConfig,
        onToken: @Sendable (String) -> Void
    ) async throws -> LLMResult {
        let session = LLMNetworkSession.shared.session
        let (stream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.requestFailed("Invalid response")
        }

        // For streaming, non-200 means the entire response is an error body
        if httpResponse.statusCode != 200 {
            var errorBody = ""
            for try await line in stream.lines {
                errorBody += line
            }
            try handleHTTPError(statusCode: httpResponse.statusCode, body: errorBody)
        }

        var fullText = ""
        var lastFinishReason: String?

        for try await line in stream.lines {
            // SSE format: lines prefixed with "data: " contain JSON
            // Empty lines delimit events, lines starting with ":" are comments
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))

            guard let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first else {
                continue
            }

            // Extract text fragments from this chunk, skipping thought parts
            if let content = firstCandidate["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if part["thought"] as? Bool == true { continue }
                    if let textFragment = part["text"] as? String {
                        fullText += textFragment
                        onToken(textFragment)
                    }
                }
            }

            // Check finishReason — present only in the final chunk
            if let finishReason = firstCandidate["finishReason"] as? String {
                lastFinishReason = finishReason
            }
        }

        guard !fullText.isEmpty else {
            throw LLMError.emptyResponse
        }

        logTruncationIfNeeded(finishReason: lastFinishReason, config: config)

        return LLMResult(
            polishedText: fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                .strippingLLMPreamble()
        )
    }

    // MARK: - Batch (non-streaming)

    private func polishBatch(
        request: URLRequest,
        config: LLMProviderConfig
    ) async throws -> LLMResult {
        let session = LLMNetworkSession.shared.session
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.requestFailed("Invalid response")
        }

        if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            try handleHTTPError(statusCode: httpResponse.statusCode, body: body)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LLMError.emptyResponse
        }

        // Filter out thought parts and join remaining text
        let responseText = parts
            .filter { $0["thought"] as? Bool != true }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !responseText.isEmpty else {
            throw LLMError.emptyResponse
        }

        logTruncationIfNeeded(
            finishReason: firstCandidate["finishReason"] as? String,
            config: config
        )

        return LLMResult(
            polishedText: responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                .strippingLLMPreamble()
        )
    }

    // MARK: - Shared

    private func logTruncationIfNeeded(finishReason: String?, config: LLMProviderConfig) {
        guard finishReason == "MAX_TOKENS" else { return }
        Task { await AppLogger.shared.log(
            "WARNING: Gemini response truncated (finishReason=MAX_TOKENS, model=\(config.model), maxOutputTokens=\(config.maxTokens))",
            level: .info, category: "LLM"
        ) }
    }

    private func handleHTTPError(statusCode: Int, body: String) throws -> Never {
        switch statusCode {
        case 400:
            if body.contains("API_KEY_INVALID") { throw LLMError.invalidAPIKey }
            throw LLMError.requestFailed("Bad request: \(body)")
        case 403: throw LLMError.invalidAPIKey
        case 429: throw LLMError.rateLimited
        default:
            throw LLMError.requestFailed("HTTP \(statusCode): \(body)")
        }
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
