import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

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
  static func fakeServerConfiguration(modelExists: Bool = true) throws
    -> EGOneServerManager.Configuration
  {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("eg1-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let model = dir.appendingPathComponent("model.gguf")
    if modelExists {
      try Data("fake".utf8).write(to: model)
    }
    return EGOneServerManager.Configuration(
      serverBinaryURL: URL(fileURLWithPath: "/bin/sleep"),
      modelURL: model,
      contextTokens: 4096,
      readinessBudgetSeconds: 3
    )
  }

  @Test func missingBinaryFailsClosed() async throws {
    let manager = EGOneServerManager()
    var config = try Self.fakeServerConfiguration()
    config.serverBinaryURL = URL(fileURLWithPath: "/nonexistent/llama-server")
    await manager.start(configuration: config)
    let state = await manager.state
    #expect(state == .failed(reason: "server_binary_missing"))
    let endpoint = await manager.activeEndpoint()
    #expect(endpoint == nil)
  }

  @Test func missingModelFailsClosed() async throws {
    let manager = EGOneServerManager()
    let config = try Self.fakeServerConfiguration(modelExists: false)
    await manager.start(configuration: config)
    let state = await manager.state
    #expect(state == .failed(reason: "model_missing"))
  }

  @Test func findFreePortReturnsUsablePort() {
    let port = EGOneServerManager.findFreePort()
    #expect(port != nil)
    #expect(port! > 0)
  }

  @Test func stoppedManagerHasNoEndpoint() async {
    let manager = EGOneServerManager()
    let endpoint = await manager.activeEndpoint()
    #expect(endpoint == nil)
    let health = await manager.probeHealth(promptFamily: .egOneFixed)
    #expect(health == .red(reason: "not_running"))
  }

  @Test func healthProjectionsForNonReadyStates() async throws {
    let manager = EGOneServerManager()
    // failed state → red with the failure reason
    var config = try Self.fakeServerConfiguration()
    config.serverBinaryURL = URL(fileURLWithPath: "/nonexistent/llama-server")
    await manager.start(configuration: config)
    let health = await manager.probeHealth(promptFamily: .egOneFixed)
    #expect(health == .red(reason: "server_binary_missing"))
  }

  /// A spawned process that never opens the health endpoint must land in
  /// `failed(server_never_became_ready)` — bounded by the readiness budget.
  /// Uses a 1-second sleep as the fake server so the process EXITS quickly;
  /// the manager observes the death during `starting` and fails closed.
  @Test func serverThatDiesDuringStartFailsClosed() async throws {
    let manager = EGOneServerManager()
    var config = try Self.fakeServerConfiguration()
    // /bin/true exits immediately — a spawn that dies during startup.
    config.serverBinaryURL = URL(fileURLWithPath: "/usr/bin/true")
    config.extraArguments = []
    await manager.start(configuration: config)
    // Give the termination handler a beat to land.
    try await Task.sleep(for: .milliseconds(500))
    let state = await manager.state
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
}
