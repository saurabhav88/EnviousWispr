import Foundation
import Testing

@testable import EnviousWisprLLM

/// #945: the per-connector pure `classify(statusCode:bodyString:)` functions.
/// These split the ambiguous pairs (out-of-credits vs rate-limited; too-long vs
/// generic 400; rejected-key) from real HTTP status + body fixtures, with no
/// network mocking — the whole point of keeping classification a pure function.
@Suite("Connector classify")
struct ConnectorClassifyTests {

  // MARK: - OpenAI

  @Test("OpenAI 429 insufficient_quota -> out of credits (the mislabel bug fix)")
  func openAIQuota() {
    let body = #"{"error":{"type":"insufficient_quota","message":"You exceeded your quota"}}"#
    #expect(OpenAIConnector.classify(statusCode: 429, bodyString: body) == .outOfCredits)
  }

  @Test("OpenAI 429 rate limit (no quota marker) -> rate limited")
  func openAIRate() {
    let body = #"{"error":{"type":"rate_limit_exceeded","message":"Rate limit reached"}}"#
    #expect(OpenAIConnector.classify(statusCode: 429, bodyString: body) == .rateLimited)
  }

  @Test("OpenAI 401 -> key rejected")
  func openAI401() {
    #expect(OpenAIConnector.classify(statusCode: 401, bodyString: "") == .apiKeyRejected)
  }

  @Test("OpenAI 403 -> access denied")
  func openAI403() {
    #expect(OpenAIConnector.classify(statusCode: 403, bodyString: "") == .accessDenied)
  }

  @Test("OpenAI 404 -> model unavailable")
  func openAI404() {
    #expect(OpenAIConnector.classify(statusCode: 404, bodyString: "") == .modelUnavailable)
  }

  @Test("OpenAI 400 context_length_exceeded -> input too long")
  func openAIContextLength() {
    let body = #"{"error":{"code":"context_length_exceeded","message":"maximum context length"}}"#
    #expect(OpenAIConnector.classify(statusCode: 400, bodyString: body) == .inputTooLong)
  }

  @Test("OpenAI 400 content filter -> content blocked")
  func openAIContentFilter() {
    let body = #"{"error":{"code":"content_filter","message":"flagged by content management"}}"#
    #expect(OpenAIConnector.classify(statusCode: 400, bodyString: body) == .contentBlocked)
  }

  @Test("OpenAI 400 generic param error -> bad request (NOT input-too-long)")
  func openAI400Generic() {
    let body = #"{"error":{"type":"invalid_request_error","param":"temperature"}}"#
    #expect(OpenAIConnector.classify(statusCode: 400, bodyString: body) == .badRequest)
  }

  @Test("OpenAI 500/503 -> provider server error")
  func openAI5xx() {
    #expect(OpenAIConnector.classify(statusCode: 500, bodyString: "") == .providerServerError)
    #expect(OpenAIConnector.classify(statusCode: 503, bodyString: "") == .providerServerError)
  }

  @Test("OpenAI unexpected status -> unknown")
  func openAIUnknown() {
    #expect(OpenAIConnector.classify(statusCode: 600, bodyString: "") == .unknown)
  }

  // MARK: - Gemini

  @Test("Gemini 400 API_KEY_INVALID -> key rejected")
  func geminiKeyInvalid() {
    let body = #"{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"API_KEY_INVALID"}}"#
    #expect(GeminiConnector.classify(statusCode: 400, bodyString: body) == .apiKeyRejected)
  }

  @Test("Gemini 403 PERMISSION_DENIED -> access denied (was mislabeled invalid key)")
  func gemini403() {
    let body = #"{"error":{"code":403,"status":"PERMISSION_DENIED"}}"#
    #expect(GeminiConnector.classify(statusCode: 403, bodyString: body) == .accessDenied)
  }

  @Test("Gemini 429 RESOURCE_EXHAUSTED -> rate-or-quota (honest, never plain rate)")
  func gemini429() {
    let body = #"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}"#
    #expect(GeminiConnector.classify(statusCode: 429, bodyString: body) == .rateLimitedOrQuota)
  }

  @Test("Gemini 400 token-limit message -> input too long")
  func geminiTokens() {
    let body =
      #"{"error":{"message":"The input token count exceeds the maximum number of tokens allowed"}}"#
    #expect(GeminiConnector.classify(statusCode: 400, bodyString: body) == .inputTooLong)
  }

  @Test("Gemini 400 prohibited content -> content blocked (best-effort)")
  func geminiBlocked() {
    let body = #"{"error":{"message":"blockReason: PROHIBITED_CONTENT"}}"#
    #expect(GeminiConnector.classify(statusCode: 400, bodyString: body) == .contentBlocked)
  }

  @Test("Gemini 404 -> model unavailable")
  func gemini404() {
    #expect(GeminiConnector.classify(statusCode: 404, bodyString: "") == .modelUnavailable)
  }

  @Test("Gemini 503 -> provider server error")
  func gemini5xx() {
    #expect(GeminiConnector.classify(statusCode: 503, bodyString: "") == .providerServerError)
  }

  // MARK: - Ollama

  @Test("Ollama 404 -> model unavailable (not pulled)")
  func ollama404() {
    #expect(OllamaConnector.classify(statusCode: 404, bodyString: "") == .modelUnavailable)
  }

  @Test("Ollama 5xx -> provider server error (stays retryable)")
  func ollama5xx() {
    let reason = OllamaConnector.classify(statusCode: 500, bodyString: "")
    #expect(reason == .providerServerError)
    #expect(reason.isRetryable)
  }

  @Test("Ollama 400 -> bad request (not retryable)")
  func ollama400() {
    let reason = OllamaConnector.classify(statusCode: 400, bodyString: "")
    #expect(reason == .badRequest)
    #expect(!reason.isRetryable)
  }
}
