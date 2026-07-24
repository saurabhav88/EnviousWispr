import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #158: request-body shape and status-code classification for the Claude
/// connector. Mirrors `GeminiRequestBodyTests.swift`'s scope — neither Gemini
/// nor Claude has an injectable transport seam (only `OpenAIConnector` does),
/// so full network round-trip coverage comes from the compatibility sweep
/// and Live UAT (plan §11.4/§11.1), not synthetic HTTP fixtures here.
/// `extractResponseText` IS a pure success-body parser, though (Codex r6),
/// so response-parsing edge cases (whitespace-only, truncation) are
/// unit-testable directly against `Data` literals without a transport seam.
@Suite("Claude request body and classification")
struct ClaudeConnectorTests {

  @Test func discoveryProbeShapeKeepsLiteralCapOfFive() {
    // Mirrors LLMModelDiscovery.probeClaude's builder call exactly.
    let body = ClaudeConnector.makeRequestBody(
      model: "claude-haiku-4-5", maxTokens: 5, system: nil, userText: "Hi")
    #expect(body["max_tokens"] as? Int == 5)
  }

  // MARK: - Output-token policy resolution (#1710)

  @Test func cappedPolicyResolvesToExactValue() {
    let resolved = ClaudeConnector.resolvedMaxTokens(.capped(700))
    #expect(resolved.value == 700)
    #expect(resolved.usedFallback == false)
  }

  @Test func providerDefaultPolicyFallsBackToRequiredConstant() {
    // The Anthropic API requires max_tokens; providerDefault is an invariant
    // breach mapped defensively, never a crash.
    let resolved = ClaudeConnector.resolvedMaxTokens(.providerDefault)
    #expect(resolved.value == LLMConstants.claudeMaxOutputTokens)
    #expect(resolved.value == 8192)
    #expect(resolved.usedFallback == true)
  }

  // MARK: - Request body shape

  @Test func requestBodyContainsRequiredFields() {
    let body = ClaudeConnector.makeRequestBody(
      model: "claude-haiku-4-5", maxTokens: 512, system: "polish this", userText: "hello there")

    #expect(body["model"] as? String == "claude-haiku-4-5")
    #expect(body["max_tokens"] as? Int == 512)
    #expect(body["system"] as? String == "polish this")

    let messages = body["messages"] as? [[String: String]]
    #expect(messages?.count == 1)
    #expect(messages?.first?["role"] == "user")
    #expect(messages?.first?["content"] == "hello there")
  }

  @Test func requestBodyOmitsSystemWhenNilOrEmpty() {
    let bodyNil = ClaudeConnector.makeRequestBody(
      model: "claude-haiku-4-5", maxTokens: 5, system: nil, userText: "Hi")
    #expect(bodyNil["system"] == nil)

    let bodyEmpty = ClaudeConnector.makeRequestBody(
      model: "claude-haiku-4-5", maxTokens: 5, system: "", userText: "Hi")
    #expect(bodyEmpty["system"] == nil)
  }

  /// The load-bearing assertion (plan §3 R1 correction): Claude generations
  /// released after Opus 4.6 reject a non-default `temperature` with an HTTP
  /// 400, so v1 never sends `temperature`, `top_p`, or `top_k` —
  /// unconditionally, not just for newer models.
  @Test func requestBodyNeverContainsSamplingParameters() {
    let body = ClaudeConnector.makeRequestBody(
      model: "claude-opus-4-8", maxTokens: 1024, system: "system prompt", userText: "text")

    #expect(body["temperature"] == nil)
    #expect(body["top_p"] == nil)
    #expect(body["top_k"] == nil)
  }

  /// GitHub cloud review P2 (PR #1712): several current models (e.g.
  /// claude-sonnet-5) default to Anthropic's "adaptive" thinking mode when
  /// `thinking` is omitted, silently spending thinking tokens the "no
  /// extended thinking, ever" design rules out. `thinking` must be sent,
  /// explicitly disabled — never omitted like the other sampling params.
  @Test func requestBodyExplicitlyDisablesThinking() {
    let body = ClaudeConnector.makeRequestBody(
      model: "claude-sonnet-5", maxTokens: 1024, system: "system prompt", userText: "text")

    let thinking = body["thinking"] as? [String: String]
    #expect(thinking?["type"] == "disabled")
  }

  /// Probe/production shared-builder parity (plan §3 R1 correction): the
  /// probe passes a small fixed prompt through the SAME builder production
  /// uses, so the two request shapes can never diverge (different `system`
  /// handling, different token budget, or a stray sampling parameter).
  @Test func probeAndProductionShareTheSameBuilderShape() {
    let production = ClaudeConnector.makeRequestBody(
      model: "claude-haiku-4-5", maxTokens: 700, system: "real system prompt",
      userText: "real dictated text")
    let probe = ClaudeConnector.makeRequestBody(
      model: "claude-haiku-4-5", maxTokens: 5, system: nil, userText: "Hi")

    // Both bodies come from the same builder, so both are free of any
    // omitted sampling parameter, both explicitly disable thinking, and
    // both carry exactly the same key SHAPE (module membership of
    // `model`/`max_tokens`/`messages`/`thinking`, `system` only when
    // supplied) — a probe/production divergence would show up as a key
    // present in one but not accounted for by this shared contract.
    for body in [production, probe] {
      #expect(body["temperature"] == nil)
      #expect(body["top_p"] == nil)
      #expect(body["top_k"] == nil)
      #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
      #expect(body["model"] != nil)
      #expect(body["max_tokens"] != nil)
      #expect(body["messages"] != nil)
    }
    #expect(production["system"] != nil)
    #expect(probe["system"] == nil)
  }

  // MARK: - Response text extraction (#158, Codex r6)

  private func responseJSON(text: String, stopReason: String = "end_turn") -> Data {
    let payload: [String: Any] = [
      "content": [["type": "text", "text": text]],
      "stop_reason": stopReason,
    ]
    return try! JSONSerialization.data(withJSONObject: payload)
  }

  @Test func extractResponseTextReturnsCleanText() throws {
    let data = responseJSON(text: "Cleaned up dictation.")
    let result = try ClaudeConnector.extractResponseText(from: data)
    #expect(result.text == "Cleaned up dictation.")
    #expect(result.truncated == false)
  }

  @Test func extractResponseTextFlagsMaxTokensTruncation() throws {
    let data = responseJSON(text: "This got cut off mid", stopReason: "max_tokens")
    let result = try ClaudeConnector.extractResponseText(from: data)
    #expect(result.text == "This got cut off mid")
    #expect(result.truncated == true)
  }

  @Test func extractResponseTextThrowsOnWhitespaceOnlyContent() {
    // The raw joined text is non-empty ("   \n  "), so a check against the
    // UNTRIMMED string would incorrectly treat this as success — this is
    // exactly the case the Codex r6 fix targets.
    let data = responseJSON(text: "   \n  ")
    #expect(throws: LLMError.self) {
      try ClaudeConnector.extractResponseText(from: data)
    }
  }

  @Test func extractResponseTextThrowsOnNoTextBlocks() {
    let payload: [String: Any] = [
      "content": [["type": "tool_use", "id": "x"]],
      "stop_reason": "end_turn",
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload)
    #expect(throws: LLMError.self) {
      try ClaudeConnector.extractResponseText(from: data)
    }
  }

  @Test func extractResponseTextThrowsOnMissingContentKey() {
    let data = try! JSONSerialization.data(withJSONObject: ["stop_reason": "end_turn"])
    #expect(throws: LLMError.self) {
      try ClaudeConnector.extractResponseText(from: data)
    }
  }

  @Test func extractResponseTextClassifiesRefusalAsContentBlocked() {
    // stop_reason: "refusal" still carries explanatory TEXT (unlike a
    // moderation refusal on other providers, which tends to leave content
    // empty and falls through to .emptyResponse) — without this check the
    // refusal text would pass every check above and be pasted as if it
    // were legitimate cleaned-up dictation (Codex r7).
    let data = responseJSON(
      text: "I can't help with that request.", stopReason: "refusal")
    #expect(throws: LLMError.classified(.contentBlocked)) {
      try ClaudeConnector.extractResponseText(from: data)
    }
  }

  // MARK: - Status classification (#945 pattern)

  @Test func classify401IsApiKeyRejected() {
    #expect(ClaudeConnector.classify(statusCode: 401, bodyString: "") == .apiKeyRejected)
  }

  @Test func classify402IsOutOfCredits() {
    // Documented, not guessed (Codex r3, PR #1712): Anthropic's dedicated
    // billing_error status, confirmed against
    // https://platform.claude.com/docs/en/api/errors.
    let body = #"{"type":"error","error":{"type":"billing_error","message":"..."}}"#
    #expect(ClaudeConnector.classify(statusCode: 402, bodyString: body) == .outOfCredits)
  }

  @Test func classify403IsAccessDenied() {
    #expect(ClaudeConnector.classify(statusCode: 403, bodyString: "") == .accessDenied)
  }

  @Test func classify404IsModelUnavailable() {
    #expect(ClaudeConnector.classify(statusCode: 404, bodyString: "") == .modelUnavailable)
  }

  @Test func classify413IsInputTooLong() {
    // Documented, not guessed (Codex r4, PR #1712): Anthropic's dedicated
    // request_too_large status for exceeding the Messages API's byte-size
    // limit, confirmed against
    // https://platform.claude.com/docs/en/api/errors#request-size-limits.
    let body = #"{"type":"error","error":{"type":"request_too_large","message":"..."}}"#
    #expect(ClaudeConnector.classify(statusCode: 413, bodyString: body) == .inputTooLong)
  }

  @Test func classify429IsRateLimited() {
    // Anthropic's rate_limit_error type is a clean signal (unlike Gemini's
    // ambiguous RESOURCE_EXHAUSTED), so no .rateLimitedOrQuota split is
    // needed — every 429 maps directly to .rateLimited.
    #expect(
      ClaudeConnector.classify(statusCode: 429, bodyString: "rate_limit_error") == .rateLimited)
  }

  @Test func classify400WithCreditBalanceIsOutOfCredits() {
    #expect(
      ClaudeConnector.classify(statusCode: 400, bodyString: "your credit balance is too low")
        == .outOfCredits)
  }

  @Test func classify400WithoutCreditBalanceIsBadRequest() {
    #expect(
      ClaudeConnector.classify(statusCode: 400, bodyString: "invalid_request_error")
        == .badRequest)
  }

  @Test func classify400WithPromptTooLongIsInputTooLong() {
    // Real observed body, 2026-07-20 (a live 250k-token overrun against the
    // founder's account): {"type":"error","error":{"type":"invalid_request_error",
    // "message":"prompt is too long: 250024 tokens > 200000 maximum"}} (Codex r7).
    let body =
      #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 250024 tokens > 200000 maximum"}}"#
    #expect(ClaudeConnector.classify(statusCode: 400, bodyString: body) == .inputTooLong)
  }

  @Test func classify400ForFable5ThinkingRejectionIsBadRequestNotCrash() {
    // Real observed body, 2026-07-20 (live call to claude-fable-5 with
    // thinking: disabled, GitHub cloud review r2, PR #1712): confirms the
    // generic 400 path handles this known per-model quirk safely (falls to
    // .badRequest, no special-case needed) rather than crashing or
    // misclassifying it as something actionable it is not.
    let body =
      #"{"type":"error","error":{"type":"invalid_request_error","message":"\"thinking.type.disabled\" is not supported for this model. Thinking defaults to adaptive mode when not specified; use \"thinking.type.enabled\" with \"budget_tokens\" for extended thinking."}}"#
    #expect(ClaudeConnector.classify(statusCode: 400, bodyString: body) == .badRequest)
  }

  @Test(arguments: [500, 502, 503, 529])
  func classify5xxIsProviderServerError(statusCode: Int) {
    // 529 is Anthropic's documented "overloaded" extension inside the 5xx
    // band — it needs no special case, the existing range check covers it.
    #expect(
      ClaudeConnector.classify(statusCode: statusCode, bodyString: "") == .providerServerError)
  }

  @Test func classifyOtherClientErrorIsBadRequest() {
    #expect(ClaudeConnector.classify(statusCode: 422, bodyString: "") == .badRequest)
  }

  @Test func classifyUnknownStatusIsUnknown() {
    #expect(ClaudeConnector.classify(statusCode: 999, bodyString: "") == .unknown)
  }

  // MARK: - Truncation rejection (#1710)

  private func truncConfig() -> LLMProviderConfig {
    LLMProviderConfig(
      model: "claude-haiku-4-5", apiKeyKeychainId: "claude-api-key",
      outputTokens: .capped(8192), temperature: 0, thinkingBudget: nil,
      reasoningEffort: nil)
  }

  @Test("stop_reason=max_tokens rejects through the production decision seam")
  func maxTokensStopReasonIsRejected() throws {
    // The exact two calls polish makes: real parser, then the same
    // rejection seam production feeds the truncated flag into.
    let body = Data(
      #"{"content": [{"type": "text", "text": "This got cut off mid"}], "stop_reason": "max_tokens"}"#
        .utf8)
    let extracted = try ClaudeConnector.extractResponseText(from: body)
    #expect(extracted.truncated == true)
    #expect(throws: LLMError.classified(.outputTruncated)) {
      try ClaudeConnector.rejectTruncationIfNeeded(
        truncated: extracted.truncated, config: truncConfig())
    }
  }

  @Test("normal end_turn passes the production decision seam untouched")
  func endTurnIsNotRejected() throws {
    let body = Data(
      #"{"content": [{"type": "text", "text": "Complete."}], "stop_reason": "end_turn"}"#.utf8)
    let extracted = try ClaudeConnector.extractResponseText(from: body)
    #expect(extracted.truncated == false)
    try ClaudeConnector.rejectTruncationIfNeeded(
      truncated: extracted.truncated, config: truncConfig())
  }


  @Test("max_tokens stop with empty text still reports truncated, not empty")
  func emptyMaxTokensIsTruncatedNotEmpty() throws {
    let body = Data(
      #"{"content": [{"type": "text", "text": ""}], "stop_reason": "max_tokens"}"#.utf8)
    let extracted = try ClaudeConnector.extractResponseText(from: body)
    #expect(extracted.truncated == true)
  }

}
