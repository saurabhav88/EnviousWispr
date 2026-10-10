import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

@Suite("OllamaConnector request body")
struct OllamaConnectorRequestBodyTests {

  private func makeBody(
    temperature: Double = 0.3, maxTokens: Int = 512, thinking: ResolvedThinking? = nil
  ) -> [String: Any] {
    OllamaConnector.makeRequestBody(
      model: "gemma4:latest",
      messages: [
        ["role": "system", "content": "sys"],
        ["role": "user", "content": "hello"],
      ],
      maxTokens: maxTokens,
      temperature: temperature,
      thinking: thinking
    )
  }

  /// #272's regression guard, RE-AIMED by #1914 rather than deleted. The defect
  /// it protects against is unchanged: a boolean `think: false` is silently
  /// ignored by gemma4 and gpt-oss and leaks chain-of-thought into
  /// `message.content` as a 5-13× expansion. What changed is the correct
  /// behaviour for a THINKING model — it now receives an explicit `"low"`
  /// instead of no key, because omission means the model's default depth, which
  /// starved the answer to empty in ENVIOUSWISPR-4M.
  @Test func nonThinkingModelSendsNoThinkKey() {
    let body = makeBody(thinking: nil)
    #expect(body["think"] == nil)
  }

  /// `think` is a TOP-LEVEL key on `/api/chat`, not an `options` entry. Placing
  /// it under `options` would be silently accepted by the daemon and silently
  /// ignored, which is indistinguishable from working.
  @Test func thinkIsTopLevelNotInsideOptions() {
    let body = makeBody(thinking: .level("low"))
    let options = body["options"] as? [String: Any]
    #expect(options?["think"] == nil)
    #expect(body["think"] as? String == "low")
  }

  /// Other providers' thinking dialects must not reach Ollama's wire format.
  /// A budget or effort value is a different provider's shape; emitting it here
  /// would send a key the daemon does not understand.
  @Test func nonLevelDialectsAreNotEmitted() {
    #expect(makeBody(thinking: .budget(1024))["think"] == nil)
    #expect(makeBody(thinking: .effort("high"))["think"] == nil)
  }

  @Test func requestBodyMapsOptions() {
    let body = makeBody(temperature: 0.42, maxTokens: 777)
    let options = body["options"] as? [String: Any]
    #expect(options?["num_predict"] as? Int == 777)
    #expect(options?["temperature"] as? Double == 0.42)
    #expect(body["stream"] as? Bool == false)
    #expect(body["model"] as? String == "gemma4:latest")
    let messages = body["messages"] as? [[String: String]]
    #expect(messages?.count == 2)
    #expect(messages?.first?["role"] == "system")
  }

  // MARK: - Eviction body (#295)

  /// Nothing else should be in the unload body — no streaming, no options,
  /// no messages. Keeps the call as narrow as possible.
  @Test func evictRequestBodyHasOnlyExpectedKeys() {
    let body = OllamaConnector.makeEvictRequestBody(model: "gemma4:latest")
    let keys = Set(body.keys)
    #expect(keys == Set(["model", "prompt", "keep_alive"]))
    #expect(body["model"] as? String == "gemma4:latest")
    #expect(body["keep_alive"] as? Int == 0)
    #expect(body["prompt"] as? String == "")
  }

  // MARK: - effectiveOllamaModel classifier (#295)

  @Test func effectiveOllamaModelReturnsModelWhenProviderIsOllama() {
    #expect(
      OllamaConnector.effectiveOllamaModel(provider: .ollama, model: "gemma4:latest")
        == "gemma4:latest"
    )
  }

  @Test func effectiveOllamaModelReturnsNilWhenProviderIsNotOllama() {
    #expect(
      OllamaConnector.effectiveOllamaModel(provider: .openAI, model: "gemma4:latest") == nil
    )
    #expect(
      OllamaConnector.effectiveOllamaModel(provider: .gemini, model: "gemma4:latest") == nil
    )
    #expect(
      OllamaConnector.effectiveOllamaModel(
        provider: .appleIntelligence, model: "apple-intelligence"
      ) == nil
    )
    #expect(
      OllamaConnector.effectiveOllamaModel(provider: .none, model: "") == nil
    )
  }

  @Test func effectiveOllamaModelReturnsNilWhenModelIsEmpty() {
    #expect(OllamaConnector.effectiveOllamaModel(provider: .ollama, model: "") == nil)
  }

  // MARK: - evictModel fire-and-forget guard (#295, hardened #901)

  /// Empty model names are a no-op — the guard must return before any network
  /// call. The old test only bounded wall-clock (< 0.5s) against a non-routable
  /// host, which a deleted `!modelName.isEmpty` guard still satisfied via fast
  /// ECONNREFUSED. This counts requests instead: empty name => zero calls.
  @Test("empty model name evicts without any network call")
  func evictModelWithEmptyNameMakesNoRequest() async {
    let counter = RequestCounter()
    let connector = OllamaConnector(networkExecutor: { _ in
      await counter.bump()
      throw URLError(.cannotConnectToHost)  // evict is fire-and-forget; the throw is ignored
    })
    await connector.evictModel("")
    #expect(await counter.count == 0)  // guard active: the network was never reached
  }

  /// The other side of the routing flip (`matcher-set-adversarial-tests`): a
  /// non-empty name must reach the network exactly once. Pins the guard from
  /// both sides so deleting it is caught regardless of which case regresses.
  @Test("non-empty model name evicts via exactly one network call")
  func evictModelWithNonEmptyNameMakesOneRequest() async {
    let counter = RequestCounter()
    let connector = OllamaConnector(networkExecutor: { _ in
      await counter.bump()
      throw URLError(.cannotConnectToHost)  // evict ignores the throw
    })
    await connector.evictModel("gemma4:latest")
    #expect(await counter.count == 1)
  }

  /// The polish call site must also route through the injected executor and
  /// surface a transport failure (not silently swallow it). The evict-only count
  /// tests can't catch a bad polish reroute.
  @Test("polish surfaces a transport failure through the injected executor")
  func polishSurfacesExecutorError() async {
    let counter = RequestCounter()
    let connector = OllamaConnector(networkExecutor: { _ in
      await counter.bump()
      throw URLError(.notConnectedToInternet)  // maps to providerUnavailable, fail-fast
    })
    let config = LLMProviderConfig(
      model: "gemma4:latest",
      apiKeyKeychainId: nil,
      outputTokens: .capped(128),
      temperature: 0.3,
      thinking: nil
    )
    await #expect(throws: LLMError.self) {
      _ = try await connector.polish(
        text: "hello",
        instructions: PolishInstructions(systemPrompt: "sys"),
        config: config,
        onToken: nil
      )
    }
    // The throw alone doesn't prove the polish path reached the network: a
    // pre-network guard (config validation, empty-model) throwing an LLMError
    // would also satisfy the expectation above. Counting the executor pins the
    // failure to the injected transport actually running — deleting the polish
    // reroute and hard-throwing earlier drops the count to 0 and reddens this.
    #expect(await counter.count == 1)
  }

  // MARK: - Output-token policy (#1710)

  @Test("capped policy value reaches num_predict exactly through the production polish path")
  func cappedValueReachesNumPredict() async throws {
    let captured = CapturedRequest()
    let connector = OllamaConnector(networkExecutor: { request in
      await captured.set(request)
      throw URLError(.notConnectedToInternet)  // stop after capturing the body
    })
    let config = LLMProviderConfig(
      model: "llama3.2",
      apiKeyKeychainId: nil,
      outputTokens: .capped(431),
      temperature: 0.3,
      thinking: nil
    )
    _ = try? await connector.polish(
      text: "hello",
      instructions: PolishInstructions(systemPrompt: "sys"),
      config: config,
      onToken: nil
    )
    let body = await captured.request?.httpBody.flatMap {
      try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    let options = body?["options"] as? [String: Any]
    #expect(options?["num_predict"] as? Int == 431)
  }

  @Test("providerDefault policy throws before any network call")
  func providerDefaultThrowsWithoutNetwork() async {
    let counter = RequestCounter()
    let connector = OllamaConnector(networkExecutor: { _ in
      await counter.bump()
      throw URLError(.notConnectedToInternet)
    })
    let config = LLMProviderConfig(
      model: "gemma4:latest",
      apiKeyKeychainId: nil,
      outputTokens: .providerDefault,
      temperature: 0.3,
      thinking: nil
    )
    let expected = LLMError.requestFailed(
      "Local polish requires an explicit output-token cap")
    await #expect(throws: expected) {
      _ = try await connector.polish(
        text: "hello",
        instructions: PolishInstructions(systemPrompt: "sys"),
        config: config,
        onToken: nil
      )
    }
    // Zero executor calls pins the throw to the pre-network guard.
    #expect(await counter.count == 0)
  }
}

/// Counts how many times the injected network executor is invoked. An actor so
/// the `@Sendable` executor closure can mutate it from any concurrency domain.
private actor CapturedRequest {
  var request: URLRequest?
  func set(_ r: URLRequest) { request = r }
}

private actor RequestCounter {
  private(set) var count = 0
  func bump() { count += 1 }
}
