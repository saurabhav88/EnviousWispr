import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLocalPolish
import Foundation

/// Localhost connector for S1-mini on the bundled server (#2649).
///
/// It exists for ONE reason, and the reason is worth stating because everything
/// else here is shared with EG-1: the two models disagree about what an empty
/// answer means. `EGOneConnector.parseSuccess` records an empty result as a
/// crash, which is right for a model told to rewrite a transcript. S1-mini's
/// published card says the opposite for its own model, and the shipped binary
/// agrees: filler-only input returns an empty string with `finish_reason: stop`.
///
/// Everything else — request body, bearer token, timeout, the single retry that
/// covers the restart-once window after a crash — comes from
/// `LocalPolishTransport`, so neither connector can drift from the other on the
/// parts where they agree.
/// (#4473: the transport now carries bytes only. The request body is still EG-1's one
/// builder, called from `send` below, and the shared response rules are
/// `LlamaServerChatResponse`.)
///
/// **No `<TRANSCRIPT>` tag stripping, deliberately.** `EGOneConnector` strips
/// those tags because `EGOnePromptBuilder` wraps the transcript in them and the
/// model can echo them back. S1-mini is sent a BARE transcript after its control
/// line, so there are no tags to echo, and stripping them would only be able to
/// damage a user who dictated the literal word.
public struct S1MiniConnector: TranscriptPolisher {
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

  /// #4473: the same request body as EG-1 (its one builder, not a second shape), serialized
  /// here and sent as bytes. The transport's one neutral failure maps to the silent bypass;
  /// the parse runs OUTSIDE that mapping so its own verdicts are never rewritten.
  private func send(
    system: String, user: String, config: LLMProviderConfig
  ) async throws -> LLMResult {
    let body = try EGOneConnector.makeRequestBody(
      system: system, user: user, config: config,
      hasLearnedWordAdapter: endpoint.hasLearnedWordAdapter)
    let bytes = try JSONSerialization.data(withJSONObject: body)
    let data: Data
    do {
      data = try await LocalPolishTransport.send(endpoint: endpoint, body: bytes)
    } catch LocalPolishTransportError.unavailable {
      throw LLMError.egOneSkipped(.crashed)
    }
    return try Self.parseSuccess(data: data, userMessage: user)
  }

  /// `internal` so tests drive it with a canned wire payload, the same seam
  /// `EGOneConnector.parseSuccess` offers.
  static func parseSuccess(data: Data, userMessage: String) throws -> LLMResult {
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

    // Shared with EG-1 and NOT restated here: a `length` finish means the
    // content is a partial rewrite. This is the guard a freshly authored
    // sibling connector drops without noticing, which is why it lives in the
    // transport rather than in each parser.
    // (#4473: it now lives in `LlamaServerChatResponse`, still shared by both.)
    try LlamaServerChatResponse.truncationGuard(json)

    guard let content = LlamaServerChatResponse.content(from: json) else {
      // A 200 with a malformed body is a local-server hiccup and rides the
      // silent family, exactly as EG-1's does.
      throw LLMError.egOneSkipped(.crashed)
    }

    let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !cleaned.isEmpty else {
      // THE delta. Empty is the correct answer to filler-only input, and a
      // failure otherwise. Deciding on the OUTPUT alone would have blinded the
      // `empty_response` signal that diagnosed #2634.
      switch LocalPolishEmptyDisposition.classify(
        input: S1ControlLineTranscript.transcript(fromUserMessage: userMessage))
      {
      case .validEmpty:
        // A correct empty result. The product's existing empty-output floor
        // takes it from here and the user keeps their deterministic text; what
        // must NOT happen is crash telemetry for a model doing its job.
        return LLMResult(polishedText: "")
      case .unexpectedEmpty:
        throw LLMError.egOneSkipped(.crashed)
      }
    }

    return LLMResult(polishedText: cleaned)
  }
}
