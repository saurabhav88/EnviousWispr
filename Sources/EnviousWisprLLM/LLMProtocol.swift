import EnviousWisprCore
import Foundation

/// Protocol for LLM-based transcript polishing.
public protocol TranscriptPolisher: Sendable {
  /// Polish a transcript using the configured LLM provider.
  /// - Parameters:
  ///   - onToken: Optional streaming callback invoked with each text fragment as it arrives.
  ///              Pass `nil` for batch (non-streaming) behavior.
  func polish(
    text: String,
    instructions: PolishInstructions,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult

  /// Polish using a structured PromptEnvelope (new prompt planner path).
  /// Connectors map roles to their API format. Default implementation bridges
  /// to the legacy method for Apple Intelligence (which never uses this path).
  func polish(
    envelope: PromptEnvelope,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult
}

extension TranscriptPolisher {
  /// Default bridge: extract single-turn pair and delegate to legacy method.
  /// Apple Intelligence connector relies on this default (never uses envelope path).
  public func polish(
    envelope: PromptEnvelope,
    config: LLMProviderConfig,
    onToken: (@Sendable (String) -> Void)?
  ) async throws -> LLMResult {
    let pair = envelope.asSingleTurn()
    let instructions = PolishInstructions(systemPrompt: pair?.system ?? "")
    let text = pair?.user ?? ""
    return try await polish(
      text: text, instructions: instructions, config: config, onToken: onToken)
  }
}

// MARK: - Preamble Stripping

extension String {
  /// Strip common LLM preamble/acknowledgment patterns from polished transcript output.
  ///
  /// Strategy (v30 — conservative):
  ///   1. Detect "wrapper shape" — either:
  ///      a) First line is short, ends with ":", and starts with an assistant
  ///         phrase (Here/Below/The corrected/etc.), OR
  ///      b) Acknowledgment prefix ("Sure,", "Certainly!") is IMMEDIATELY followed
  ///         by wrapper shape (a) on the remaining content.
  ///   2. Only strip when wrapper shape is present. This prevents false-stripping
  ///      user dictation that happens to start with "Sure, here is the plan..."
  ///      (which flows into prose without a colon).
  ///   3. Strip `<transcript>` wrapper tags if echoed back.
  func strippingLLMPreamble() -> String {
    var result = self.trimmingCharacters(in: .whitespacesAndNewlines)

    // Helper — does the first line look like an assistant-emitted preamble?
    // (short, ends with ":", starts with a wrapper phrase)
    func firstLineLooksLikePreamble(_ text: String) -> Bool {
      let firstNewline = text.firstIndex(of: "\n") ?? text.endIndex
      let firstLine = text[text.startIndex..<firstNewline]
      guard firstLine.count < 100, firstLine.hasSuffix(":"), !firstLine.isEmpty else {
        return false
      }
      let trimmedFirst = firstLine.trimmingCharacters(in: .whitespaces).lowercased()
      return
        trimmedFirst.hasPrefix("here")
        || trimmedFirst.hasPrefix("below")
        || trimmedFirst.hasPrefix("the corrected")
        || trimmedFirst.hasPrefix("the cleaned")
        || trimmedFirst.hasPrefix("the polished")
        || trimmedFirst.hasPrefix("the rewritten")
        || trimmedFirst.hasPrefix("corrected version")
        || trimmedFirst.hasPrefix("cleaned")
        || trimmedFirst.hasPrefix("polished")
    }

    // Does the first sentence after the acknowledgment look like a short
    // standalone reply (few clauses, short), as cloud LLMs typically produce?
    // This discriminates from user dictation that flows into multi-clause prose.
    // e.g. "I can help with that." (0 commas, 21 chars) => standalone reply.
    //      "here is the plan, we launch the beta on Tuesday..." (multi-comma,
    //       70+ chars) => user prose, do not strip.
    func firstSentenceIsStandaloneReply(_ text: String) -> Bool {
      guard !text.isEmpty else { return false }
      // Find end of first sentence (first . ! ? or newline).
      let terminators: Set<Character> = [".", "!", "?", "\n"]
      var firstSentence = ""
      for ch in text {
        firstSentence.append(ch)
        if terminators.contains(ch) { break }
      }
      let commaCount = firstSentence.filter { $0 == "," }.count
      // Standalone reply: ≤ 60 chars and at most 1 comma. Adjustable.
      return firstSentence.count <= 60 && commaCount <= 1
    }

    // Acknowledgment prefixes. Stripped when followed by EITHER:
    //   a) preamble-line wrapper shape ("Here is the transcript:\n...")
    //   b) short standalone reply ("I can help with that.")
    // Preserved when followed by user prose that flows with commas.
    let acknowledgments = [
      "Certainly!",
      "Sure!",
      "Sure,",
      "Of course!",
      "Got it.",
      "Got it!",
      "Absolutely!",
      "Here you go:",
    ]
    for ack in acknowledgments {
      if result.hasPrefix(ack) {
        let afterAck = String(result.dropFirst(ack.count))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if firstLineLooksLikePreamble(afterAck) || firstSentenceIsStandaloneReply(afterAck) {
          result = afterAck
        }
        break
      }
    }

    // Strip the first line if it looks like an assistant preamble.
    if firstLineLooksLikePreamble(result) {
      let firstNewline = result.firstIndex(of: "\n") ?? result.endIndex
      result = String(result[firstNewline...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Strip <transcript> wrapper if echoed back (may be truncated at token limit).
    // Case-insensitive so both <transcript> and <TRANSCRIPT> are handled.
    result = result.replacingOccurrences(
      of: "</?transcript>",
      with: "",
      options: [.regularExpression, .caseInsensitive]
    ).trimmingCharacters(in: .whitespacesAndNewlines)

    return result
  }
}

/// Errors that can occur during LLM operations.
public enum LLMError: LocalizedError, Sendable, Equatable {
  case invalidAPIKey
  case requestFailed(String)
  case rateLimited
  case emptyResponse
  case providerUnavailable
  case modelNotFound(String)
  case frameworkUnavailable(String)
  /// Input language is not supported by the selected provider. Distinct from
  /// `frameworkUnavailable` (global provider state): this fires per-request
  /// when a specific detected language is outside the provider's supported
  /// set. Pipeline falls back to raw text.
  case unsupportedInputLanguage(String)
  /// Post-generation validator detected that the output language differs
  /// from the expected input language (e.g. German input polished as
  /// English). Pipeline falls back to raw text silently; this signal is
  /// kept distinct from `requestFailed` so it never surfaces as "AI polish
  /// failed" in the UI.
  case outputLanguageDrift(expected: String, actual: String)

  public var errorDescription: String? {
    switch self {
    case .invalidAPIKey: return "Invalid API key."
    case .requestFailed(let msg): return "LLM request failed: \(msg)"
    case .rateLimited: return "Rate limited. Please try again later."
    case .emptyResponse: return "LLM returned an empty response."
    case .providerUnavailable: return "LLM provider is unavailable."
    case .modelNotFound(let model):
      return "Ollama model '\(model)' is not pulled. Run: ollama pull \(model)"
    case .frameworkUnavailable(let reason):
      return reason
    case .unsupportedInputLanguage(let code):
      return
        "Apple Intelligence does not support the input language '\(code)' for on-device polishing."
    case .outputLanguageDrift(let expected, let actual):
      return "LLM polish output drifted from expected language '\(expected)' to '\(actual)'."
    }
  }

  public static func == (lhs: LLMError, rhs: LLMError) -> Bool {
    switch (lhs, rhs) {
    case (.invalidAPIKey, .invalidAPIKey),
      (.rateLimited, .rateLimited),
      (.emptyResponse, .emptyResponse),
      (.providerUnavailable, .providerUnavailable):
      return true
    case (.requestFailed(let a), .requestFailed(let b)),
      (.modelNotFound(let a), .modelNotFound(let b)),
      (.frameworkUnavailable(let a), .frameworkUnavailable(let b)),
      (.unsupportedInputLanguage(let a), .unsupportedInputLanguage(let b)):
      return a == b
    case (.outputLanguageDrift(let le, let la), .outputLanguageDrift(let re, let ra)):
      return le == re && la == ra
    default:
      return false
    }
  }
}
