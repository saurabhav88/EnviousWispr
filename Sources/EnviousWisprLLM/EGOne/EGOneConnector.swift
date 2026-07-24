import EnviousWisprCore
import Foundation

/// Localhost OpenAI-wire connector for the bundled EG-1 inference server
/// (#1271). Thin sibling of `OpenAIConnector`: same chat-completions wire
/// format, but no keychain (the per-launch bearer token comes from the
/// endpoint), temperature 0, and every transport failure maps to the
/// SILENT bypass family — a local-server hiccup must read as "no polish
/// this time", never as an "AI polish failed" pill.
///
/// Stateless by contract: reads the endpoint per call, never owns the
/// process (that is `EGOneServerManager`).
public struct EGOneConnector: TranscriptPolisher {
  private let endpoint: EGOneEndpoint

  public init(endpoint: EGOneEndpoint) {
    self.endpoint = endpoint
  }

  public func polish(
    text: String,
    instructions: PolishInstructions,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    try await send(system: instructions.systemPrompt, user: text, config: config)
  }

  public func polish(
    envelope: PromptEnvelope,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    guard let pair = envelope.asSingleTurn() else {
      let user = envelope.messages.filter { $0.role == .user }.map(\.content).joined()
      let system = envelope.messages.filter { $0.role == .system }.map(\.content)
        .joined(separator: "\n")
      return try await send(system: system, user: user, config: config)
    }
    return try await send(system: pair.system ?? "", user: pair.user, config: config)
  }

  /// Build the chat-completions body (#1710). Static and pure for fixture
  /// testing. EG-1's truncation policy depends on its computed cap; an
  /// uncapped request is an invariant breach and throws through the
  /// ordinary limb-failure path.
  static func makeRequestBody(
    system: String, user: String, config: LLMProviderConfig
  ) throws -> [String: Any] {
    guard case .capped(let maxTokens) = config.outputTokens else {
      throw LLMError.requestFailed("Local polish requires an explicit output-token cap")
    }
    return [
      "model": config.model,
      "messages": [
        ["role": "system", "content": system],
        ["role": "user", "content": user],
      ],
      "max_tokens": maxTokens,
      "temperature": config.temperature,
    ]
  }

  private func send(
    system: String, user: String, config: LLMProviderConfig
  ) async throws -> LLMResult {
    let body = try Self.makeRequestBody(system: system, user: user, config: config)

    var request = URLRequest(url: endpoint.chatCompletionsURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(endpoint.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    // The pipeline's 15 s budget is the real cap; this transport timeout
    // only stops a zombie socket from outliving the step.
    request.timeoutInterval = 20

    // One internal retry on connection-refused/reset: covers the
    // restart-once window after a server crash (plan §4). This is the
    // EXPLICIT retry decision for EG-1 — `LLMRetryPolicy` deliberately
    // treats the bypass error below as non-retryable so outer machinery
    // never stacks retries on top.
    var lastConnectionError = false
    for attempt in 0...1 {
      if attempt > 0 {
        try await Task.sleep(for: .milliseconds(750))
      }
      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw LLMError.egOneSkipped(.crashed)
        }
        guard http.statusCode == 200 else {
          Task {
            await AppLogger.shared.log(
              "EG-1 server HTTP \(http.statusCode)", level: .verbose, category: "LLM")
          }
          throw LLMError.egOneSkipped(.crashed)
        }
        return try Self.parseSuccess(data: data)
      } catch let urlError as URLError {
        switch urlError.code {
        case .cannotConnectToHost, .networkConnectionLost:
          lastConnectionError = true
          continue
        case .cancelled:
          throw CancellationError()
        default:
          throw LLMError.egOneSkipped(.crashed)
        }
      }
    }
    _ = lastConnectionError
    throw LLMError.egOneSkipped(.crashed)
  }

  /// `internal` (not private) so the tag-echo regression test drives it
  /// with a canned wire payload.
  static func parseSuccess(data: Data) throws -> LLMResult {
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    // finish_reason == "length" means generation STOPPED at the max_tokens
    // cap — the content is a partial rewrite. Accepting it pastes a
    // truncated polish, the exact failure the EG-1 contract forbids; the
    // token budgets make this rare, this check makes it impossible
    // (#1271 cloud review P2).
    if let finish = (json?["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String,
      finish == "length"
    {
      throw LLMError.egOneSkipped(.outputTruncated)
    }
    guard let choices = json?["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String,
      !content.isEmpty
    else {
      // A 200 with a malformed or empty body is still a LOCAL-server hiccup
      // — it must ride the silent family like every other EG-1 failure.
      // `LLMError.emptyResponse` here would surface the "AI polish failed"
      // pill + a Sentry capture, breaking the connector's own contract
      // (#1271 seam review P1, independently confirmed by Codex r10).
      throw LLMError.egOneSkipped(.crashed)
    }
    // Tag stripping ON: the EG-1 prompt is a SANDWICH path — the user
    // message wraps dictation in `<TRANSCRIPT>` tags the model can echo
    // (unlike the tag-free fixed cloud prompt, which passes false). A
    // dictated literal tag survives because `EGOnePromptBuilder` neutralizes
    // it with a zero-width non-joiner before it reaches the model
    // (#1271 Codex r4).
    let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
      .strippingLLMPreamble(stripTranscriptTags: true)
    // Emptiness gates on the CLEANED text (#1271 Codex r12): whitespace-only
    // or tags-only content passes the raw check above, then cleans down to
    // nothing — which would paste empty text instead of the raw fallback.
    guard !cleaned.isEmpty else {
      throw LLMError.egOneSkipped(.crashed)
    }
    return LLMResult(polishedText: cleaned)
  }
}
