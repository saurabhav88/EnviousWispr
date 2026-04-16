import EnviousWisprCore
import Foundation

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

    return try await performWithRetry(request: request, config: config)
  }

  public func polish(
    envelope: PromptEnvelope,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    guard let pair = envelope.asSingleTurn() else {
      // Fallback: join all messages (should not happen for OpenAI)
      let text = envelope.messages.filter { $0.role == .user }.map(\.content).joined()
      let system = envelope.messages.filter { $0.role == .system }.map(\.content).joined(
        separator: "\n")
      return try await polish(
        text: text,
        instructions: PolishInstructions(systemPrompt: system),
        config: config,
        onToken: onToken
      )
    }
    return try await polish(
      text: pair.user,
      instructions: PolishInstructions(systemPrompt: pair.system ?? ""),
      config: config,
      onToken: onToken
    )
  }

  // MARK: - Retry

  private func performWithRetry(
    request: URLRequest,
    config: LLMProviderConfig,
    maxRetries: Int = LLMRetryPolicy.defaultMaxRetries,
    delays: [UInt64] = LLMRetryPolicy.defaultDelays
  ) async throws -> LLMResult {
    // Allocate the call number once per logical polish. Retries reuse the
    // same number so logs never mistake a retried polish for multiple
    // independent calls (Codex review finding P3).
    let callNumber = LLMNetworkSession.shared.nextCallNumber()
    var lastError: Error?
    for attempt in 0...maxRetries {
      if attempt > 0 {
        let delay = delays[min(attempt - 1, delays.count - 1)]
        Task {
          await AppLogger.shared.log(
            "OpenAI retry \(attempt)/\(maxRetries) after \(delay / 1_000_000_000)s (model=\(config.model))",
            level: .verbose, category: "LLM"
          )
        }
        try await Task.sleep(nanoseconds: delay)
      }

      let collector = LLMTaskMetricsCollector()
      var statusForLog = "pending"
      do {
        defer {
          let line = LLMTaskMetricsCollector.format(
            provider: "openai", model: config.model, callNumber: callNumber,
            status: statusForLog, metrics: collector.metrics
          )
          Task { await AppLogger.shared.log(line, level: .info, category: "LLM") }
        }
        let data: Data
        let response: URLResponse
        do {
          (data, response) = try await LLMNetworkSession.shared.session.data(
            for: request, delegate: collector
          )
        } catch {
          statusForLog = "error:\(Self.shortError(error))"
          throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
          statusForLog = "error:non_http_response"
          throw LLMError.requestFailed("Invalid response")
        }
        statusForLog = String(httpResponse.statusCode)
        switch httpResponse.statusCode {
        case 200:
          // Parse inside the defer scope so a malformed 200 payload
          // (e.g. content-moderation refusal, unexpected schema)
          // updates statusForLog to error_after_200 before the
          // metrics line is written (Codex GitHub review P2).
          do {
            return try Self.parseSuccess(data: data, config: config)
          } catch {
            statusForLog = "error_after_200:\(Self.shortError(error))"
            throw error
          }
        case 401:
          throw LLMError.invalidAPIKey
        case 429:
          throw LLMError.rateLimited
        default:
          #if DEBUG
            let body = String(data: data, encoding: .utf8) ?? ""
            let truncated = String(body.prefix(200))
            Task {
              await AppLogger.shared.log(
                "OpenAI HTTP \(httpResponse.statusCode): \(truncated)",
                level: .verbose, category: "LLM"
              )
            }
          #else
            Task {
              await AppLogger.shared.log(
                "OpenAI HTTP \(httpResponse.statusCode)",
                level: .verbose, category: "LLM"
              )
            }
          #endif
          throw LLMError.requestFailed(Self.friendlyMessage(for: httpResponse.statusCode))
        }
      } catch {
        if statusForLog == "pending" {
          statusForLog = "error:\(Self.shortError(error))"
        }
        lastError = error
        if !LLMRetryPolicy.isRetryable(error) { throw error }
      }
    }
    throw lastError ?? LLMError.requestFailed("All retries exhausted")
  }

  /// Parse a successful OpenAI 200 response into an LLMResult.
  /// Throws `LLMError.emptyResponse` on missing/empty content so the retry
  /// caller can mark statusForLog as error_after_200.
  private static func parseSuccess(
    data: Data, config: LLMProviderConfig
  ) throws -> LLMResult {
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let choices = json?["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String,
      !content.isEmpty
    else {
      throw LLMError.emptyResponse
    }

    if let finishReason = choices.first?["finish_reason"] as? String,
      finishReason == "length"
    {
      Task {
        await AppLogger.shared.log(
          "WARNING: OpenAI response truncated (finish_reason=length, model=\(config.model), max_tokens=\(config.maxTokens))",
          level: .info, category: "LLM"
        )
      }
    }

    return LLMResult(
      polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines)
        .strippingLLMPreamble()
    )
  }

  /// Short error token for diagnostic log lines. Mirrors GeminiConnector.shortError.
  fileprivate static func shortError(_ error: Error) -> String {
    if let urlError = error as? URLError {
      return "urlerror_\(urlError.code.rawValue)"
    }
    if error is CancellationError {
      return "cancelled"
    }
    return "\(type(of: error))"
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
