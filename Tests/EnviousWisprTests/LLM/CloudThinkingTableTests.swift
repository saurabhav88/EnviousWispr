import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// The nine ids that answered 200 to `thinking: disabled` in the 2026-10-03 probes. Their
/// body must stay exactly what it was before this change. Expected strings are literals.
private let legacyClaudeIDs = [
  "claude-haiku-4-5", "claude-sonnet-5", "claude-opus-5", "claude-opus-4-5",
  "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-5",
  "claude-sonnet-4-6",
]

/// #3425: the per-model thinking decisions for Gemini, OpenAI and Claude.
///
/// Class: Drift Guard. When one of these fails, the user does NOT see a wrong
/// answer; a developer sees that a frozen request shape changed. The proof that the shapes
/// really work is the key-gated live sweeps (`GeminiLiveSweepTests`,
/// `OpenAILiveSweepTests`, `ClaudeLiveSweepTests`) and Live UAT, each of which polishes
/// real dictated sentences through the shipped connectors.
///
/// Every expected value below is an independent literal taken from the live probe
/// receipts in the plan (2026-10-03), never read back from the table under test.
@Suite("Cloud thinking tables (#3425)", .tags(.driftGuard))
struct CloudThinkingTableTests {

  // MARK: - Gemini

  @Test func gemini38FlashSendsLowAndTheBodyCarriesIt() {
    let capabilities = LLMProvider.gemini.modelCapabilities(model: "gemini-3.8-flash")
    #expect(capabilities.thinkingControl == .level("low"))
    // The level reaches the wire exactly as the 3.7 row's does.
    let config = LLMProviderConfig(
      model: "gemini-3.8-flash", apiKeyKeychainId: "gemini-api-key",
      outputTokens: .providerDefault, temperature: 0, thinking: .level("low"))
    let generationConfig = GeminiConnector.makeGenerationConfig(config: config)
    let thinkingConfig = generationConfig["thinkingConfig"] as? [String: String]
    #expect(thinkingConfig == ["thinkingLevel": "low"])
    // `minimal` is the value Google rejects for this model; it must never be chosen.
    #expect(capabilities.thinkingControl != .level("minimal"))
  }

  // MARK: - OpenAI: the gpt-6 generation

  @Test(arguments: ["gpt-6-luna", "gpt-6-sol", "gpt-6-astra", "gpt-6.1-sol"])
  func gpt6IdsAreReasoningShapedAndOmitTemperature(model: String) {
    let c = LLMProvider.openAI.modelCapabilities(model: model)
    #expect(c.thinkingControl != .unsupported)
    #expect(c.temperaturePolicy == .omit)
    #expect(c.supportsChatCompletions)
  }

  @Test func gpt6MatcherIsBoundedAndKeepsTheOldExceptions() {
    // A synthetic future id in the family gets the family's shape.
    let future = LLMProvider.openAI.modelCapabilities(model: "gpt-6-future")
    #expect(future.thinkingControl == .effort("low"))
    #expect(future.temperaturePolicy == .omit)
    // `gpt-60-future` is not GPT-6.
    let notGPT6 = LLMProvider.openAI.modelCapabilities(model: "gpt-60-future")
    #expect(notGPT6.thinkingControl == .unsupported)
    #expect(notGPT6.temperaturePolicy == .include)
    // The chat-variant exception applies to the new family too.
    let chat = LLMProvider.openAI.modelCapabilities(model: "gpt-6-chat-latest")
    #expect(chat.thinkingControl == .unsupported)
    // Endpoint eligibility stays independent.
    #expect(!LLMProvider.openAI.modelCapabilities(model: "gpt-6-pro").supportsChatCompletions)
    #expect(!LLMProvider.openAI.modelCapabilities(model: "gpt-6-codex").supportsChatCompletions)
  }

  // MARK: - OpenAI: fastest legal effort per exact id

  /// Probed live 2026-10-03: every one of these returned 200 at effort `none`.
  @Test(arguments: [
    "gpt-6-luna", "gpt-6-sol", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "gpt-5.5",
    "gpt-5.4", "gpt-5.4-mini", "gpt-5.2",
  ])
  func effortNoneWhereTheLiveProbeConfirmedIt(model: String) {
    #expect(LLMProvider.openAI.modelCapabilities(model: model).thinkingControl == .effort("none"))
  }

  /// `gpt-6-astra` and `gpt-6.1-sol` REJECT `none` (HTTP 400), so `low` is their floor; the
  /// rest were never probed, so they keep the value every user has always received.
  @Test(arguments: ["gpt-6-astra", "gpt-6.1-sol", "gpt-5", "gpt-5-mini", "gpt-5.1", "o3"])
  func effortLowForEverythingElse(model: String) {
    #expect(LLMProvider.openAI.modelCapabilities(model: model).thinkingControl == .effort("low"))
  }

  /// A dated snapshot gets its alias's value; the picker offers snapshots (discovery only
  /// filters `-001` style duplicates and `latest`).
  @Test func datedSnapshotsFollowTheirAlias() {
    func effort(_ model: String) -> LLMModelCapabilities.ThinkingControl {
      LLMProvider.openAI.modelCapabilities(model: model).thinkingControl
    }
    #expect(effort("gpt-5.5-2026-04-23") == .effort("none"))
    #expect(effort("gpt-5.4-mini-2026-03-17") == .effort("none"))
    #expect(effort("gpt-6-astra-2026-01-01") == .effort("low"))
    // Not a real date, or not a trailing date: no normalisation, so the unlisted id gets `low`.
    #expect(effort("gpt-5.5-2026-13-45") == .effort("low"))
    #expect(effort("gpt-5.5-turbo") == .effort("low"))
    #expect(effort("gpt-5.5-20260423") == .effort("low"))
    // Real Gregorian dates only: a leap day is a date, the others are not.
    #expect(effort("gpt-5.5-2024-02-29") == .effort("none"))
    #expect(effort("gpt-5.5-2025-02-29") == .effort("low"))
    #expect(effort("gpt-5.5-2026-02-31") == .effort("low"))
    #expect(effort("gpt-5.5-2026-04-31") == .effort("low"))
    // ASCII digits only: a sign is not a digit.
    #expect(effort("gpt-5.5-2026-+4-23") == .effort("low"))
    #expect(effort("gpt-5.5-+026-04-23") == .effort("low"))
  }

  @Test func openAIBodiesCarryTheChosenEffortAndNoTemperature() {
    func body(_ model: String) -> [String: Any] {
      var thinking: ResolvedThinking?
      if case .effort(let value) = LLMProvider.openAI.modelCapabilities(model: model)
        .thinkingControl
      {
        thinking = .effort(value)
      }
      let config = LLMProviderConfig(
        model: model, apiKeyKeychainId: "openai-api-key", outputTokens: .providerDefault,
        temperature: 0, thinking: thinking)
      return OpenAIConnector.makeRequestBody(
        config: config,
        messages: [["role": "system", "content": "s"], ["role": "user", "content": "u"]])
    }
    let luna = body("gpt-6-luna")
    #expect(luna["reasoning_effort"] as? String == "none")
    #expect(luna["temperature"] == nil)
    let sol61 = body("gpt-6.1-sol")
    #expect(sol61["reasoning_effort"] as? String == "low")
    #expect(sol61["temperature"] == nil)
  }

  // MARK: - Claude: frozen full bodies

  /// Canonical JSON with sorted keys, so the comparison is on bytes and cannot be
  /// satisfied by a body that merely contains the right keys.
  private func canonical(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  @Test(arguments: legacyClaudeIDs)
  func legacyClaudeBodyIsByteIdentical(model: String) {
    // Production shape: real system prompt, real cap.
    let production = ClaudeConnector.makeRequestBody(
      model: model, maxTokens: 8192, system: "s", userText: "u")
    #expect(
      canonical(production)
        == #"{"max_tokens":8192,"messages":[{"content":"u","role":"user"}],"model":"\#(model)","system":"s","thinking":{"type":"disabled"}}"#
    )
    // Picker probe shape: no system field, cap 5.
    let probe = ClaudeConnector.makeRequestBody(
      model: model, maxTokens: 5, system: nil, userText: "Hi")
    #expect(
      canonical(probe)
        == #"{"max_tokens":5,"messages":[{"content":"Hi","role":"user"}],"model":"\#(model)","thinking":{"type":"disabled"}}"#
    )
    // Warmup shape, decoded from the REAL warmup builder, not rebuilt by the test.
    let warmup = LLMNetworkSession.shared.buildWarmupRequest(
      provider: .claude, model: model, apiKey: "k")
    let sent = warmup?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
    #expect(
      (sent as? [String: Any]).map(canonical)
        == #"{"max_tokens":1,"messages":[{"content":".","role":"user"}],"model":"\#(model)","thinking":{"type":"disabled"}}"#
    )
  }

  @Test func sonnet55SendsBetweenToolsAndNoEffort() {
    let body = ClaudeConnector.makeRequestBody(
      model: "claude-sonnet-5-5", maxTokens: 8192, system: "s", userText: "u")
    #expect(
      canonical(body)
        == #"{"max_tokens":8192,"messages":[{"content":"u","role":"user"}],"model":"claude-sonnet-5-5","system":"s","thinking":{"type":"between_tools"}}"#
    )
  }

  @Test(arguments: ["claude-opus-5-5", "claude-fable-5", "claude-fable-5-1"])
  func alwaysThinkingClaudeModelsSendLowEffortAndNoThinkingField(model: String) {
    let body = ClaudeConnector.makeRequestBody(
      model: model, maxTokens: 8192, system: "s", userText: "u")
    #expect(
      canonical(body)
        == #"{"max_tokens":8192,"messages":[{"content":"u","role":"user"}],"model":"\#(model)","output_config":{"effort":"low"},"system":"s"}"#
    )
    #expect(body["thinking"] == nil)
  }

  @Test func newClaudeShapesReachTheProbeAndTheWarmupToo() {
    for (model, expected) in [
      (
        "claude-sonnet-5-5",
        #"{"max_tokens":1,"messages":[{"content":".","role":"user"}],"model":"claude-sonnet-5-5","thinking":{"type":"between_tools"}}"#
      ),
      (
        "claude-opus-5-5",
        #"{"max_tokens":1,"messages":[{"content":".","role":"user"}],"model":"claude-opus-5-5","output_config":{"effort":"low"}}"#
      ),
    ] {
      let warmup = LLMNetworkSession.shared.buildWarmupRequest(
        provider: .claude, model: model, apiKey: "k")
      let sent = warmup?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
      #expect((sent as? [String: Any]).map(canonical) == expected)
      // The picker probe builds through the same function with its own cap and no system.
      let probe = ClaudeConnector.makeRequestBody(
        model: model, maxTokens: 5, system: nil, userText: "Hi")
      #expect(probe["system"] == nil)
      #expect(probe["max_tokens"] as? Int == 5)
    }
  }

  @Test func unlistedClaudeIdKeepsTheDisabledBody() {
    // A future id nobody has probed keeps today's body; if Anthropic rejects it, the picker
    // probe hides it, exactly as before this change.
    let body = ClaudeConnector.makeRequestBody(
      model: "claude-future-9", maxTokens: 5, system: nil, userText: "Hi")
    #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
    #expect(body["output_config"] == nil)
  }

  // MARK: - Claude: replies that carry a thinking block

  @Test func thinkingBlockBeforeTextIsDroppedAndTheTextSurvives() throws {
    let reply = #"""
      {"content":[{"type":"thinking","thinking":"reasoning here","signature":"x"},
                  {"type":"text","text":"Hello there."}],"stop_reason":"end_turn"}
      """#
    let parsed = try ClaudeConnector.extractResponseText(from: Data(reply.utf8))
    #expect(parsed.text == "Hello there.")
    #expect(!parsed.truncated)
  }

  @Test func truncationAfterThinkingStaysTruncatedAndIsRejected() throws {
    let partial = #"""
      {"content":[{"type":"thinking","thinking":"long","signature":"x"},
                  {"type":"text","text":"Hello th"}],"stop_reason":"max_tokens"}
      """#
    let thinkingOnly = #"""
      {"content":[{"type":"thinking","thinking":"long","signature":"x"}],"stop_reason":"max_tokens"}
      """#
    let config = LLMProviderConfig(
      model: "claude-opus-5-5", apiKeyKeychainId: "anthropic-api-key",
      outputTokens: .capped(8192), temperature: 0, thinking: nil)
    for reply in [partial, thinkingOnly] {
      let parsed = try ClaudeConnector.extractResponseText(from: Data(reply.utf8))
      #expect(parsed.truncated)
      #expect(throws: LLMError.self) {
        try ClaudeConnector.rejectTruncationIfNeeded(truncated: parsed.truncated, config: config)
      }
    }
  }

  // MARK: - Claude: refusals

  /// Anthropic documents refusals that arrive with `content: []`. Both shapes must classify as
  /// a content block, never as the alerting empty-response class (#3425, Codex build r1).
  @Test(arguments: [
    #"{"content":[],"stop_reason":"refusal"}"#,
    #"{"content":[{"type":"text","text":"I cannot help with that."}],"stop_reason":"refusal"}"#,
  ])
  func refusalClassifiesAsContentBlockedWhetherOrNotItCarriesText(reply: String) {
    do {
      _ = try ClaudeConnector.extractResponseText(from: Data(reply.utf8))
      Issue.record("a refusal must throw")
    } catch LLMError.classified(let reason) {
      #expect(reason == .contentBlocked)
    } catch {
      Issue.record("expected classified(.contentBlocked), got \(error)")
    }
  }

  @Test func emptyContentWithoutARefusalMarkerStaysEmptyResponse() {
    do {
      _ = try ClaudeConnector.extractResponseText(
        from: Data(#"{"content":[],"stop_reason":"end_turn"}"#.utf8))
      Issue.record("empty content must throw")
    } catch LLMError.emptyResponse {
    } catch {
      Issue.record("expected emptyResponse, got \(error)")
    }
  }
}
