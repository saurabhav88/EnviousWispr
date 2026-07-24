import EnviousWisprCore
import Foundation
import os

/// OpenAI Chat Completions API connector for transcript polishing.
///
/// Request shape is per-model (#1330): `LLMModelCapabilities` decides whether
/// `temperature` is serialized, and a bounded unsupported-param
/// strip-and-retry self-heals the static table against provider-side drift
/// (one extra round-trip, memoized per model for the rest of the process).
public struct OpenAIConnector: TranscriptPolisher {
  /// Transport seam: one physical HTTP exchange. Injected by tests to script
  /// reject/succeed sequences; production always uses the shared session.
  typealias RequestExecutor = @Sendable (
    URLRequest,
    LLMTaskMetricsCollector
  ) async throws -> (Data, URLResponse)

  private let keychainManager: KeychainManager
  private let requestExecutor: RequestExecutor
  private let baseURL = "https://api.openai.com/v1/chat/completions"

  /// Params the strip-retry may remove after a qualifying 400. Never
  /// `model`/`messages` — they are the request itself. `max_completion_tokens`
  /// is absent under `.providerDefault` (#1710) and, when present via
  /// `.capped`, is a deliberate policy value the strip must not remove.
  static let strippableParams: Set<String> = ["temperature", "reasoning_effort"]

  /// Process-lifetime memo of params each exact model id rejected, so the
  /// one-round-trip adaptation tax is paid once per model per app run.
  /// Never persisted: an OpenAI-side fix resets on relaunch.
  private static let paramMemo = OSAllocatedUnfairLock<[String: Set<String>]>(initialState: [:])

  public init(keychainManager: KeychainManager = KeychainManager()) {
    self.keychainManager = keychainManager
    self.requestExecutor = { request, collector in
      try await LLMNetworkSession.shared.session.data(for: request, delegate: collector)
    }
  }

  /// Test seam. Production callers use the public init.
  init(keychainManager: KeychainManager, requestExecutor: @escaping RequestExecutor) {
    self.keychainManager = keychainManager
    self.requestExecutor = requestExecutor
  }

  public func polish(
    text: String,
    instructions: PolishInstructions,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    // Key first: a user must have a usable key before model compatibility
    // becomes the actionable failure (missing/rejected/unreadable-key
    // precedence, #1330 grounded review r4).
    let apiKey = try getAPIKey(config: config)

    // Responses-API-only families (-pro, codex) can never succeed on Chat
    // Completions; fail deterministically with the model-unavailable notice
    // instead of a doomed network call (today only HTTP 404 maps there, and
    // the provider may answer 400 instead).
    let capabilities = LLMProvider.openAI.modelCapabilities(model: config.model)
    guard capabilities.supportsChatCompletions else {
      throw LLMError.classified(.modelUnavailable)
    }

    let messages: [[String: String]] = [
      ["role": "system", "content": instructions.systemPrompt],
      ["role": "user", "content": text],
    ]

    return try await performWithRetry(apiKey: apiKey, messages: messages, config: config)
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

  // MARK: - Request construction

  /// Build the Chat Completions body for `config`, honoring the model's
  /// temperature policy and any omissions (memoized or same-call strips).
  /// Static and pure for fixture testing.
  static func makeRequestBody(
    config: LLMProviderConfig,
    messages: [[String: String]],
    omitting: Set<String> = []
  ) -> [String: Any] {
    let capabilities = LLMProvider.openAI.modelCapabilities(model: config.model)

    var body: [String: Any] = [
      "model": config.model,
      "messages": messages,
      "store": false,
    ]
    // #1710: only `.capped` serializes a limit; `.providerDefault` sends
    // none, so the provider's own per-model maximum applies.
    if case .capped(let value) = config.outputTokens {
      body["max_completion_tokens"] = value
    }
    if capabilities.temperaturePolicy == .include && !omitting.contains("temperature") {
      body["temperature"] = config.temperature
    }
    if let reasoningEffort = config.reasoningEffort, !omitting.contains("reasoning_effort") {
      body["reasoning_effort"] = reasoningEffort
    }
    return body
  }

  private func makeRequest(
    apiKey: String, body: [String: Any]
  ) throws -> URLRequest {
    guard let url = URL(string: baseURL) else {
      throw LLMError.requestFailed("Invalid OpenAI URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 60
    return request
  }

  // MARK: - Retry

  private func performWithRetry(
    apiKey: String,
    messages: [[String: String]],
    config: LLMProviderConfig,
    maxRetries: Int = LLMRetryPolicy.defaultMaxRetries,
    delays: [UInt64] = LLMRetryPolicy.defaultDelays
  ) async throws -> LLMResult {
    // Allocate the call number once per logical polish. Transient retries
    // AND shape-strip re-issues reuse the same number so logs never mistake
    // one logical polish for multiple independent calls; each physical
    // request still emits its own metrics line via executeOnce.
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

      do {
        // Inner shape loop: a qualifying unsupported-param 400 rebuilds the
        // body without the rejected param and re-issues immediately. Bounded
        // by the allowlist size; does not consume a transient attempt.
        var stripsThisCall = 0
        while true {
          let omitting = Self.memoizedOmissions(model: config.model)
          let body = Self.makeRequestBody(
            config: config, messages: messages, omitting: omitting)
          let sentStrippable = Self.strippableParams.filter { body[$0] != nil }
          let request = try makeRequest(apiKey: apiKey, body: body)

          switch try await executeOnce(
            request: request, config: config, callNumber: callNumber)
          {
          case .success(let result):
            return result

          case .httpFailure(let statusCode, let bodyString):
            if statusCode == 400,
              stripsThisCall < Self.strippableParams.count,
              let param = Self.strippableParam(
                fromErrorBody: bodyString, sentParams: sentStrippable)
            {
              stripsThisCall += 1
              let firstStripForModel = Self.recordOmission(model: config.model, param: param)
              if firstStripForModel {
                Task {
                  await AppLogger.shared.log(
                    "OpenAI request shape adapted model=\(config.model) omitted_param=\(param)",
                    level: .info, category: "LLM"
                  )
                }
              }
              continue
            }

            // #945: read the body INSIDE the error arm so the classifier can
            // split the ambiguous pairs (out-of-credits vs rate-limited on
            // 429; too-long vs generic 400).
            #if DEBUG
              let truncated = String(bodyString.prefix(200))
              Task {
                await AppLogger.shared.log(
                  "OpenAI HTTP \(statusCode): \(truncated)",
                  level: .verbose, category: "LLM"
                )
              }
            #else
              Task {
                await AppLogger.shared.log(
                  "OpenAI HTTP \(statusCode)",
                  level: .verbose, category: "LLM"
                )
              }
            #endif
            throw LLMError.classified(
              Self.classify(statusCode: statusCode, bodyString: bodyString))
          }
        }
      } catch {
        lastError = error
        if !LLMRetryPolicy.isRetryable(error) { throw error }
      }
    }
    throw lastError ?? LLMError.requestFailed("All retries exhausted")
  }

  /// One physical HTTP exchange. Owns its own metrics collector, status
  /// token, and metrics-line defer, so every request — transient retry or
  /// shape-strip re-issue — emits exactly one task_metrics line under the
  /// shared logical call number.
  private enum AttemptOutcome {
    case success(LLMResult)
    case httpFailure(statusCode: Int, body: String)
  }

  private func executeOnce(
    request: URLRequest,
    config: LLMProviderConfig,
    callNumber: Int
  ) async throws -> AttemptOutcome {
    let collector = LLMTaskMetricsCollector()
    var statusForLog = "pending"
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
      (data, response) = try await requestExecutor(request, collector)
    } catch {
      statusForLog = "error:\(Self.shortError(error))"
      throw error
    }
    guard let httpResponse = response as? HTTPURLResponse else {
      statusForLog = "error:non_http_response"
      throw LLMError.requestFailed("Invalid response")
    }
    statusForLog = String(httpResponse.statusCode)

    if httpResponse.statusCode == 200 {
      // Parse inside the defer scope so a malformed 200 payload
      // (e.g. content-moderation refusal, unexpected schema)
      // updates statusForLog to error_after_200 before the
      // metrics line is written (Codex GitHub review P2).
      do {
        return .success(try Self.parseSuccess(data: data, config: config))
      } catch {
        statusForLog = "error_after_200:\(Self.shortError(error))"
        throw error
      }
    }

    return .httpFailure(
      statusCode: httpResponse.statusCode,
      body: String(data: data, encoding: .utf8) ?? ""
    )
  }

  // MARK: - Unsupported-param recovery

  private struct OpenAIErrorEnvelope: Decodable {
    struct APIError: Decodable {
      let type: String?
      let param: String?
      let code: String?
    }
    let error: APIError
  }

  /// Extract the parameter a 400 body rejects, iff it qualifies for the
  /// strip-retry: allowlisted, actually sent, and the structured error does
  /// not contradict the unsupported-param reading. `code` MAY be absent —
  /// the public API reference does not document the 400 schema and our
  /// recorded evidence proves only `param` (#1330) — so fail open on a
  /// missing code and closed on a contradicting one.
  static func strippableParam(
    fromErrorBody body: String,
    sentParams: Set<String>
  ) -> String? {
    let allowedCodes: Set<String> = ["unsupported_parameter", "unsupported_value"]

    guard
      let data = body.data(using: .utf8),
      let envelope = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data),
      let param = envelope.error.param,
      Self.strippableParams.contains(param),
      sentParams.contains(param)
    else {
      return nil
    }
    guard envelope.error.type == nil || envelope.error.type == "invalid_request_error" else {
      return nil
    }
    guard envelope.error.code == nil || allowedCodes.contains(envelope.error.code!) else {
      return nil
    }
    return param
  }

  static func memoizedOmissions(model: String) -> Set<String> {
    paramMemo.withLock { $0[model] ?? [] }
  }

  /// Record a rejected param for `model`. Returns true when newly learned
  /// (first strip for this model+param this run), so callers log once.
  @discardableResult
  static func recordOmission(model: String, param: String) -> Bool {
    paramMemo.withLock { memo in
      memo[model, default: []].insert(param).inserted
    }
  }

  /// Test hook: clear learned omissions for one model so scripted transport
  /// tests stay independent even though the memo is process-global.
  static func resetOmissions(model: String) {
    _ = paramMemo.withLock { $0.removeValue(forKey: model) }
  }

  /// Parse a successful OpenAI 200 response into an LLMResult.
  /// Throws `LLMError.emptyResponse` on missing/empty content so the retry
  /// caller can mark statusForLog as error_after_200.
  ///
  /// Emptiness is checked on the TRIMMED content, not the raw string (#1710):
  /// a whitespace/newline-only response has a non-empty raw string but is a
  /// successful-looking empty result once this function trims it into the
  /// final `LLMResult` — checking the untrimmed value would let that case
  /// through as a false "success" and hide a real provider failure from the
  /// pipeline's fallback logic. Mirrors `ClaudeConnector.extractResponseText`.
  private static func parseSuccess(
    data: Data, config: LLMProviderConfig
  ) throws -> LLMResult {
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let choices = json?["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String,
      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw LLMError.emptyResponse
    }

    // #1710: a length-stop is a PARTIAL rewrite — pasting it would silently
    // delete the tail of the dictation. Reject whole; the pipeline keeps the
    // complete pre-polish text.
    if let finishReason = choices.first?["finish_reason"] as? String,
      finishReason == "length"
    {
      Task {
        await AppLogger.shared.log(
          "WARNING: OpenAI response truncated; rejecting partial output "
            + "(finish_reason=length, model=\(config.model), policy=\(config.outputTokens))",
          level: .info, category: "LLM"
        )
      }
      throw LLMError.classified(.outputTruncated)
    }

    return LLMResult(
      polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines)
        .strippingLLMPreamble(stripTranscriptTags: false)
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

  /// Pure status+body -> reason classifier (#945). Unit-testable without network
  /// mocking: feed `(Int, String)` fixtures. `internal` so the same-module
  /// connector throws it and `@testable` tests assert it.
  static func classify(statusCode: Int, bodyString: String) -> PolishFailureReason {
    switch statusCode {
    case 401:
      return .apiKeyRejected
    case 403:
      return .accessDenied
    case 404:
      return .modelUnavailable
    case 429:
      // Split rate-limit vs out-of-credits by the body's `error.type`.
      return bodyString.contains("insufficient_quota") ? .outOfCredits : .rateLimited
    case 400:
      if bodyString.contains("context_length_exceeded") { return .inputTooLong }
      if bodyString.contains("content_filter") || bodyString.contains("content_policy") {
        return .contentBlocked
      }
      return .badRequest
    case 500...599:
      return .providerServerError
    default:
      return (400...499).contains(statusCode) ? .badRequest : .unknown
    }
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
