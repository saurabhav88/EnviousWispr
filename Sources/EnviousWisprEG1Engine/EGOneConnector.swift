import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLocalPolish
import Foundation

/// EG-1's polish connector for the EnviousDecode helper (#4473 P2).
///
/// It sends the one request the helper serves: `model`, a system turn and a user turn,
/// `max_tokens` and `temperature`. The helper refuses any field it does not know, so nothing
/// else is sent: no adapter field and no slot number. The learned-word check does not ride
/// polish requests on this engine, so `LocalPolishEndpoint.hasLearnedWordAdapter` is not read.
///
/// What an answer MEANS is EG-1's contract and is the same as on the llama engine: an answer
/// that stopped at the token cap is a partial rewrite and is skipped whole, an empty or
/// malformed answer is a local hiccup, and every failure rides the SILENT bypass family, so a
/// dictation is pasted without polish and never shows an "AI polish failed" pill. Chatter is
/// removed by the caller that holds the dictation (`LLMResult.removingModelChatter`).
///
/// The llama engine has a connector of the same name for the same model; the two live in
/// modules that never import each other. Stateless: it reads the endpoint per call and never
/// owns the process (that is `LocalPolishProcessManager`).
public struct EGOneConnector: TranscriptPolisher {
  private let endpoint: LocalPolishEndpoint

  public init(endpoint: LocalPolishEndpoint) {
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

  /// The request body. Static and pure, so a test reads it without a helper. EG-1's truncation
  /// policy depends on its computed cap; an uncapped request is an invariant breach and throws
  /// through the ordinary limb-failure path.
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

  /// The neutral transport carries the bytes and reports one failure, which is the silent
  /// bypass here. A request the helper refuses (HTTP 400) is that same failure. The parse runs
  /// OUTSIDE that mapping, so the parser's own verdict (truncated, malformed, empty) is never
  /// rewritten into a transport failure.
  private func send(
    system: String, user: String, config: LLMProviderConfig
  ) async throws -> LLMResult {
    let body = try Self.makeRequestBody(system: system, user: user, config: config)
    let bytes = try JSONSerialization.data(withJSONObject: body)
    let data: Data
    do {
      data = try await LocalPolishTransport.send(endpoint: endpoint, body: bytes)
    } catch LocalPolishTransportError.unavailable {
      throw LLMError.egOneSkipped(.crashed)
    }
    return try Self.parseSuccess(data: data)
  }

  /// `internal` (not private) so a test drives it with a canned wire payload.
  static func parseSuccess(data: Data) throws -> LLMResult {
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let choice = (json?["choices"] as? [[String: Any]])?.first
    // `finish_reason: length` means generation stopped at the cap (or at the end of the
    // context): the content is a PARTIAL rewrite. Accepting it would paste a truncated polish.
    if choice?["finish_reason"] as? String == "length" {
      throw LLMError.egOneSkipped(.outputTruncated)
    }
    guard let message = choice?["message"] as? [String: Any],
      let content = message["content"] as? String, !content.isEmpty
    else {
      // A 200 with a malformed or empty body is still a local hiccup: the silent family, not
      // `LLMError.emptyResponse`, which would show the "AI polish failed" pill.
      throw LLMError.egOneSkipped(.crashed)
    }
    // Tag stripping ON: the EG-1 prompt wraps the dictation in `<TRANSCRIPT>` tags the model
    // can echo. A dictated literal tag survives because `EGOnePromptBuilder` neutralizes it
    // before it reaches the model.
    let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
      .strippingTranscriptTags()
    // Emptiness is judged on the CLEANED text: whitespace-only or tags-only content must not
    // be pasted as an empty polish.
    guard !cleaned.isEmpty else {
      throw LLMError.egOneSkipped(.crashed)
    }
    return LLMResult(polishedText: cleaned, localDecode: decodeStats(json))
  }

  /// The helper's `x_decode` object (#4473). A helper that sends none (an older build) gives
  /// nil: the engine is then unknown, never assumed.
  static func decodeStats(_ json: [String: Any]?) -> LocalDecodeStats? {
    guard let decode = json?["x_decode"] as? [String: Any],
      let implementation = decode["implementation"] as? String, !implementation.isEmpty
    else { return nil }
    return LocalDecodeStats(
      implementation: implementation,
      draftProposedTokens: decode["draft_proposed"] as? Int,
      draftAcceptedTokens: decode["draft_accepted"] as? Int,
      emittedTokens: decode["emitted_tokens"] as? Int)
  }
}
