import Foundation
import EnviousWisprCore

/// Ollama local LLM connector. Uses Ollama's native /api/chat endpoint
/// for access to `think`, `keep_alive`, and timing telemetry.
/// Requires Ollama to be running: https://ollama.com
public struct OllamaConnector: TranscriptPolisher {
    private let baseURL: String

    /// Simplified prompt for weak/small models that struggle with complex instructions.
    private static let weakModelSystemPrompt = "Fix grammar and punctuation. Return only the corrected text."

    public init(baseURL: String = "http://localhost:11434") {
        self.baseURL = baseURL
    }

    public func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
        let endpointURL = "\(baseURL)/api/chat"
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

        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": false,
            "think": false,
            "keep_alive": "60m",
            "options": [
                "num_predict": config.maxTokens,
                "temperature": config.temperature,
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, _) = try await performWithRetry(request: request, config: config)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let message = json?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else {
            throw LLMError.emptyResponse
        }

        // Log timing telemetry for observability
        if let loadNs = json?["load_duration"] as? Int64,
           let promptNs = json?["prompt_eval_duration"] as? Int64,
           let evalNs = json?["eval_duration"] as? Int64,
           let evalCount = json?["eval_count"] as? Int {
            let loadMs = Double(loadNs) / 1_000_000
            let promptMs = Double(promptNs) / 1_000_000
            let evalMs = Double(evalNs) / 1_000_000
            Task { await AppLogger.shared.log(
                "Ollama timing: load=\(String(format: "%.0f", loadMs))ms prompt=\(String(format: "%.0f", promptMs))ms eval=\(String(format: "%.0f", evalMs))ms tokens=\(evalCount) (model=\(config.model))",
                level: .verbose, category: "LLM"
            ) }
        }

        // Check for truncation via done_reason
        if let doneReason = json?["done_reason"] as? String, doneReason != "stop" {
            Task { await AppLogger.shared.log(
                "WARNING: Ollama response truncated (done_reason=\(doneReason), model=\(config.model))",
                level: .info, category: "LLM"
            ) }
        }

        return LLMResult(
            polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines)
                .strippingLLMPreamble()
        )
    }

    public func polish(
        envelope: PromptEnvelope,
        config: LLMProviderConfig,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
        // Ollama supports the full messages array (needed for Gemma few-shot).
        // Map PromptEnvelope roles directly to Ollama API roles.
        let messages: [[String: String]] = envelope.messages.map { msg in
            let role: String
            switch msg.role {
            case .system: role = "system"
            case .user: role = "user"
            case .assistant: role = "assistant"
            }
            return ["role": role, "content": msg.content]
        }

        let endpointURL = "\(baseURL)/api/chat"
        guard let url = URL(string: endpointURL) else {
            throw LLMError.requestFailed("Invalid Ollama URL: \(endpointURL)")
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "stream": false,
            "think": false,
            "keep_alive": "60m",
            "options": [
                "num_predict": config.maxTokens,
                "temperature": config.temperature,
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, _) = try await performWithRetry(request: request, config: config)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let message = json?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty
        else {
            throw LLMError.emptyResponse
        }

        if let doneReason = json?["done_reason"] as? String, doneReason != "stop" {
            Task {
                await AppLogger.shared.log(
                    "WARNING: Ollama response truncated (done_reason=\(doneReason), model=\(config.model))",
                    level: .info, category: "LLM"
                )
            }
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
                    case .notConnectedToInternet, .cannotFindHost:
                        throw LLMError.providerUnavailable  // not transient, fail fast
                    default:
                        throw urlError  // let LLMRetryPolicy.isRetryable() decide
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
                    #if DEBUG
                    let body = String(data: data, encoding: .utf8) ?? ""
                    let truncated = String(body.prefix(200))
                    Task { await AppLogger.shared.log(
                        "Ollama HTTP \(httpResponse.statusCode): \(truncated)",
                        level: .verbose, category: "LLM"
                    ) }
                    #else
                    Task { await AppLogger.shared.log(
                        "Ollama HTTP \(httpResponse.statusCode)",
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
        // Convert exhausted connection errors to domain error for UI
        if let urlError = lastError as? URLError, urlError.code == .cannotConnectToHost {
            throw LLMError.providerUnavailable
        }
        throw lastError ?? LLMError.requestFailed("All retries exhausted")
    }

    private static func friendlyMessage(for statusCode: Int) -> String {
        switch statusCode {
        case 400: return "Ollama rejected the request. Check model name and parameters."
        case 500...599: return "Ollama server error (HTTP \(statusCode)). Try restarting Ollama."
        default: return "Ollama request failed (HTTP \(statusCode))."
        }
    }
}
