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
  ///   3. Strip `<transcript>` wrapper tags if echoed back — ONLY when
  ///      `stripTranscriptTags` is true. That cleanup exists for the sandwich
  ///      prompt paths (Ollama, Apple) whose user message wraps the transcript in
  ///      `<transcript>` tags the model can echo. The fixed cloud prompt (#1255)
  ///      sends NO sandwich, so stripping those tags there would delete a user's
  ///      literal dictated `<transcript>` text (XML, prompt notes); cloud callers
  ///      pass `false` (Codex code-review r5).
  func strippingLLMPreamble(stripTranscriptTags: Bool = true) -> String {
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
    // Case-insensitive so both <transcript> and <TRANSCRIPT> are handled. Skipped on
    // the no-sandwich cloud path so literal dictated tags survive (see doc above).
    if stripTranscriptTags {
      result = result.replacingOccurrences(
        of: "</?transcript>",
        with: "",
        options: [.regularExpression, .caseInsensitive]
      ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
  /// The selected on-device Apple Intelligence model is enabled but not usable
  /// right now — still downloading, or restricted by organization policy.
  /// Distinct from `frameworkUnavailable`, which is the PERMANENT "this Mac or
  /// build cannot run Apple Intelligence" state (pre-macOS-26, switched off,
  /// ineligible hardware, not compiled in). `modelNotReady` is TRANSIENT and may
  /// resolve on its own, so the live dictation path keeps surfacing it (the user
  /// learns why polish is temporarily unavailable) instead of silently degrading
  /// to raw text the way the permanent cases do. (#1080)
  case modelNotReady(String)
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
  /// EG-1 (first-party local server) per-request unavailability (#1271).
  /// Semantics: BYPASS, exactly like the AFM silent-skip family — the user
  /// gets deterministic-cleaned raw text, no provider stamp, no "AI polish
  /// failed" pill. The runner adds this to `isSilentPolishSkip` and emits
  /// `llm.polish_skipped` with the carried reason. NON-retryable by
  /// `LLMRetryPolicy` (the connector already performs the single
  /// connection-refused retry that covers the restart-once window).
  case egOneSkipped(EGOneSkipReason)
  /// #1305: the Ollama readiness preflight found local polish not usable —
  /// server down (`.providerUnreachable`) or armed model not installed
  /// (`.modelUnavailable`). Thrown by the `LLMPolishStep` entry gate BEFORE any
  /// polisher construction or connector retry loop. Semantics: a SURFACED SKIP,
  /// the third class between Failure and Bypass — `polishedText` nil, no
  /// provider stamp, user notice YES (skipped tone, pinned copy in
  /// `PolishFailureReason.ollamaPreflightSkipMessage`), Sentry capture NO,
  /// PostHog `llm.polish_skipped` YES. Non-retryable by `LLMRetryPolicy`.
  case localPolishNotReady(PolishFailureReason)
  /// A cloud/Ollama polish failure carrying its specific classified reason
  /// (#945). The single adapter that threads the rich `PolishFailureReason`
  /// catalog through the existing `throws LLMError` contract: connectors throw
  /// this on the polish path, and the runner unwraps it for the on-screen notice
  /// and the telemetry reason tag. The pre-existing specific cases stay for the
  /// Settings model-discovery path and backward compatibility.
  case classified(PolishFailureReason)

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
    case .modelNotReady(let reason):
      return reason
    case .unsupportedInputLanguage(let code):
      return
        "Apple Intelligence does not support the input language '\(code)' for on-device polishing."
    case .outputLanguageDrift(let expected, let actual):
      return "LLM polish output drifted from expected language '\(expected)' to '\(actual)'."
    case .egOneSkipped(let reason):
      // Silent bypass — never an on-screen notice; log/debug reads only.
      return "EG-1 polish skipped (\(reason.rawValue))."
    case .localPolishNotReady(let reason):
      // Surfaced skip (#1305) — the on-screen notice is the pinned copy in
      // `PolishFailureReason.ollamaPreflightSkipMessage`, composed by the
      // runner. This generic description exists only for logs.
      return "Local polish not ready (\(reason.telemetryTag))."
    case .classified(let reason):
      // The user-facing, provider-specific notice is composed by the runner via
      // `reason.composedMessage(provider:)`. This generic description exists only
      // for logs / incidental `localizedDescription` reads where no provider is
      // known — it is never the on-screen notice.
      return "AI polish failed (\(reason.telemetryTag))."
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
      (.modelNotReady(let a), .modelNotReady(let b)),
      (.unsupportedInputLanguage(let a), .unsupportedInputLanguage(let b)):
      return a == b
    case (.outputLanguageDrift(let le, let la), .outputLanguageDrift(let re, let ra)):
      return le == re && la == ra
    case (.egOneSkipped(let a), .egOneSkipped(let b)):
      return a == b
    case (.localPolishNotReady(let a), .localPolishNotReady(let b)):
      return a == b
    case (.classified(let a), .classified(let b)):
      return a == b
    default:
      return false
    }
  }
}

// MARK: - Sentry identity

/// Pins each case's Sentry grouping key to the exact string it has been
/// sending in production, so the identity survives any future add/remove of
/// a case (#1525 PR E; mirrors `HeartPathError`/`OutputClassifierError`).
///
/// The 13 descriptors below are NOT derived — they were MEASURED against
/// shipping code (both a throwaway `swift test` and the canonical
/// `scripts/xcode-test.sh` Xcode-engine run agree) and cross-checked against
/// live Sentry issue titles (`docs/audits/2026-07-14-1525-pr-e-preflight.md`).
/// The bridged codes do NOT follow source declaration order — they group by
/// associated-value payload shape, sequential by declaration order within
/// each shape group. Live data proves this has already drifted release to
/// release for `.classified` (`#6` on dist 2.2.1, `#8` on dist 2.3.1) — this
/// pin freezes it going forward.
///
/// NEVER change any of these shipped `sentryFingerprintDescriptor` values:
/// doing so would split an existing production Sentry issue's history in
/// two. A NEW case gets a fresh unused number, never a reused one. Both
/// switches are exhaustive, so a new case cannot compile until it declares
/// its own identity here.
extension LLMError: StableSentryErrorIdentity {
  public var sentryFingerprintDescriptor: String {
    switch self {
    case .requestFailed: return "EnviousWisprLLM.LLMError#0"
    case .modelNotFound: return "EnviousWisprLLM.LLMError#1"
    case .frameworkUnavailable: return "EnviousWisprLLM.LLMError#2"
    case .modelNotReady: return "EnviousWisprLLM.LLMError#3"
    case .unsupportedInputLanguage: return "EnviousWisprLLM.LLMError#4"
    case .outputLanguageDrift: return "EnviousWisprLLM.LLMError#5"
    case .egOneSkipped: return "EnviousWisprLLM.LLMError#6"
    case .localPolishNotReady: return "EnviousWisprLLM.LLMError#7"
    case .classified: return "EnviousWisprLLM.LLMError#8"
    case .invalidAPIKey: return "EnviousWisprLLM.LLMError#9"
    case .rateLimited: return "EnviousWisprLLM.LLMError#10"
    case .emptyResponse: return "EnviousWisprLLM.LLMError#11"
    case .providerUnavailable: return "EnviousWisprLLM.LLMError#12"
    }
  }

  public var sentrySemanticID: String {
    switch self {
    case .requestFailed: return "llm.request_failed"
    case .modelNotFound: return "llm.model_not_found"
    case .frameworkUnavailable: return "llm.framework_unavailable"
    case .modelNotReady: return "llm.model_not_ready"
    case .unsupportedInputLanguage: return "llm.unsupported_input_language"
    case .outputLanguageDrift: return "llm.output_language_drift"
    case .egOneSkipped: return "llm.eg_one_skipped"
    case .localPolishNotReady: return "llm.local_polish_not_ready"
    case .classified: return "llm.classified"
    case .invalidAPIKey: return "llm.invalid_api_key"
    case .rateLimited: return "llm.rate_limited"
    case .emptyResponse: return "llm.empty_response"
    case .providerUnavailable: return "llm.provider_unavailable"
    }
  }
}

/// Why an EG-1 polish was silently bypassed (#1271). Raw values are the
/// `llm.polish_skipped` telemetry reason strings — one `local_polish_`
/// prefix so a single analytics query captures every EG-1 skip mode
/// (mirrors the AFM `context_window_` prefix family).
public enum EGOneSkipReason: String, Sendable, Equatable {
  /// Provider selected but no runtime handle / server not ready (booting,
  /// paused for memory pressure, or failed).
  case notReady = "local_polish_not_ready"
  /// Model artifact not downloaded/verified yet.
  case downloadPending = "local_polish_download_pending"
  /// Server unreachable mid-request (crashed; connector already retried
  /// once to cover the restart window).
  case crashed = "local_polish_crashed"
  /// Input exceeds the manifest context budget — polish whole or not at
  /// all, never a silent truncation.
  case inputTooLong = "local_polish_input_too_long"
  /// The server stopped generation at the max_tokens cap
  /// (finish_reason == length): the content is a PARTIAL rewrite, and
  /// pasting it would be exactly the silent truncation the contract
  /// forbids (#1271 cloud review). Skip whole → raw fallback.
  case outputTruncated = "local_polish_output_truncated"
}
