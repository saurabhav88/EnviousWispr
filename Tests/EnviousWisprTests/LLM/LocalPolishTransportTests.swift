import EnviousWisprCore
import EnviousWisprEG1Engine
import EnviousWisprLlamaEngine
import Foundation
import Testing
import os

@testable import EnviousWisprLLM
@testable import EnviousWisprLocalPolish

/// #4473: the local polish transport carries prepared bytes and reports one neutral failure.
///
/// Customer harm when it is wrong. A changed request (body, address, bearer, content type)
/// makes the local model answer the wrong input or refuse the call, so polish silently stops.
/// A transport failure that is not the one neutral case reaches the screen as "AI polish
/// failed" for what is only a local hiccup. A lost retry drops the polish of the take that
/// lands while a crashed server restarts; an extra retry delays every failing take. A
/// cancellation turned into a failure keeps abandoned work alive. Encounter: every dictation
/// polished by a bundled model. Owner: plan #4473 phase P1. Rig: the transport's own injected
/// request and pause, scripted per attempt; no network and no real wait.
@Suite("Local polish transport: bytes in, bytes out (#4473)", .tags(.productOutcome))
struct LocalPolishTransportTests {
  static let endpoint = LocalPolishEndpoint(socketPath: "/t/4242.sock", authToken: "tok-1", contextTokens: 4096)
  /// Not JSON, on purpose: the transport must send and return bytes it cannot read.
  static let body = Data([0x00, 0xFF, 0x7B, 0x22, 0x0A])
  static let answer = Data([0xFE, 0x00, 0x5D])

  /// What one attempt does.
  enum Step: Sendable {
    case http(Int)
    case fail(LocalPolishHelperClientError)
    case cancelled
    case unrelated
  }

  struct Unrelated: Error, Equatable {}

  /// Scripted outcomes, one per attempt, and a record of what the transport did.
  final class Wire: Sendable {
    private struct State: Sendable {
      var steps: [Step]
      var requests: [LocalPolishHelperRequest] = []
      var endpoints: [LocalPolishEndpoint] = []
      var pauses = 0
    }
    private let state: OSAllocatedUnfairLock<State>
    private let pauseIsCancelled: Bool

    init(_ steps: [Step], pauseIsCancelled: Bool = false) {
      state = OSAllocatedUnfairLock(initialState: State(steps: steps))
      self.pauseIsCancelled = pauseIsCancelled
    }

    var requests: [LocalPolishHelperRequest] { state.withLock { $0.requests } }
    var endpoints: [LocalPolishEndpoint] { state.withLock { $0.endpoints } }
    var pauses: Int { state.withLock { $0.pauses } }

    func perform(_ request: LocalPolishHelperRequest, _ endpoint: LocalPolishEndpoint) throws
      -> LocalPolishHelperResponse
    {
      let step = state.withLock { state -> Step? in
        state.requests.append(request)
        state.endpoints.append(endpoint)
        return state.steps.isEmpty ? nil : state.steps.removeFirst()
      }
      switch try #require(step, "the transport made more attempts than the script allows") {
      case .http(let status):
        return LocalPolishHelperResponse(status: status, body: LocalPolishTransportTests.answer)
      case .fail(let error):
        throw error
      case .cancelled:
        throw CancellationError()
      case .unrelated:
        throw Unrelated()
      }
    }

    func pause() throws {
      state.withLock { $0.pauses += 1 }
      if pauseIsCancelled { throw CancellationError() }
    }
  }

  private static func send(_ wire: Wire) async throws -> Data {
    try await LocalPolishTransport.send(
      endpoint: endpoint, body: body,
      perform: { request, endpoint in try wire.perform(request, endpoint) },
      retryPause: { try wire.pause() })
  }

  @Test("the request goes out as prepared and the answer bytes come back untouched")
  func requestAndAnswerAreUntouched() async throws {
    let wire = Wire([.http(200)])
    let data = try await Self.send(wire)
    #expect(data == Self.answer)
    #expect(wire.pauses == 0)
    let requests = wire.requests
    try #require(requests.count == 1)
    #expect(
      requests[0]
        == LocalPolishHelperRequest(
          method: .post, path: "/v1/chat/completions", body: Self.body, timeout: .seconds(20)))
    #expect(wire.endpoints == [Self.endpoint])
  }

  @Test(
    "a failure that is not a dropped connection is unavailable at once, with no second try",
    arguments: [Step.http(500), .http(404), .fail(.timedOut), .fail(.failed)])
  func failuresAreUnavailableWithoutRetry(_ step: Step) async {
    let wire = Wire([step])
    await #expect(throws: LocalPolishTransportError.unavailable) {
      try await Self.send(wire)
    }
    #expect(wire.requests.count == 1)
    #expect(wire.pauses == 0)
  }

  static let droppedConnections: [LocalPolishHelperClientError] = [.notConnectable, .connectionLost]

  @Test(
    "a dropped connection is tried once more and the second answer is used",
    arguments: droppedConnections)
  func droppedConnectionRecovers(_ error: LocalPolishHelperClientError) async throws {
    let wire = Wire([.fail(error), .http(200)])
    #expect(try await Self.send(wire) == Self.answer)
    #expect(wire.requests.count == 2)
    #expect(wire.pauses == 1)
    #expect(wire.requests.map(\.body) == [Self.body, Self.body])
  }

  @Test("a connection dropped twice stops after two attempts", arguments: droppedConnections)
  func droppedConnectionGivesUpAfterTwo(_ error: LocalPolishHelperClientError) async {
    let wire = Wire([.fail(error), .fail(error), .http(200)])
    await #expect(throws: LocalPolishTransportError.unavailable) {
      try await Self.send(wire)
    }
    #expect(wire.requests.count == 2)
    #expect(wire.pauses == 1)
  }

  @Test("a cancelled request stays a cancellation and is not tried again")
  func cancelledRequestStaysCancelled() async {
    let wire = Wire([.cancelled, .http(200)])
    await #expect(throws: CancellationError.self) {
      try await Self.send(wire)
    }
    #expect(wire.requests.count == 1)
    #expect(wire.pauses == 0)
  }

  @Test("a cancellation during the wait before the second try stops there")
  func cancelledPauseStaysCancelled() async {
    let wire = Wire([.fail(.notConnectable), .http(200)], pauseIsCancelled: true)
    await #expect(throws: CancellationError.self) {
      try await Self.send(wire)
    }
    #expect(wire.requests.count == 1)
    #expect(wire.pauses == 1)
  }

  @Test("an error the transport does not know passes through unchanged")
  func unrelatedErrorPassesThrough() async {
    let wire = Wire([.unrelated, .http(200)])
    await #expect(throws: Unrelated()) {
      try await Self.send(wire)
    }
    #expect(wire.requests.count == 1)
  }
}

/// #4473: both bundled connectors over a real local HTTP server, after the transport stopped
/// building their requests and reading their answers.
///
/// Customer harm when it is wrong: a connector that sends a changed request gets a polish of
/// the wrong input; a dead server that is not mapped to the silent skip shows "AI polish
/// failed"; an empty answer handled by the other model's rule either reports a crash for
/// S1-mini doing its job on filler-only speech or pastes nothing for EG-1. Owner: plan #4473
/// phase P1. Rig: the lifecycle fixture's fake server, started once for the whole test.
@Suite("Bundled connectors over the local wire (#4473)", .serialized, .tags(.productOutcome))
struct LocalPolishConnectorWireTests {
  private struct Post: Decodable {
    let path: String
    let body: String
  }

  private static func posts(_ fixture: EGOneAdapterLifecycleTests.Fixture) throws -> [Post] {
    let log = fixture.root.appendingPathComponent("posts.jsonl")
    guard FileManager.default.fileExists(atPath: log.path) else { return [] }
    return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode(Post.self, from: Data($0.utf8))
    }
  }

  /// About half a second: it starts the fake server once as a real child process.
  @Test(
    "each connector sends its request, skips silently on a failing server, and keeps its own empty rule"
  )
  func connectorsOverTheWire() async throws {
    let fixture = try EGOneAdapterLifecycleTests.Fixture()
    let manager = LocalPolishProcessManager()
    defer { fixture.cleanup() }
    await manager.start(configuration: fixture.configuration())
    let endpoint = try #require(await manager.activeEndpoint(), "fake server never became ready")
    let egOne = EGOneConnector(endpoint: endpoint)
    let s1Mini = S1MiniConnector(endpoint: endpoint)
    let instructions = PolishInstructions(systemPrompt: "System line")
    let config = LLMProviderConfig(
      model: "eg-1", apiKeyKeychainId: nil, outputTokens: .capped(64), temperature: 0,
      thinking: nil)

    // A normal answer, and the request the server really received.
    let polished = try await egOne.polish(
      text: "so um hello", instructions: instructions, config: config, onToken: nil)
    #expect(polished.polishedText == "Move the meeting to Friday.")
    let sent = try Self.posts(fixture)
    try #require(sent.count == 1)
    #expect(sent[0].path == "/v1/chat/completions")
    let expected: [String: Any] = [
      "model": "eg-1", "max_tokens": 64, "temperature": 0,
      "messages": [
        ["role": "system", "content": "System line"],
        ["role": "user", "content": "so um hello"],
      ],
    ]
    let canonical = { (object: Any) throws -> Data in
      try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    #expect(
      try canonical(JSONSerialization.jsonObject(with: Data(sent[0].body.utf8)))
        == canonical(expected))

    // An empty answer: each connector keeps its own rule.
    try Data().write(to: fixture.root.appendingPathComponent("post_content"))
    await #expect(throws: LLMError.egOneSkipped(.crashed)) {
      _ = try await egOne.polish(
        text: "send the report", instructions: instructions, config: config, onToken: nil)
    }
    let filler = try await s1Mini.polish(
      text: S1MiniConnectorTests.userMessage("um uh"), instructions: instructions,
      config: config, onToken: nil)
    #expect(filler.polishedText == "")
    await #expect(throws: LLMError.egOneSkipped(.crashed)) {
      _ = try await s1Mini.polish(
        text: S1MiniConnectorTests.userMessage("send the report by friday"),
        instructions: instructions, config: config, onToken: nil)
    }

    // A failing server: the silent skip from both, and one request each (no second try).
    try Data("500".utf8).write(to: fixture.root.appendingPathComponent("post_status"))
    let before = try Self.posts(fixture).count
    await #expect(throws: LLMError.egOneSkipped(.crashed)) {
      _ = try await egOne.polish(
        text: "hello", instructions: instructions, config: config, onToken: nil)
    }
    await #expect(throws: LLMError.egOneSkipped(.crashed)) {
      _ = try await s1Mini.polish(
        text: S1MiniConnectorTests.userMessage("hello"), instructions: instructions,
        config: config, onToken: nil)
    }
    #expect(try Self.posts(fixture).count == before + 2)
    await manager.stop()
  }
}
