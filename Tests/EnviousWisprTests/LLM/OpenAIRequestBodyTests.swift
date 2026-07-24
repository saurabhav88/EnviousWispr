import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

@Suite("OpenAI request body")
struct OpenAIRequestBodyTests {
  @Test func modelProbeRequestBodyUsesMaxCompletionTokens() {
    let body = LLMModelDiscovery.makeOpenAIProbeRequestBody(modelID: "gpt-5")
    #expect(body["max_completion_tokens"] as? Int == 5)
  }

  @Test func modelProbeRequestBodyDoesNotUseDeprecatedMaxTokens() {
    let body = LLMModelDiscovery.makeOpenAIProbeRequestBody(modelID: "gpt-5")
    #expect(body["max_tokens"] == nil)
  }

  @Test func modelProbeRequestBodyDisablesProviderLogging() {
    let body = LLMModelDiscovery.makeOpenAIProbeRequestBody(modelID: "gpt-5")
    #expect(body["store"] as? Bool == false)
  }

  @Test func modelProbeRequestBodyEchoesModelID() {
    let body = LLMModelDiscovery.makeOpenAIProbeRequestBody(modelID: "gpt-5-mini")
    #expect(body["model"] as? String == "gpt-5-mini")
  }

  // MARK: - Polish request body per family (#1330)

  private func config(
    model: String, reasoningEffort: String? = nil,
    outputTokens: OutputTokenPolicy = .capped(512)
  ) -> LLMProviderConfig {
    LLMProviderConfig(
      model: model, apiKeyKeychainId: "openai-api-key", outputTokens: outputTokens,
      temperature: 0, thinkingBudget: nil, reasoningEffort: reasoningEffort)
  }

  private let messages: [[String: String]] = [
    ["role": "system", "content": "polish"], ["role": "user", "content": "hello"],
  ]

  @Test func classicModelSendsTemperatureZeroAndNoEffort() {
    let body = OpenAIConnector.makeRequestBody(
      config: config(model: "gpt-4o-mini"), messages: messages)
    #expect(body["temperature"] as? Double == 0)
    #expect(body["reasoning_effort"] == nil)
    #expect(body["max_completion_tokens"] as? Int == 512)
    #expect(body["store"] as? Bool == false)
  }

  @Test func reasoningModelOmitsTemperatureAndSendsEffort() {
    let body = OpenAIConnector.makeRequestBody(
      config: config(model: "gpt-5.6-sol", reasoningEffort: "low"), messages: messages)
    #expect(body["temperature"] == nil)
    #expect(body["reasoning_effort"] as? String == "low")
  }

  @Test func reasoningModelWithoutEffortStillOmitsTemperature() {
    // The gpt-5.5 evidence: temperature is rejected even when no
    // reasoning-effort field is present, so omission is unconditional.
    let body = OpenAIConnector.makeRequestBody(
      config: config(model: "gpt-5.5"), messages: messages)
    #expect(body["temperature"] == nil)
    #expect(body["reasoning_effort"] == nil)
  }

  @Test func omittingSetRemovesParamsRegardlessOfFamily() {
    let body = OpenAIConnector.makeRequestBody(
      config: config(model: "gpt-4o-mini", reasoningEffort: "low"),
      messages: messages,
      omitting: ["temperature", "reasoning_effort"])
    #expect(body["temperature"] == nil)
    #expect(body["reasoning_effort"] == nil)
    // Never strippable: the request itself.
    #expect(body["model"] as? String == "gpt-4o-mini")
    #expect(body["max_completion_tokens"] as? Int == 512)
  }

  // MARK: - Output-token policy (#1710)

  @Test func providerDefaultOmitsMaxCompletionTokens() {
    let body = OpenAIConnector.makeRequestBody(
      config: config(model: "gpt-4o-mini", outputTokens: .providerDefault),
      messages: messages)
    #expect(body["max_completion_tokens"] == nil)
    #expect(body["max_tokens"] == nil)
  }

  @Test func cappedSerializesExactValue() {
    let body = OpenAIConnector.makeRequestBody(
      config: config(model: "gpt-4o-mini", outputTokens: .capped(777)),
      messages: messages)
    #expect(body["max_completion_tokens"] as? Int == 777)
  }

  // MARK: - Discovery candidate predicate (#1330)

  @Test(arguments: ["gpt-5.6-sol", "gpt-5.6-luna", "gpt-4o-mini", "o3", "o4-mini", "gpt-5.5"])
  func chatCapableModelsAreCandidates(id: String) {
    #expect(LLMModelDiscovery.isOpenAIChatCompletionCandidate(id))
  }

  @Test(arguments: [
    "gpt-5-pro", "gpt-5.5-pro-2026-04-23", "gpt-5-codex",
    "gpt-4o-realtime-preview", "gpt-4o-audio-preview", "gpt-5-search-api",
    "gpt-4o-transcribe", "dall-e-3", "text-embedding-3-small",
  ])
  func nonCandidatesAreExcluded(id: String) {
    #expect(!LLMModelDiscovery.isOpenAIChatCompletionCandidate(id))
  }
  // Alias ("latest") and version-duplicate ("-001") filtering is
  // deliberately NOT this predicate's job — `filterModels` owns it for all
  // providers, so gpt-5-chat-latest is excluded there, not here.
}
