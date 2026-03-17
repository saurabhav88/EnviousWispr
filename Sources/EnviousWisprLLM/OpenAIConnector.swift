import Foundation
import EnviousWisprCore

/// OpenAI Chat Completions API connector for transcript polishing.
public struct OpenAIConnector: TranscriptPolisher {
    private let keychainManager: KeychainManager
    private let baseURL = "https://api.openai.com/v1/chat/completions"

    public init(keychainManager: KeychainManager = KeychainManager()) {
        self.keychainManager = keychainManager
    }

    public func polish(
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

        guard let url = URL(string: baseURL) else {
            throw LLMError.requestFailed("Invalid OpenAI URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, httpResponse) = try await performWithRetry(request: request, config: config)

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

    // MARK: - Retry

    private func performWithRetry(
        request: URLRequest,
        config: LLMProviderConfig,
        maxRetries: Int = LLMRetryPolicy.defaultMaxRetries,
        delays: [UInt64] = LLMRetryPolicy.defaultDelays
    ) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?
        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delay = delays[min(attempt - 1, delays.count - 1)]
                Task { await AppLogger.shared.log(
                    "OpenAI retry \(attempt)/\(maxRetries) after \(delay / 1_000_000_000)s (model=\(config.model))",
                    level: .verbose, category: "LLM"
                ) }
                try await Task.sleep(nanoseconds: delay)
            }

            do {
                let (data, response) = try await LLMNetworkSession.shared.session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw LLMError.requestFailed("Invalid response")
                }
                switch httpResponse.statusCode {
                case 200:
                    return (data, httpResponse)
                case 401:
                    throw LLMError.invalidAPIKey
                case 429:
                    throw LLMError.rateLimited
                default:
                    #if DEBUG
                    let body = String(data: data, encoding: .utf8) ?? ""
                    let truncated = String(body.prefix(200))
                    Task { await AppLogger.shared.log(
                        "OpenAI HTTP \(httpResponse.statusCode): \(truncated)",
                        level: .verbose, category: "LLM"
                    ) }
                    #else
                    Task { await AppLogger.shared.log(
                        "OpenAI HTTP \(httpResponse.statusCode)",
                        level: .verbose, category: "LLM"
                    ) }
                    #endif
                    throw LLMError.requestFailed(Self.friendlyMessage(for: httpResponse.statusCode))
                }
            } catch {
                lastError = error
                if !LLMRetryPolicy.isRetryable(error) { throw error }
            }
        }
        throw lastError!
    }

    private static func friendlyMessage(for statusCode: Int) -> String {
        switch statusCode {
        case 400: return "OpenAI rejected the request. Check model name and parameters."
        case 403: return "OpenAI access denied. Check your API key permissions."
        case 404: return "OpenAI model not found. Verify the model name in settings."
        case 500...599: return "OpenAI server error (HTTP \(statusCode)). Try again shortly."
        default: return "OpenAI request failed (HTTP \(statusCode))."
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
