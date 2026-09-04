import EnviousWisprCore
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
///
/// **No `<TRANSCRIPT>` tag stripping, deliberately.** `EGOneConnector` strips
/// those tags because `EGOnePromptBuilder` wraps the transcript in them and the
/// model can echo them back. S1-mini is sent a BARE transcript after its control
/// line, so there are no tags to echo, and stripping them would only be able to
/// damage a user who dictated the literal word.
public struct S1MiniConnector: TranscriptPolisher {
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

  private func send(
    system: String, user: String, config: LLMProviderConfig
  ) async throws -> LLMResult {
    try await LocalPolishTransport.send(
      endpoint: endpoint, system: system, user: user, config: config,
      parse: { try Self.parseSuccess(data: $0, userMessage: user) })
  }

  /// The transcript this request carried, recovered from the user message.
  ///
  /// The empty-answer rule needs the INPUT, and the user message is
  /// `controlLine + "\n" + transcript` by construction
  /// (`S1ControlLinePromptBuilder`). Dropping the first line recovers it without
  /// threading a second parameter through the transport, which would have made
  /// the shared path know about one model's prompt shape.
  ///
  /// If the shape is ever not what this expects, the WHOLE user message is used
  /// instead. That fails toward `unexpectedEmpty`, which is the safe direction:
  /// the control line contains ordinary words, so a malformed message can only
  /// ever make an empty answer look like a failure, never like a valid empty.
  static func transcript(fromUserMessage message: String) -> String {
    guard let newline = message.firstIndex(of: "\n"),
      message[message.startIndex..<newline].hasPrefix("[Styling:")
    else { return message }
    return String(message[message.index(after: newline)...])
  }

  /// `internal` so tests drive it with a canned wire payload, the same seam
  /// `EGOneConnector.parseSuccess` offers.
  static func parseSuccess(data: Data, userMessage: String) throws -> LLMResult {
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

    // Shared with EG-1 and NOT restated here: a `length` finish means the
    // content is a partial rewrite. This is the guard a freshly authored
    // sibling connector drops without noticing, which is why it lives in the
    // transport rather than in each parser.
    try LocalPolishTransport.truncationGuard(json)

    guard let content = LocalPolishTransport.content(from: json) else {
      // A 200 with a malformed body is a local-server hiccup and rides the
      // silent family, exactly as EG-1's does.
      throw LLMError.egOneSkipped(.crashed)
    }

    let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
      .strippingLLMPreamble(stripTranscriptTags: false)

    guard !cleaned.isEmpty else {
      // THE delta. Empty is the correct answer to filler-only input, and a
      // failure otherwise. Deciding on the OUTPUT alone would have blinded the
      // `empty_response` signal that diagnosed #2634.
      switch LocalPolishEmptyDisposition.classify(
        input: Self.transcript(fromUserMessage: userMessage))
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
