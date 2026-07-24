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

  @Test func openAIWarmupBodyKeepsLiteralCapOfOne() {
    let request = LLMNetworkSession.shared.buildWarmupRequest(
      provider: .openAI, model: "gpt-4o-mini", apiKey: "sk-test")
    #expect(bodyJSON(request)?["max_completion_tokens"] as? Int == 1)
  }

  @Test func geminiWarmupBodyKeepsLiteralCapOfOne() {
    let body = LLMNetworkSession.makeGeminiWarmupRequestBody()
    let generationConfig = body["generationConfig"] as? [String: Any]
    #expect(generationConfig?["maxOutputTokens"] as? Int == 1)
  }

  @Test func claudeWarmupBodyKeepsLiteralCapOfOne() {
    let request = LLMNetworkSession.shared.buildWarmupRequest(
      provider: .claude, model: "claude-haiku-4-5", apiKey: "sk-ant-test")
    #expect(bodyJSON(request)?["max_tokens"] as? Int == 1)
  }

  @Test func nonCloudProviderBuildsNoWarmupRequest() {
    let request = LLMNetworkSession.shared.buildWarmupRequest(
      provider: .ollama, model: "llama3.2", apiKey: "unused")
    #expect(request == nil)
  }
}
