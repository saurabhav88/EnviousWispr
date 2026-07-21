import EnviousWisprCore
import Foundation

/// Google Gemini API connector for transcript polishing.
/// Uses Server-Sent Events (SSE) streaming for lower perceived latency.
public struct GeminiConnector: TranscriptPolisher {
  private let keychainManager: KeychainManager
  private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

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

    let body = Self.makeRequestBody(
      text: text,
      systemPrompt: instructions.systemPrompt,
      generationConfig: generationConfig
    )

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 60

    // Allocate the call number once per logical polish. Retries reuse the
    // same number so logs never mistake a retried polish for multiple
    // independent calls (see Codex review finding P3).
    let callNumber = LLMNetworkSession.shared.nextCallNumber()

    return try await performWithRetry(config: config) {
      if let onToken {
        return try await self.polishStreaming(
          request: request, config: config, callNumber: callNumber, onToken: onToken
        )
      } else {
        return try await self.polishBatch(
          request: request, config: config, callNumber: callNumber
        )
      }
    }
  }

  public func polish(
    envelope: PromptEnvelope,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    guard let pair = envelope.asSingleTurn() else {
      // Fallback: join messages (should not happen for Gemini)
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

  static func makeRequestBody(
    text: String,
    systemPrompt: String,
    generationConfig: [String: Any]
  ) -> [String: Any] {
    var body: [String: Any] = [
      "systemInstruction": [
        "parts": [["text": systemPrompt]]
      ],
      "generationConfig": generationConfig,
      "store": false,
    ]

    // When ${transcript} placeholder is used, LLMPolishStep resolves the full
    // prompt into systemPrompt and passes text as "". In that case we send a
    // minimal contents array; otherwise the transcript goes in contents.
    if text.isEmpty {
      body["contents"] = [
        ["parts": [["text": "Polish the transcript per the system instructions."]]]
      ]
    } else {
      body["contents"] = [["parts": [["text": text]]]]
    }

    return body
  }

  // MARK: - SSE Streaming

  private func polishStreaming(
    request: URLRequest,
    config: LLMProviderConfig,
    callNumber: Int,
    onToken: @Sendable (String) -> Void
  ) async throws -> LLMResult {
    let session = LLMNetworkSession.shared.session
    let collector = LLMTaskMetricsCollector()
    var statusForLog = "pending"
    defer {
      let line = LLMTaskMetricsCollector.format(
        provider: "gemini", model: config.model, callNumber: callNumber,
        status: statusForLog, metrics: collector.metrics
      )
      Task { await AppLogger.shared.log(line, level: .info, category: "LLM") }
    }

    let stream: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (stream, response) = try await session.bytes(for: request, delegate: collector)
    } catch {
      statusForLog = "error:\(Self.shortError(error))"
      throw error
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      statusForLog = "error:non_http_response"
      throw LLMError.requestFailed("Invalid response")
    }
    statusForLog = String(httpResponse.statusCode)

    // From here on the stream may throw (mid-response timeout, disconnect,
    // cancellation). Capture that outcome in statusForLog before the defer
    // fires so the diagnostic does not record a mid-stream failure as a
    // successful 200 (Codex review finding P2).
    let fullText: String
    let lastFinishReason: String?
    do {
      if httpResponse.statusCode != 200 {
        var errorBody = ""
        for try await line in stream.lines {
          errorBody += line
        }
        try handleHTTPError(statusCode: httpResponse.statusCode, body: errorBody)
      }

      var text = ""
      var finishReason: String?

      for try await line in stream.lines {
        // SSE format: lines prefixed with "data: " contain JSON
        // Empty lines delimit events, lines starting with ":" are comments
        guard line.hasPrefix("data: ") else { continue }
        let jsonString = String(line.dropFirst(6))

        guard let jsonData = jsonString.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let candidates = json["candidates"] as? [[String: Any]],
          let firstCandidate = candidates.first
        else {
          continue
        }

        // Extract text fragments from this chunk, skipping thought parts
        if let content = firstCandidate["content"] as? [String: Any],
          let parts = content["parts"] as? [[String: Any]]
        {
          for part in parts {
            if part["thought"] as? Bool == true { continue }
            if let textFragment = part["text"] as? String {
              text += textFragment
              onToken(textFragment)
            }
          }
        }

        // Check finishReason — present only in the final chunk
        if let reason = firstCandidate["finishReason"] as? String {
          finishReason = reason
        }
      }
      fullText = text
      lastFinishReason = finishReason
    } catch {
      // Record the mid-stream failure so the metrics line reflects reality.
      // The HTTP status was 200 at headers, but the body did not complete.
      statusForLog = "error_after_\(httpResponse.statusCode):\(Self.shortError(error))"
      throw error
    }

    // Trimmed, not raw (#1710): see extractBatchResponseText's doc comment
    // for why a whitespace/newline-only accumulation must not pass as a
    // successful result.
    guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      statusForLog = "error_after_\(httpResponse.statusCode):empty_response"
      throw LLMError.emptyResponse
    }

    logTruncationIfNeeded(finishReason: lastFinishReason, config: config)

    return LLMResult(
      polishedText: fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        .strippingLLMPreamble(stripTranscriptTags: false)
    )
  }

  // MARK: - Batch (non-streaming)

  private func polishBatch(
    request: URLRequest,
    config: LLMProviderConfig,
    callNumber: Int
  ) async throws -> LLMResult {
    let session = LLMNetworkSession.shared.session
    let collector = LLMTaskMetricsCollector()
    var statusForLog = "pending"
    defer {
      let line = LLMTaskMetricsCollector.format(
        provider: "gemini", model: config.model, callNumber: callNumber,
        status: statusForLog, metrics: collector.metrics
      )
      Task { await AppLogger.shared.log(line, level: .info, category: "LLM") }
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request, delegate: collector)
    } catch {
      statusForLog = "error:\(Self.shortError(error))"
      throw error
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      statusForLog = "error:non_http_response"
      throw LLMError.requestFailed("Invalid response")
    }
    statusForLog = String(httpResponse.statusCode)

    // Post-header failures (non-200 body, malformed JSON, empty candidates,
    // all-thought response with zero text) must be reflected in statusForLog
    // so the defer never records a successful-looking line for a failed
    // call. The responseText empty-check is inside this do block because
    // an all-thought response still throws LLMError.emptyResponse and would
    // otherwise leak through with status=200.
    let extracted: (text: String, finishReason: String?)
    do {
      if httpResponse.statusCode != 200 {
        let body = String(data: data, encoding: .utf8) ?? ""
        try handleHTTPError(statusCode: httpResponse.statusCode, body: body)
      }

      extracted = try Self.extractBatchResponseText(from: data)
    } catch {
      statusForLog = "error_after_\(httpResponse.statusCode):\(Self.shortError(error))"
      throw error
    }

    logTruncationIfNeeded(finishReason: extracted.finishReason, config: config)

    return LLMResult(
      polishedText: extracted.text.trimmingCharacters(in: .whitespacesAndNewlines)
        .strippingLLMPreamble(stripTranscriptTags: false)
    )
  }

  /// Pure success-body parser for the non-streaming path (#1710, mirroring
  /// `ClaudeConnector.extractResponseText`). Extracted out of `polishBatch`
  /// so the emptiness edge case is unit-testable directly against `Data`
  /// literals without a transport seam (neither Gemini nor Claude has one —
  /// see `ClaudeConnectorTests.swift`).
  ///
  /// Emptiness is checked on the TRIMMED text, not the raw joined text: a
  /// whitespace/newline-only response has a non-empty raw string but is a
  /// successful-looking empty result once `polishBatch` trims it into the
  /// final `LLMResult` — checking the untrimmed value here would let that
  /// case through as a false "success" and hide a real provider failure
  /// from the pipeline's fallback logic.
  static func extractBatchResponseText(
    from data: Data
  ) throws -> (text: String, finishReason: String?) {
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let candidates = json?["candidates"] as? [[String: Any]],
      let candidate = candidates.first,
      let content = candidate["content"] as? [String: Any],
      let candidateParts = content["parts"] as? [[String: Any]]
    else {
      throw LLMError.emptyResponse
    }
    let text =
      candidateParts
      .filter { $0["thought"] as? Bool != true }
      .compactMap { $0["text"] as? String }
      .joined()
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LLMError.emptyResponse
    }
    return (text, candidate["finishReason"] as? String)
  }

  // MARK: - Shared

  private func logTruncationIfNeeded(finishReason: String?, config: LLMProviderConfig) {
    guard finishReason == "MAX_TOKENS" else { return }
    Task {
      await AppLogger.shared.log(
        "WARNING: Gemini response truncated (finishReason=MAX_TOKENS, model=\(config.model), maxOutputTokens=\(config.maxTokens))",
        level: .info, category: "LLM"
      )
    }
  }

  private func handleHTTPError(statusCode: Int, body: String) throws -> Never {
    #if DEBUG
      let truncated = String(body.prefix(200))
      Task {
        await AppLogger.shared.log(
          "Gemini HTTP \(statusCode): \(truncated)",
          level: .verbose, category: "LLM"
        )
      }
    #else
      Task {
        await AppLogger.shared.log(
          "Gemini HTTP \(statusCode)",
          level: .verbose, category: "LLM"
        )
      }
    #endif
    throw LLMError.classified(Self.classify(statusCode: statusCode, bodyString: body))
  }

  /// Pure status+body -> reason classifier (#945). Gemini's 429
  /// `RESOURCE_EXHAUSTED` does NOT cleanly split rate-limit vs quota, so it maps
  /// to the honest `rateLimitedOrQuota` rather than guessing (which is how the
  /// old code recreated the out-of-credits-told-to-wait bug). Content-safety on a
  /// non-200 is best-effort; a 200-with-`promptFeedback.blockReason` still
  /// degrades to `emptyResponse` in the success parse (deferred enhancement).
  /// Unit-testable without network mocking.
  static func classify(statusCode: Int, bodyString: String) -> PolishFailureReason {
    switch statusCode {
    case 400:
      if bodyString.contains("API_KEY_INVALID") { return .apiKeyRejected }
      if bodyString.contains("exceeds the maximum number of tokens") { return .inputTooLong }
      if bodyString.contains("PROHIBITED_CONTENT") || bodyString.contains("blockReason") {
        return .contentBlocked
      }
      return .badRequest
    case 401:
      return .apiKeyRejected
    case 403:
      return .accessDenied
    case 404:
      return .modelUnavailable
    case 429:
      return .rateLimitedOrQuota
    case 500...599:
      return .providerServerError
    default:
      return (400...499).contains(statusCode) ? .badRequest : .unknown
    }
  }

  /// Short error token for diagnostic log lines. Prefers URLError.code.rawValue
  /// for network errors (e.g. -1001 for timeout, -1009 for offline); falls back
  /// to the Swift type name. Never a full localized message.
  fileprivate static func shortError(_ error: Error) -> String {
    if let urlError = error as? URLError {
      return "urlerror_\(urlError.code.rawValue)"
    }
    if error is CancellationError {
      return "cancelled"
    }
    return "\(type(of: error))"
  }

  // MARK: - Retry

  private func performWithRetry(
    config: LLMProviderConfig,
    maxRetries: Int = LLMRetryPolicy.defaultMaxRetries,
    delays: [UInt64] = LLMRetryPolicy.defaultDelays,
    operation: () async throws -> LLMResult
  ) async throws -> LLMResult {
    var lastError: Error?
    for attempt in 0...maxRetries {
      if attempt > 0 {
        let delay = delays[min(attempt - 1, delays.count - 1)]
        Task {
          await AppLogger.shared.log(
            "Gemini retry \(attempt)/\(maxRetries) after \(delay / 1_000_000_000)s (model=\(config.model))",
            level: .verbose, category: "LLM"
          )
        }
        try await Task.sleep(nanoseconds: delay)
      }
      do {
        return try await operation()
      } catch {
        lastError = error
        if !LLMRetryPolicy.isRetryable(error) { throw error }
      }
    }
    throw lastError ?? LLMError.requestFailed("All retries exhausted")
  }

  private func getAPIKey(config: LLMProviderConfig) throws -> String {
    guard let keychainId = config.apiKeyKeychainId else {
      throw LLMError.classified(.apiKeyMissing)
    }
    do {
      return try keychainManager.retrieve(key: keychainId)
    } catch KeyStoreError.retrieveFailed(let status) where status == errSecItemNotFound {
      // No key is stored. NOTE this is the arm a real no-key user takes, not the
      // `guard` above: `LLMPolishStep` always supplies the fixed key id for a cloud
      // provider, so `apiKeyKeychainId` is never nil in production (#1446). Classify
      // by what the STORE says, not by whether an id was passed.
      throw LLMError.classified(.apiKeyMissing)
    } catch {
      // A key IS stored but could not be read (corrupt entry, locked Keychain,
      // missing entitlement, migration bug). The user sees the same notice as the
      // no-key case — re-entering the key in Settings fixes both — but this one is
      // OUR defect and keeps its own alerting fingerprint (#1446).
      throw LLMError.classified(.apiKeyUnreadable)
    }
  }
}
