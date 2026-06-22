import EnviousWisprCore
import Foundation

/// Ollama local LLM connector. Uses Ollama's native /api/chat endpoint
/// for access to `think`, `keep_alive`, and timing telemetry.
/// Requires Ollama to be running: https://ollama.com
public struct OllamaConnector: TranscriptPolisher {
  private let baseURL: String

  /// #901 test seam — the network transport for both call sites (evict + polish
  /// retry loop). Defaults to today's exact expression, so production behavior is
  /// identical. A test injects a request-counting fake to assert the empty-name
  /// evict guard makes zero calls (the old test only bounded wall-clock against a
  /// non-routable host, which a deleted guard still satisfied via fast ECONNREFUSED).
  private let networkExecutor: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  /// Simplified prompt for weak/small models that struggle with complex instructions.
  private static let weakModelSystemPrompt =
    "Fix grammar and punctuation. Return only the corrected text."

  public init(
    baseURL: String = "http://localhost:11434",
    networkExecutor: @Sendable @escaping (URLRequest) async throws -> (Data, URLResponse) = {
      try await LLMNetworkSession.shared.session.data(for: $0)
    }
  ) {
    self.baseURL = baseURL
    self.networkExecutor = networkExecutor
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
    let systemPrompt =
      OllamaSetupService.isWeakModel(config.model)
      ? Self.weakModelSystemPrompt
      : instructions.systemPrompt

    var messages: [[String: String]] = [
      ["role": "system", "content": systemPrompt]
    ]
    if !text.isEmpty {
      messages.append(["role": "user", "content": text])
    }

    let body = Self.makeRequestBody(
      model: config.model,
      messages: messages,
      maxTokens: config.maxTokens,
      temperature: config.temperature
    )

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

    Self.logTelemetry(json: json, message: message, model: config.model)

    // Check for truncation via done_reason
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

    let body = Self.makeRequestBody(
      model: config.model,
      messages: messages,
      maxTokens: config.maxTokens,
      temperature: config.temperature
    )

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

    Self.logTelemetry(json: json, message: message, model: config.model)

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

  // MARK: - Eviction (#295)

  /// Tells Ollama to unload the named model from memory immediately.
  ///
  /// Prevents dual-resident model pressure when the user swaps polish models
  /// mid-session. Ollama's default `keep_alive` holds the previous model in
  /// VRAM for its full window, which on constrained machines has disrupted
  /// CoreAudio BT audio (root cause for #286).
  ///
  /// Fire-and-forget: returns void, swallows all errors, short timeout.
  /// Uses `/api/generate` per Ollama docs — `keep_alive: 0` on `/api/chat`
  /// is not a documented unload pattern.
  public func evictModel(_ modelName: String) async {
    let endpointURL = "\(baseURL)/api/generate"
    guard !modelName.isEmpty, let url = URL(string: endpointURL) else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 3.0

    let start = Date()
    do {
      request.httpBody = try JSONSerialization.data(
        withJSONObject: Self.makeEvictRequestBody(model: modelName)
      )
      let (_, response) = try await networkExecutor(request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
      let result = (200...299).contains(status) ? "unloaded" : "error"
      await AppLogger.shared.log(
        "Ollama evict: model=\(modelName) result=\(result) http=\(status) duration_ms=\(elapsedMs)",
        level: .info, category: "LLM"
      )
    } catch {
      let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
      let reason = (error as? URLError)?.code.rawValue.description ?? "error"
      await AppLogger.shared.log(
        "Ollama evict: model=\(modelName) result=error reason=\(reason) duration_ms=\(elapsedMs)",
        level: .info, category: "LLM"
      )
    }
  }

  // MARK: - Telemetry

  /// Logs Ollama `/api/chat` timing + reasoning-output telemetry (#276).
  ///
  /// `thinking` captures the char count of `message.thinking`, which we
  /// discard but which gemma4 spends significant eval time producing. Non-
  /// thinking models (llama3.2 etc.) log `thinking=0`. Compare against
  /// `eval`/`tokens` to see what fraction of eval time was spent on
  /// reasoning vs the final answer.
  private static func logTelemetry(
    json: [String: Any]?,
    message: [String: Any],
    model: String
  ) {
    guard
      let loadNs = json?["load_duration"] as? Int64,
      let promptNs = json?["prompt_eval_duration"] as? Int64,
      let evalNs = json?["eval_duration"] as? Int64,
      let evalCount = json?["eval_count"] as? Int
    else { return }
    let loadMs = Double(loadNs) / 1_000_000
    let promptMs = Double(promptNs) / 1_000_000
    let evalMs = Double(evalNs) / 1_000_000
    let thinkingChars = (message["thinking"] as? String)?.count ?? 0
    let contentChars = (message["content"] as? String)?.count ?? 0
    Task {
      await AppLogger.shared.log(
        "Ollama timing: load=\(String(format: "%.0f", loadMs))ms prompt=\(String(format: "%.0f", promptMs))ms eval=\(String(format: "%.0f", evalMs))ms tokens=\(evalCount) thinking=\(thinkingChars)chars content=\(contentChars)chars (model=\(model))",
        level: .verbose, category: "LLM"
      )
    }
  }

  // MARK: - Request body

  /// Builds the `/api/chat` request body shared by both polish entry points.
  ///
  /// The `think` parameter is intentionally omitted (#272):
  /// - Setting `think: false` (boolean) is silently ignored by gemma4:latest and
  ///   causes reasoning to leak into `message.content` as a 5-13× expansion that
  ///   the validator rejects.
  /// - Omitting the key lets Ollama route any reasoning to `message.thinking`
  ///   (which we don't read) and deliver the clean final answer in `message.content`,
  ///   provided `num_predict` is large enough to accommodate both (see
  ///   `LLMConstants.ollamaMaxTokens`).
  /// Non-thinking models (llama3.2 etc.) are unaffected: they emit empty
  /// `message.thinking` regardless.
  /// Returns the model name iff the provider is `.ollama` and the model
  /// is non-empty; nil otherwise. Pure helper used by the settings
  /// observer to snapshot the pre-swap effective Ollama model (#295).
  public static func effectiveOllamaModel(provider: LLMProvider, model: String) -> String? {
    provider == .ollama && !model.isEmpty ? model : nil
  }

  /// Builds the `/api/generate` unload request body (#295).
  /// Uses `keep_alive: 0` with empty prompt. Some Ollama versions
  /// 400 on missing `prompt` key, so it is emitted explicitly.
  static func makeEvictRequestBody(model: String) -> [String: Any] {
    [
      "model": model,
      "prompt": "",
      "keep_alive": 0,
    ]
  }

  static func makeRequestBody(
    model: String,
    messages: [[String: String]],
    maxTokens: Int,
    temperature: Double
  ) -> [String: Any] {
    [
      "model": model,
      "messages": messages,
      "stream": false,
      "keep_alive": "60m",
      "options": [
        "num_predict": maxTokens,
        "temperature": temperature,
      ],
    ]
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
        Task {
          await AppLogger.shared.log(
            "Ollama retry \(attempt)/\(maxRetries) after \(delay / 1_000_000_000)s (model=\(config.model))",
            level: .verbose, category: "LLM"
          )
        }
        try await Task.sleep(nanoseconds: delay)
      }

      do {
        let (data, response): (Data, URLResponse)
        do {
          (data, response) = try await networkExecutor(request)
        } catch let urlError as URLError {
          switch urlError.code {
          case .notConnectedToInternet, .cannotFindHost:
            throw LLMError.classified(.providerUnreachable)  // not transient, fail fast
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
        default:
          // #945: read the body INSIDE the error arm for classification (404 ->
          // model not pulled, 5xx -> server error). `data` is in hand from above.
          let bodyString = String(data: data, encoding: .utf8) ?? ""
          #if DEBUG
            let truncated = String(bodyString.prefix(200))
            Task {
              await AppLogger.shared.log(
                "Ollama HTTP \(httpResponse.statusCode): \(truncated)",
                level: .verbose, category: "LLM"
              )
            }
          #else
            Task {
              await AppLogger.shared.log(
                "Ollama HTTP \(httpResponse.statusCode)",
                level: .verbose, category: "LLM"
              )
            }
          #endif
          throw LLMError.classified(
            Self.classify(statusCode: httpResponse.statusCode, bodyString: bodyString))
        }
      } catch {
        lastError = error
        if !LLMRetryPolicy.isRetryable(error) { throw error }
      }
    }
    // Convert exhausted connection errors to domain error for UI
    if let urlError = lastError as? URLError, urlError.code == .cannotConnectToHost {
      throw LLMError.classified(.providerUnreachable)
    }
    throw lastError ?? LLMError.requestFailed("All retries exhausted")
  }

  /// Pure status+body -> reason classifier (#945). 404 means the model is not
  /// pulled; 5xx is a local Ollama server error. `bodyString` is accepted for
  /// signature parity with the cloud classifiers (and future body-based splits).
  /// Unit-testable without network mocking.
  static func classify(statusCode: Int, bodyString: String) -> PolishFailureReason {
    switch statusCode {
    case 404:
      return .modelUnavailable
    case 500...599:
      return .providerServerError
    default:
      return (400...499).contains(statusCode) ? .badRequest : .unknown
    }
  }
}
