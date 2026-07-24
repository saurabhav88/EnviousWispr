import EnviousWisprCore
import Foundation

/// Anthropic Claude Messages API connector for transcript polishing.
///
/// v1: no extended thinking, ever (`LLMModelCapabilities.supportsReasoning`
/// is `false` for every Claude model). `temperature`/`top_p`/`top_k` are
/// omitted from the request body — Claude generations released after Opus
/// 4.6 reject a non-default `temperature`, including 0, with an HTTP 400;
/// omitting them unconditionally is the same shape #1330 established for
/// OpenAI's reasoning family, applied here so a future catalog model
/// doesn't silently break. `thinking` is the one exception: it IS sent,
/// explicitly disabled (GitHub cloud review P2, PR #1712) — several
/// current models (`claude-sonnet-5`, `claude-fable-5`, `claude-opus-4-8`,
/// `claude-opus-4-7`) default to Anthropic's "adaptive" thinking mode when
/// `thinking` is omitted entirely, which would silently spend thinking
/// tokens the "no extended thinking, ever" design explicitly rules out and
/// could push a polish call past its latency budget. `{"type":"disabled"}`
/// is confirmed accepted (HTTP 200, `thinking_tokens: 0` in the response)
/// across every current model's capability shape (adaptive-only,
/// enabled-only, and both), verified live against the real catalog before
/// landing this. No streaming (`onToken` accepted but unused, matching
/// OpenAI's precedent) and no unsupported-param strip-and-retry (`thinking`
/// is the only sampling-adjacent param sent, and every current model
/// accepts disabling it).
public struct ClaudeConnector: TranscriptPolisher {
  private let keychainManager: KeychainManager
  private let baseURL = "https://api.anthropic.com/v1/messages"
  private static let apiVersion = "2023-06-01"

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

    guard let url = URL(string: baseURL) else {
      throw LLMError.requestFailed("Invalid Claude URL")
    }
    // #1710: the Anthropic API REQUIRES `max_tokens`. `.capped` carries the
    // policy value; an unexpected `.providerDefault` maps defensively to the
    // fixed constant (non-crashing invariant guard, not a second authority).
    let resolved = Self.resolvedMaxTokens(config.outputTokens)
    let maxTokens = resolved.value
    if resolved.usedFallback {
      Task {
        await AppLogger.shared.log(
          "Claude received providerDefault output-token policy; "
            + "using required fallback \(maxTokens)",
          level: .info, category: "LLM"
        )
      }
    }
    let body = Self.makeRequestBody(
      model: config.model,
      maxTokens: maxTokens,
      system: instructions.systemPrompt,
      userText: text
    )

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 60

    // Allocate the call number once per logical polish. Retries reuse the
    // same number so logs never mistake a retried polish for multiple
    // independent calls (mirrors GeminiConnector/OpenAIConnector).
    let callNumber = LLMNetworkSession.shared.nextCallNumber()

    return try await performWithRetry(config: config) {
      try await self.polishBatch(request: request, config: config, callNumber: callNumber)
    }
  }

  public func polish(
    envelope: PromptEnvelope,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    // The `.cloudFixed` family Claude joins always produces exactly one
    // system and one user message, so this should never be reached — but
    // the connector fails loud rather than silently dropping content if a
    // future prompt path ever hands it a few-shot or multi-turn envelope.
    guard let pair = envelope.asSingleTurn() else {
      throw LLMError.requestFailed("Claude requires a single-turn prompt envelope")
    }
    return try await polish(
      text: pair.user,
      instructions: PolishInstructions(systemPrompt: pair.system ?? ""),
      config: config,
      onToken: onToken
    )
  }

  // MARK: - Truncation rejection (#1710)

  /// A max_tokens stop is a PARTIAL rewrite — reject whole; the pipeline
  /// keeps the complete pre-polish text. The production decision seam:
  /// `polish` feeds `extractResponseText`'s truncated flag here, and tests
  /// drive the same function.
  static func rejectTruncationIfNeeded(truncated: Bool, config: LLMProviderConfig) throws {
    guard truncated else { return }
    Task {
      await AppLogger.shared.log(
        "WARNING: Claude response truncated; rejecting partial output "
          + "(stop_reason=max_tokens, model=\(config.model), policy=\(config.outputTokens))",
        level: .info, category: "LLM"
      )
    }
    throw LLMError.classified(.outputTruncated)
  }

  // MARK: - Request construction

  /// Resolve the required `max_tokens` value for a policy (#1710). Static
  /// and pure for fixture testing. `usedFallback` marks the defensive
  /// `.providerDefault` mapping so the call site can log the invariant breach.
  static func resolvedMaxTokens(
    _ policy: OutputTokenPolicy
  ) -> (value: Int, usedFallback: Bool) {
    switch policy {
    case .capped(let value): return (value, false)
    case .providerDefault: return (LLMConstants.claudeMaxOutputTokens, true)
    }
  }

  /// The single owner of the Claude request shape, used by both production
  /// polish and `LLMModelDiscovery.probeClaude` — so a probe/production body
  /// mismatch can never report a model "available" against a shape
  /// production doesn't actually send. `system` is omitted entirely when
  /// nil/empty (the probe passes `nil`; production always has a real system
  /// prompt for the `.cloudFixed` family). Deliberately module-internal
  /// (not `private`): `LLMModelDiscovery` calls this from another file in
  /// the same `EnviousWisprLLM` module.
  static func makeRequestBody(
    model: String,
    maxTokens: Int,
    system: String?,
    userText: String
  ) -> [String: Any] {
    // Known, verified exception (GitHub cloud review r2, PR #1712):
    // `claude-fable-5` rejects `thinking: {"type":"disabled"}` with a real
    // HTTP 400 (`"thinking.type.disabled" is not supported for this
    // model`), confirmed live — despite sharing the identical catalog
    // `capabilities.thinking` shape (`enabled: false, adaptive: true`) as
    // `claude-sonnet-5`/`claude-opus-4-8`/`claude-opus-4-7`, which all
    // accept `disabled` fine (also verified live). The catalog's declared
    // capability shape is therefore NOT a reliable predictor of which
    // exact `thinking.type` values a model accepts — this is a per-model
    // API quirk, not a pattern to hardcode around. No special-case branch
    // here: the resulting 400 already falls through the EXISTING generic
    // non-200 path in `probeClaude` (returns `false`, correctly excluding
    // Fable 5 from the offered picker) and `classify` (`.badRequest` if a
    // stale selection somehow reaches production, which the settings
    // canonicalization fallback already prevents on the next discovery
    // pass) — this is the "filtered out" resolution, not a locked/broken
    // state. Confirmed live: 9/10 catalog models offered and passing with
    // Fable 5 excluded, zero broken dictations.
    var body: [String: Any] = [
      "model": model,
      "max_tokens": maxTokens,
      "messages": [["role": "user", "content": userText]],
      "thinking": ["type": "disabled"],
    ]
    if let system, !system.isEmpty {
      body["system"] = system
    }
    return body
  }

  // MARK: - Batch

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
        provider: "claude", model: config.model, callNumber: callNumber,
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

    // Post-header failures (non-200 body, malformed JSON, no text blocks,
    // all-empty text) must be reflected in statusForLog so the defer never
    // records a successful-looking line for a failed call. A genuinely
    // malformed (non-JSON) body propagates as a raw JSONSerialization decode
    // error here, matching GeminiConnector/OpenAIConnector's existing
    // precedent rather than inventing a bespoke rewrite to `.emptyResponse`.
    let responseText: String
    do {
      if httpResponse.statusCode != 200 {
        let body = String(data: data, encoding: .utf8) ?? ""
        try handleHTTPError(statusCode: httpResponse.statusCode, body: body)
      }

      let extracted = try Self.extractResponseText(from: data)
      responseText = extracted.text
      // #1710: the throw happens inside this do block so the catch below
      // stamps error_after_<code>; the decision itself is the production
      // seam tests drive directly.
      try Self.rejectTruncationIfNeeded(truncated: extracted.truncated, config: config)
    } catch {
      statusForLog = "error_after_\(httpResponse.statusCode):\(Self.shortError(error))"
      throw error
    }

    return LLMResult(
      polishedText: responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        .strippingLLMPreamble(stripTranscriptTags: false)
    )
  }

  // MARK: - Shared

  private func handleHTTPError(statusCode: Int, body: String) throws -> Never {
    #if DEBUG
      let truncated = String(body.prefix(200))
      Task {
        await AppLogger.shared.log(
          "Claude HTTP \(statusCode): \(truncated)",
          level: .verbose, category: "LLM"
        )
      }
    #else
      Task {
        await AppLogger.shared.log(
          "Claude HTTP \(statusCode)",
          level: .verbose, category: "LLM"
        )
      }
    #endif
    throw LLMError.classified(Self.classify(statusCode: statusCode, bodyString: body))
  }

  /// Pure status+body -> reason classifier (#945). Anthropic's `rate_limit_error`
  /// type is a clean signal (unlike Gemini's ambiguous `RESOURCE_EXHAUSTED`), so
  /// 429 maps directly to `.rateLimited`, no `.rateLimitedOrQuota` needed. The
  /// low-credit-balance body shape is unverified (JUDGMENT-CALL, plan §2.5): a
  /// best-effort substring match on a 400 body, falling through to the generic
  /// `.badRequest` otherwise. Unit-testable without network mocking.
  static func classify(statusCode: Int, bodyString: String) -> PolishFailureReason {
    switch statusCode {
    case 400:
      if bodyString.contains("credit balance") { return .outOfCredits }
      // Real observed body (2026-07-20, live 250k-token overrun against the
      // founder's account): {"type":"error","error":{"type":"invalid_request_error",
      // "message":"prompt is too long: 250024 tokens > 200000 maximum"}} — matches
      // OpenAI/Gemini's existing `.inputTooLong` classification for the same
      // real-world failure (Codex r7), not left as a generic `.badRequest`
      // that would misread a too-long dictation as a configuration defect.
      if bodyString.contains("prompt is too long") { return .inputTooLong }
      return .badRequest
    case 401:
      return .apiKeyRejected
    case 402:
      // Documented, not guessed (GitHub cloud review r3, PR #1712,
      // confirmed against https://platform.claude.com/docs/en/api/errors):
      // 402 is Anthropic's dedicated `billing_error` status for a billing
      // or payment problem (e.g. no prepaid credits) — the same real-world
      // condition `.outOfCredits` already exists to name, not a generic
      // client-error/configuration-problem case.
      return .outOfCredits
    case 403:
      return .accessDenied
    case 404:
      return .modelUnavailable
    case 413:
      // Documented, not guessed (GitHub cloud review r4, PR #1712,
      // confirmed against the same
      // https://platform.claude.com/docs/en/api/errors fetch that
      // established 402 above): 413 is Anthropic's dedicated
      // `request_too_large` status for a request exceeding the Messages
      // API's byte-size limit — the same real-world "your dictation is
      // too long for this request" condition `.inputTooLong` already
      // names for the 400 prompt-is-too-long case above, just hit via a
      // different limit (byte size vs. token count).
      return .inputTooLong
    case 429:
      return .rateLimited
    case 500...599:
      return .providerServerError
    default:
      return (400...499).contains(statusCode) ? .badRequest : .unknown
    }
  }

  /// Pure success-body parser (#158, Codex r6). Extracts and validates the
  /// text content of a 200 Claude response, and reports whether Anthropic
  /// truncated it (`stop_reason == "max_tokens"`). Unit-testable without
  /// network mocking, mirroring `makeRequestBody`/`classify`'s pattern.
  ///
  /// Emptiness is checked on the TRIMMED text, not the raw joined text: a
  /// whitespace/newline-only response has a non-empty raw string but is a
  /// successful-looking empty result once `polishBatch` trims it into the
  /// final `LLMResult` — checking the untrimmed value here would let that
  /// case through as a false "success" and hide a real provider failure
  /// from the pipeline's fallback logic.
  static func extractResponseText(from data: Data) throws -> (text: String, truncated: Bool) {
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let content = json?["content"] as? [[String: Any]] else {
      throw LLMError.emptyResponse
    }
    let text =
      content
      .filter { $0["type"] as? String == "text" }
      .compactMap { $0["text"] as? String }
      .joined()
    let truncated = (json?["stop_reason"] as? String) == "max_tokens"
    // #1710 cloud review P2 class: empty text that ALSO carries max_tokens
    // is a provider condition — return the truncated flag so the decision
    // seam classifies it as outputTruncated, never our alerting
    // emptyResponse. Empty WITHOUT the marker stays emptyResponse.
    guard truncated || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LLMError.emptyResponse
    }
    // `stop_reason: "refusal"` is a documented Anthropic value for a model
    // declining to continue — unlike a moderation refusal on other
    // providers (which tends to leave `content` empty/null and falls
    // through to the generic `.emptyResponse` case), Claude's refusal still
    // carries explanatory TEXT, so without this check it would pass every
    // check above and get pasted as if it were legitimate cleaned-up
    // dictation (Codex r7) — classify it the same way OpenAI/Gemini's
    // existing `.contentBlocked` case handles a moderation refusal.
    if (json?["stop_reason"] as? String) == "refusal" {
      throw LLMError.classified(.contentBlocked)
    }
    return (text, truncated)
  }

  /// Short error token for diagnostic log lines. Mirrors
  /// GeminiConnector.shortError/OpenAIConnector.shortError.
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
            "Claude retry \(attempt)/\(maxRetries) after \(delay / 1_000_000_000)s (model=\(config.model))",
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
      // provider, so `apiKeyKeychainId` is never nil in production. Classify
      // by what the STORE says, not by whether an id was passed.
      throw LLMError.classified(.apiKeyMissing)
    } catch {
      // A key IS stored but could not be read (corrupt entry, locked Keychain,
      // missing entitlement, migration bug). The user sees the same notice as the
      // no-key case — re-entering the key in Settings fixes both — but this one is
      // OUR defect and keeps its own alerting fingerprint.
      throw LLMError.classified(.apiKeyUnreadable)
    }
  }
}
