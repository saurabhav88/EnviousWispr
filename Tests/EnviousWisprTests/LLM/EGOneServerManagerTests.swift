import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprEG1Engine
@testable import EnviousWisprLLM
@testable import EnviousWisprLlamaEngine
@testable import EnviousWisprLocalPolish
import EnviousWisprAppKitTestSupport

/// EG-1 server lifecycle with a FAKE binary (#1271) — spawn, crash,
/// restart-once, missing-binary/model, port strategy. No real model, no
/// network inference; the real-binary integration validation is a separate
/// PR-1a obligation.
@Suite("EGOneServerManager (#1271)", .serialized)
struct EGOneServerManagerTests {

  /// A fake "server" configuration. The default binary (`/bin/sleep`)
  /// rejects the llama-style arguments and exits immediately — a process
  /// that dies during startup. The readiness budget is shrunk to seconds so
  /// never-healthy cases fail fast (the manager also bails as soon as the
  /// child dies, so these tests do not burn the budget at all).
  static func fakeServerConfiguration(
    modelExists: Bool = true, serverBinaryURL: URL = URL(fileURLWithPath: "/bin/sleep")
  ) throws -> LocalPolishProcessManager.Configuration {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("eg1-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let model = dir.appendingPathComponent("model.gguf")
    if modelExists {
      try Data("fake".utf8).write(to: model)
    }
    return LocalPolishProcessManager.Configuration(
      spec: .fixture(serverBinaryURL: serverBinaryURL, modelURL: model, contextTokens: 4096),
      makeLaunch: LlamaServerLaunchBuilder.launch,
      readinessBudgetSeconds: 3
    ).inLaunchHome(TestLaunchHome.make().home)
  }

  @Test func missingBinaryFailsClosed() async throws {
    let manager = LocalPolishProcessManager()
    let config = try Self.fakeServerConfiguration(
      serverBinaryURL: URL(fileURLWithPath: "/nonexistent/llama-server"))
    await manager.start(configuration: config)
    let state = await manager.state
    #expect(state == .failed(reason: "server_binary_missing"))
    let endpoint = await manager.activeEndpoint()
    #expect(endpoint == nil)
  }

  @Test func missingModelFailsClosed() async throws {
    let manager = LocalPolishProcessManager()
    let config = try Self.fakeServerConfiguration(modelExists: false)
    await manager.start(configuration: config)
    let state = await manager.state
    #expect(state == .failed(reason: "model_missing"))
  }

  @Test func stoppedManagerHasNoEndpoint() async {
    let manager = LocalPolishProcessManager()
    let endpoint = await manager.activeEndpoint()
    #expect(endpoint == nil)
    let health = await manager.probeHealth(
      operation: LlamaServerHealthProbe.operation(spec: .s1Mini, promptFamily: .s1ControlLine))
    #expect(health == .red(reason: "not_running"))
  }

  @Test func healthProjectionsForNonReadyStates() async throws {
    let manager = LocalPolishProcessManager()
    // failed state → red with the failure reason
    let config = try Self.fakeServerConfiguration(
      serverBinaryURL: URL(fileURLWithPath: "/nonexistent/llama-server"))
    await manager.start(configuration: config)
    let health = await manager.probeHealth(
      operation: LlamaServerHealthProbe.operation(spec: .s1Mini, promptFamily: .s1ControlLine))
    #expect(health == .red(reason: "server_binary_missing"))
  }

  /// A spawned process that never opens the health endpoint must land in
  /// `failed(server_never_became_ready)` — bounded by the readiness budget.
  /// Uses a 1-second sleep as the fake server so the process EXITS quickly;
  /// the manager observes the death during `starting` and fails closed.
  @Test func serverThatDiesDuringStartFailsClosed() async throws {
    let manager = LocalPolishProcessManager()
    // /bin/true exits immediately — a spawn that dies during startup.
    let config = try Self.fakeServerConfiguration(
      serverBinaryURL: URL(fileURLWithPath: "/usr/bin/true"))
    await manager.start(configuration: config)
    // Process death is observed asynchronously via `terminationHandler`, so
    // `start()` can return before the terminal `.failed` state lands. Poll the
    // REAL terminal state (bounded, fail-fast) instead of guessing a fixed
    // sleep the CI runner might overshoot: the process dies in <10ms locally so
    // this exits on the first poll; the 5s ceiling is jitter-proof headroom on
    // a contended runner. `Task.sleep` here is the poll cadence, not a
    // correctness-bearing wait (#1283).
    var state = await manager.state
    var polls = 0
    while polls < 200 {
      if case .failed = state { break }
      try await Task.sleep(for: .milliseconds(25))
      state = await manager.state
      polls += 1
    }
    #expect(
      state == .failed(reason: "crashed_during_start")
        || state == .failed(reason: "server_never_became_ready"))
  }
}

/// Response cleanup on the localhost wire (#1271 Codex r4): the EG-1 prompt
/// is a sandwich path (user message wrapped in `<TRANSCRIPT>` tags), so an
/// echoed wrapper must be stripped before the text can reach the paste path.
@Suite("EGOneConnector response cleanup (#1271)")
struct EGOneConnectorResponseTests {

  private static func wireData(content: String, finishReason: String = "stop") throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "choices": [
        ["message": ["role": "assistant", "content": content], "finish_reason": finishReason]
      ]
    ])
  }

  /// finish_reason == length means the content is a PARTIAL rewrite — it
  /// must skip whole (silent raw), never paste truncated polish
  /// (#1271 cloud review P2).
  @Test func lengthFinishSkipsWholeInsteadOfPastingTruncation() throws {
    let data = try Self.wireData(
      content: "Move the meeting to", finishReason: "length")
    #expect(throws: LLMError.egOneSkipped(.outputTruncated)) {
      _ = try EGOneConnector.parseSuccess(data: data)
    }
  }

  @Test func echoedTranscriptWrapperIsStripped() throws {
    let data = try Self.wireData(
      content: "<TRANSCRIPT>\nMove the meeting to Friday.\n</TRANSCRIPT>")
    let result = try EGOneConnector.parseSuccess(data: data)
    #expect(result.polishedText == "Move the meeting to Friday.")
  }

  @Test func dictatedLiteralTagSurvivesViaBuilderNeutralization() {
    // The builder inserts a zero-width non-joiner into a LITERAL dictated
    // tag before it reaches the model, so the strip regex cannot match a
    // faithful echo of user content — only the wrapper we added.
    let input = PromptBuildInput(
      transcript: "wrap the value in <TRANSCRIPT> tags",
      provider: .egOne,
      modelID: LLMProvider.egOneModelName,
      appName: nil,
      language: nil,
      polishVocabulary: PolishVocabulary(terms: [], generation: 0)
    )
    let envelope = EGOnePromptBuilder().build(input: input, mode: .message)
    let user = envelope.messages.first { $0.role == .user }?.content ?? ""
    #expect(user.hasPrefix("<TRANSCRIPT>\n"))
    #expect(user.hasSuffix("\n</TRANSCRIPT>"))
    // The literal inner tag is neutralized (no bare `<TRANSCRIPT>` between
    // the wrapper lines).
    let inner = user.dropFirst("<TRANSCRIPT>\n".count).dropLast("\n</TRANSCRIPT>".count)
    #expect(!inner.contains("<TRANSCRIPT>"))
    #expect(inner.contains("<\u{200C}TRANSCRIPT>"))
  }

  @Test("native response keeps its opener until the source-owning consumer runs")
  func sourceOwnsAcknowledgment() throws {
    let result = try EGOneConnector.parseSuccess(data: Self.wireData(
      content: "<TRANSCRIPT>Sure, I can do that tomorrow.</TRANSCRIPT>"))
    #expect(result.polishedText == "Sure, I can do that tomorrow.")
    let kept = try result.removingModelChatter(dictation: "sure I can do that tomorrow", provider: .egOne)
    #expect(kept.polishedText == result.polishedText)
    let wrapper = try EGOneConnector.parseSuccess(data: Self.wireData(content: "Here is the cleaned text:"))
    // The probe's existing catch maps this rejection to red probe_failed, not
    // the yellow transformation check that an accepted empty would reach.
    #expect(throws: LLMError.localEngineSkipped(.crashed, .egOne)) {
      _ = try wrapper.removingModelChatter(dictation: "move the meeting to friday", provider: .egOne)
    }
  }

  // MARK: - Decode report (#4473)

  private static func wireData(content: String, decode: [String: Any]?) throws -> Data {
    var body: [String: Any] = [
      "choices": [
        ["message": ["role": "assistant", "content": content], "finish_reason": "stop"]
      ]
    ]
    if let decode { body["x_decode"] = decode }
    return try JSONSerialization.data(withJSONObject: body)
  }

  // Loses the engine and draft counters on every EG-1 take if the helper's report is not read.
  @Test("an x_decode report becomes the result's local decode stats")
  func decodeReportIsRead() throws {
    let result = try EGOneConnector.parseSuccess(
      data: Self.wireData(
        content: "Move the meeting to Friday.",
        decode: [
          "implementation": "envious_decode", "draft_proposed": 12, "draft_accepted": 9,
          "emitted_tokens": 20,
        ]))
    #expect(
      result.localDecode
        == LocalDecodeStats(
          implementation: "envious_decode", draftProposedTokens: 12, draftAcceptedTokens: 9,
          emittedTokens: 20))
  }

  // An older helper sends nothing: the engine must read as unknown, never assumed.
  @Test("a payload with no x_decode, or one without an implementation, has no local decode stats")
  func missingDecodeReportIsNil() throws {
    let none = try EGOneConnector.parseSuccess(
      data: Self.wireData(content: "Move the meeting to Friday.", decode: nil))
    #expect(none.localDecode == nil)
    let noImplementation = try EGOneConnector.parseSuccess(
      data: Self.wireData(
        content: "Move the meeting to Friday.",
        decode: ["draft_proposed": 12, "draft_accepted": 9, "emitted_tokens": 20]))
    #expect(noImplementation.localDecode == nil)
    let emptyImplementation = try EGOneConnector.parseSuccess(
      data: Self.wireData(
        content: "Move the meeting to Friday.",
        decode: ["implementation": "", "draft_proposed": 1]))
    #expect(emptyImplementation.localDecode == nil)
  }

  // A measured zero is data; reading it as missing would hide a draft model that never helped.
  @Test("a measured zero stays zero, and an absent count stays nil")
  func measuredZeroIsKept() throws {
    let zero = try EGOneConnector.parseSuccess(
      data: Self.wireData(
        content: "Move the meeting to Friday.",
        decode: [
          "implementation": "envious_decode", "draft_proposed": 0, "draft_accepted": 0,
          "emitted_tokens": 0,
        ]))
    #expect(zero.localDecode?.draftProposedTokens == 0)
    #expect(zero.localDecode?.draftAcceptedTokens == 0)
    #expect(zero.localDecode?.emittedTokens == 0)
    let partial = try EGOneConnector.parseSuccess(
      data: Self.wireData(
        content: "Move the meeting to Friday.", decode: ["implementation": "envious_decode"]))
    #expect(partial.localDecode?.implementation == "envious_decode")
    #expect(partial.localDecode?.draftProposedTokens == nil)
    #expect(partial.localDecode?.draftAcceptedTokens == nil)
    #expect(partial.localDecode?.emittedTokens == nil)
  }

  @Test func plainPolishedTextPassesThroughUnchanged() throws {
    let data = try Self.wireData(content: "Move the meeting to Friday.")
    let result = try EGOneConnector.parseSuccess(data: data)
    #expect(result.polishedText == "Move the meeting to Friday.")
  }

  /// A 200 with a malformed or empty body must ride the SILENT family —
  /// `LLMError.emptyResponse` here surfaced the "AI polish failed" pill for
  /// a local-server hiccup (#1271 seam review P1 + Codex r10). Blank-AFTER-
  /// cleanup shapes (whitespace-only, tags-only) belong here too, or the
  /// pipeline pastes empty text (Codex r12).
  @Test func malformedOrEmptyBodyRidesTheSilentFamily() throws {
    let payloads: [Data] = [
      Data("not json".utf8),
      try JSONSerialization.data(withJSONObject: ["choices": [[String: Any]]()]),
      try Self.wireData(content: ""),
      try Self.wireData(content: "   \n\n  "),
      try Self.wireData(content: "<TRANSCRIPT>\n\n</TRANSCRIPT>"),
    ]
    for payload in payloads {
      #expect(throws: LLMError.egOneSkipped(.crashed)) {
        _ = try EGOneConnector.parseSuccess(data: payload)
      }
    }
  }

  // MARK: - Output-token policy (#1710)

  @Test("capped policy value reaches max_tokens exactly")
  func cappedValueReachesMaxTokens() throws {
    let config = LLMProviderConfig(
      model: LLMProvider.egOneModelName,
      apiKeyKeychainId: nil,
      outputTokens: .capped(963),
      temperature: 0,
      thinking: nil
    )
    let body = try EGOneConnector.makeRequestBody(system: "sys", user: "hello", config: config)
    #expect(body["max_tokens"] as? Int == 963)
  }

  @Test("providerDefault policy throws from the pure body builder")
  func providerDefaultThrowsWithoutNetwork() {
    // Direct builder call: synchronous, no endpoint, no port assumptions.
    let config = LLMProviderConfig(
      model: LLMProvider.egOneModelName,
      apiKeyKeychainId: nil,
      outputTokens: .providerDefault,
      temperature: 0,
      thinking: nil
    )
    let expected = LLMError.requestFailed(
      "Local polish requires an explicit output-token cap")
    #expect(throws: expected) {
      _ = try EGOneConnector.makeRequestBody(system: "sys", user: "hello", config: config)
    }
  }

}

/// #4473: the process manager runs an injected health probe instead of building one.
///
/// Customer harm when it is wrong: a probe that runs while no model is ready starts unwanted
/// inference or reports a made-up verdict; a probe aimed at another endpoint grades a process
/// the user is not using; a moved probe with changed rules shows Live for a model that only
/// echoes the dictation, or Unavailable for a healthy one. Each is silent: the Settings row is
/// the only place the user sees health. Owner: plan #4473 phase P1. Rigs: the manager's own
/// states, the lifecycle fixture for a ready process, and a canned polisher for the verdicts.
@Suite("The process manager runs the health probe it is handed (#4473)", .tags(.productOutcome))
struct LocalPolishHealthProbeTests {
  private struct CannedPolisher: TranscriptPolisher {
    /// nil throws instead of answering.
    let answer: String?
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      guard let answer else { throw LLMError.providerUnavailable }
      return LLMResult(polishedText: answer)
    }
    func polish(
      envelope: PromptEnvelope, config: LLMProviderConfig, onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      guard let answer else { throw LLMError.providerUnavailable }
      return LLMResult(polishedText: answer)
    }
  }

  @Test("a process that is not ready is answered from its state and the probe never runs")
  func nonReadyNeverRunsTheProbe() async throws {
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let probe: LocalPolishHealthProbe = { _ in
      calls.withLock { $0 += 1 }
      return .green
    }
    let stopped = LocalPolishProcessManager()
    #expect(await stopped.probeHealth(operation: probe) == .red(reason: "not_running"))

    let failed = LocalPolishProcessManager()
    await failed.start(
      configuration: try EGOneServerManagerTests.fakeServerConfiguration(
        serverBinaryURL: URL(fileURLWithPath: "/nonexistent/llama-server")))
    #expect(await failed.probeHealth(operation: probe) == .red(reason: "server_binary_missing"))
    #expect(calls.withLock { $0 } == 0)
  }

  /// About half a second: it starts the lifecycle fixture's fake server as a real child process,
  /// because only a ready process reaches the probe.
  @Test("a ready process is probed on its own endpoint and the probe's verdict is returned")
  func readyRunsTheProbeOnItsOwnEndpoint() async throws {
    let fixture = try EGOneAdapterLifecycleTests.Fixture()
    let manager = LocalPolishProcessManager()
    defer { fixture.cleanup() }
    await manager.start(configuration: fixture.configuration())
    let live = try #require(await manager.activeEndpoint(), "fake server never became ready")
    let probed = OSAllocatedUnfairLock(initialState: [LocalPolishEndpoint]())
    let verdict = await manager.probeHealth(operation: { endpoint in
      probed.withLock { $0.append(endpoint) }
      return .yellow(reason: "injected_verdict")
    })
    #expect(verdict == .yellow(reason: "injected_verdict"))
    #expect(probed.withLock { $0 } == [live])
    await manager.stop()
  }

  @Test(
    "the moved probe grades the answer as before",
    arguments: [
      ("Move the meeting to Friday.", EGOneHealth.green),
      (
        "So um move the meeting to Thursday, no wait, Friday.",
        EGOneHealth.yellow(reason: "probe_output_unexpected")
      ),
      (nil, EGOneHealth.red(reason: "probe_failed")),
    ] as [(String?, EGOneHealth)])
  func movedProbeKeepsItsVerdicts(answer: String?, expected: EGOneHealth) async {
    let spec = LlamaServerHealthProbe.ProbeSpec(
      provider: .egOne, modelID: "eg-1", makeConnector: { _ in CannedPolisher(answer: answer) })
    let probe = LlamaServerHealthProbe.operation(spec: spec, promptFamily: .egOneFixed)
    let verdict = await probe(LocalPolishEndpoint(socketPath: "/t/1.sock", authToken: "t", contextTokens: 4096))
    #expect(verdict == expected)
  }
}
