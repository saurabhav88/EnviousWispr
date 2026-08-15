import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #158, Grounded Review R2/R3: `preWarmModel`'s key-selection logic used to
/// be a guard plus a SEPARATE two-way ternary (`provider == .openAI ?
/// openAIKeyID : geminiKeyID`) that would route Claude straight to the
/// Gemini key the moment the guard let it through. `warmupKeychainId(for:)`
/// is the extracted, pure replacement — this is the direct regression test
/// for that fix. No existing test file covered `preWarmModel`'s key
/// selection or `buildWarmupRequest`'s per-provider request shape at all.
@Suite("LLMNetworkSession warmup key selection and request shape")
struct LLMNetworkSessionWarmupTests {

  // MARK: - Key selection (the exact bug class this plan found repeatedly)

  @Test func openAIWarmsWithItsOwnKeyID() {
    #expect(LLMNetworkSession.warmupKeychainId(for: .openAI) == KeychainManager.openAIKeyID)
  }

  @Test func geminiWarmsWithItsOwnKeyID() {
    #expect(LLMNetworkSession.warmupKeychainId(for: .gemini) == KeychainManager.geminiKeyID)
  }

  @Test func claudeWarmsWithItsOwnKeyID() {
    #expect(LLMNetworkSession.warmupKeychainId(for: .claude) == KeychainManager.claudeKeyID)
  }

  @Test(arguments: [LLMProvider.ollama, .appleIntelligence, .egOne, .none])
  func nonCloudProvidersHaveNoWarmupKeyID(provider: LLMProvider) {
    #expect(LLMNetworkSession.warmupKeychainId(for: provider) == nil)
  }

  // MARK: - Request shape per provider

  @Test func claudeWarmupRequestCarriesAnthropicHeaders() {
    let request = LLMNetworkSession.shared.buildWarmupRequest(
      provider: .claude, model: "claude-haiku-4-5", apiKey: "sk-ant-test-key")
    #expect(request?.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(request?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test-key")
    #expect(request?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    // No Authorization/x-goog-api-key header — only the matching provider's
    // own auth header appears (the concrete regression this test guards).
    #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request?.value(forHTTPHeaderField: "x-goog-api-key") == nil)
  }

  @Test func openAIWarmupRequestCarriesBearerHeader() {
    let request = LLMNetworkSession.shared.buildWarmupRequest(
      provider: .openAI, model: "gpt-4o-mini", apiKey: "sk-openai-test-key")
    #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-openai-test-key")
    #expect(request?.value(forHTTPHeaderField: "x-api-key") == nil)
  }

  @Test func geminiWarmupRequestCarriesGoogleHeader() {
    let request = LLMNetworkSession.shared.buildWarmupRequest(
      provider: .gemini, model: "gemini-2.0-flash", apiKey: "gemini-test-key")
    #expect(request?.value(forHTTPHeaderField: "x-goog-api-key") == "gemini-test-key")
    #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
  }

  // MARK: - Warm-up literal caps stay independent of #1710 policy

  private func bodyJSON(_ request: URLRequest?) -> [String: Any]? {
    request?.httpBody.flatMap {
      try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
  }

  /// #2062 replaced this case's old assertion of `1`. The literal cap was NOT
  /// arbitrary-but-harmless: every `gpt-5.x` model rejects a ceiling of 1 with a
  /// real HTTP 400, because reasoning tokens are drawn from the same budget, and
  /// it produced 314 silent warm-up failures in 90 days. The cliff was measured
  /// against the live API at between 2 and 4 (see
  /// `openAIWarmupMaxCompletionTokens`); the value asserted here is the shipped
  /// one, so a revert to any sub-cliff literal turns this red.
  @Test func openAIWarmupBodyCapClearsTheReasoningModelFloor() {
    let request = LLMNetworkSession.shared.buildWarmupRequest(
      provider: .openAI, model: "gpt-4o-mini", apiKey: "sk-test")
    let cap = bodyJSON(request)?["max_completion_tokens"] as? Int
    #expect(cap == LLMNetworkSession.openAIWarmupMaxCompletionTokens)
    // Independent of the constant, so this cannot pass by restating the
    // production value back to itself: 4 is the measured 400/200 boundary.
    #expect((cap ?? 0) >= 4, "a ceiling at or below the measured cliff 400s on every gpt-5 model")
  }

  /// The reason the OpenAI cap moved and these two did not: neither provider
  /// rejects a ceiling of 1. Gemini's warm-up returned no `400` at all across the
  /// same 90-day window (only `429` quota and timeouts), and `claude_http_400`
  /// traced to one account with `out_of_credits`, not to request shape — verified
  /// live on 2026-08-15 against `claude-haiku-4-5` and `claude-sonnet-5`, both
  /// HTTP 200 on the exact shipped body. Raising them would spend real tokens on
  /// every session's ping to fix nothing.
  @Test func nonOpenAIWarmupCapsDeliberatelyStayAtOne() {
    let gemini = LLMNetworkSession.makeGeminiWarmupRequestBody()
    #expect((gemini["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int == 1)
    let claude = LLMNetworkSession.shared.buildWarmupRequest(
      provider: .claude, model: "claude-haiku-4-5", apiKey: "sk-ant-test")
    #expect(bodyJSON(claude)?["max_tokens"] as? Int == 1)
  }

  @Test func nonCloudProviderBuildsNoWarmupRequest() {
    let request = LLMNetworkSession.shared.buildWarmupRequest(
      provider: .ollama, model: "llama3.2", apiKey: "unused")
    #expect(request == nil)
  }

  // MARK: - #2062: the discarded failure body

  /// The body is logged to the DEBUG app log so a warm-up `400` is diagnosable
  /// at all. It is bounded and flattened because it lands in a rotating file a
  /// user may send us, and a provider can answer with an HTML error page.
  @Test func failureBodyRendersTheProviderMessage() {
    let body = Data(
      #"{"error":{"message":"Could not finish the message","type":"invalid_request_error"}}"#
        .utf8)
    let rendered = LLMNetworkSession.warmupFailureBodyForLog(body)
    #expect(rendered.contains("Could not finish the message"))
    #expect(rendered.contains("\n") == false, "the log line must stay one line")
  }

  @Test func failureBodyDistinguishesEmptyFromUnreadable() {
    #expect(LLMNetworkSession.warmupFailureBodyForLog(Data()) == "<empty>")
    // Lone continuation bytes: a body that exists and is not decodable. It must
    // not render as "<empty>", or "we got nothing back" and "we got something we
    // could not read" become the same log line and the same wrong diagnosis.
    let invalid = Data([0xFF, 0xFE, 0xFD])
    #expect(LLMNetworkSession.warmupFailureBodyForLog(invalid) == "<non-utf8 3 bytes>")
  }

  @Test func failureBodyIsBounded() {
    let huge = Data(String(repeating: "a", count: 4096).utf8)
    let rendered = LLMNetworkSession.warmupFailureBodyForLog(huge, limit: 64)
    #expect(rendered.count < 200, "an HTML error page must not flood the log")
    #expect(rendered.contains("truncated 4096 bytes"), "truncation must be visible, not silent")
  }
}
