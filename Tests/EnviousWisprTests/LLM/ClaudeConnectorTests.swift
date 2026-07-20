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
  /// 400, so v1 never sends `temperature`, `thinking`, `top_p`, or `top_k` —
  /// unconditionally, not just for newer models.
  @Test func requestBodyNeverContainsSamplingParameters() {
    let body = ClaudeConnector.makeRequestBody(
      model: "claude-opus-4-8", maxTokens: 1024, system: "system prompt", userText: "text")

    #expect(body["temperature"] == nil)
    #expect(body["thinking"] == nil)
    #expect(body["top_p"] == nil)
    #expect(body["top_k"] == nil)
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
    // sampling parameter and both carry exactly the same key SHAPE (module
    // membership of `model`/`max_tokens`/`messages`, `system` only when
    // supplied) — a probe/production divergence would show up as a key
    // present in one but not accounted for by this shared contract.
    for body in [production, probe] {
      #expect(body["temperature"] == nil)
      #expect(body["thinking"] == nil)
      #expect(body["top_p"] == nil)
      #expect(body["top_k"] == nil)
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

  // MARK: - Status classification (#945 pattern)

  @Test func classify401IsApiKeyRejected() {
    #expect(ClaudeConnector.classify(statusCode: 401, bodyString: "") == .apiKeyRejected)
  }

  @Test func classify403IsAccessDenied() {
    #expect(ClaudeConnector.classify(statusCode: 403, bodyString: "") == .accessDenied)
  }

  @Test func classify404IsModelUnavailable() {
    #expect(ClaudeConnector.classify(statusCode: 404, bodyString: "") == .modelUnavailable)
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
}
