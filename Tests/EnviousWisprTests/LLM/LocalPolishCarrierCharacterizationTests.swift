import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprEG1Engine
@testable import EnviousWisprLLM
@testable import EnviousWisprLlamaEngine
@testable import EnviousWisprLocalPolish

/// #4493 C0: what the six helper operations send and how each reads a fixed answer, frozen
/// against hand-written literals BEFORE the carrier changes from a loopback port to a private
/// socket. The carrier switch must keep every row green without editing an expectation, except
/// the OWNER rows, which describe the loopback carrier itself and are replaced with it.
///
/// Evidence kinds, named in each test:
/// - WIRE: the lifecycle fixture's fake helper (a real child process) recorded the request.
/// - REQUEST-OBJECT: the request the site handed to its injected executor (since C3 the helper
///   exchange's `LocalPolishHelperRequest` and the endpoint it names).
/// - OWNER: what the helper exchange makes of a request on the carrier: since C4 the bytes a
///   helper receives on the private socket (bearer, content type, body) and a missing socket.
/// - SOURCE GUARD: a value no test can observe at run time (a site with no executor seam), read
///   from the owning function's text. It is not wire evidence.
///
/// Frozen: method, path, the bearer and content-type headers, the body and each site's time
/// limit. Not frozen: scheme, host and port (they ARE the carrier being replaced) and the
/// headers `URLSession` added by itself (User-Agent, Accept, Accept-Language, Accept-Encoding,
/// Connection, Host), which the socket client does not send. A body the site passes through is
/// compared byte for byte; a body the site builds from a dictionary is compared as parsed JSON,
/// so key order is not frozen.
///
/// Customer harm when a row breaks: a polish, word check or summary that asks the helper a
/// different question, or reads its answer differently, after a change that was meant to move
/// only the connection.
@Suite("Local polish carrier characterization (#4493)", .serialized, .tags(.driftGuard))
struct LocalPolishCarrierCharacterizationTests {
  private static let token = "tok-1"
  private static let endpoint = LocalPolishEndpoint(
    socketPath: "/t/4242.sock", authToken: token, contextTokens: 8192, hasLearnedWordAdapter: true)

  private final class Captured: Sendable {
    private let requests = OSAllocatedUnfairLock(
      initialState: [(LocalPolishHelperRequest, LocalPolishEndpoint)]())
    func append(_ request: LocalPolishHelperRequest, _ endpoint: LocalPolishEndpoint) {
      requests.withLock { $0.append((request, endpoint)) }
    }
    var all: [(LocalPolishHelperRequest, LocalPolishEndpoint)] { requests.withLock { $0 } }
  }

  /// Parsed JSON written back with sorted keys: equal for equal JSON whatever the key order.
  private static func canonical(_ json: Data) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]),
      options: [.sortedKeys, .fragmentsAllowed])
  }

  private static func question() -> LearnedWordCheckQuestion {
    let sentence = "I said toast"
    return LearnedWordCheckQuestion(
      id: 7, sentence: sentence, range: sentence.range(of: "toast")!,
      contextRange: sentence.startIndex..<sentence.endIndex, word: "Tuist")
  }

  // MARK: - 1. chat

  @Test("chat: REQUEST-OBJECT POST /v1/chat/completions, body and answer bytes unchanged, 20 s")
  func chat() async throws {
    let captured = Captured()
    // Deliberately not canonical JSON: the transport must not decode or re-serialize it.
    let body = Data(#"{"z": 1, "a" : [2,3], "model":"eg-1"}"#.utf8)
    let answer = Data(
      #"{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"Friday at three."}}]}"#
        .utf8)
    let returned = try await LocalPolishTransport.send(
      endpoint: Self.endpoint, body: body,
      perform: { request, endpoint in
        captured.append(request, endpoint)
        return LocalPolishHelperResponse(status: 200, body: answer)
      }, retryPause: {})
    #expect(returned == answer)
    let (request, endpoint) = try #require(captured.all.first)
    #expect(captured.all.count == 1)
    #expect(endpoint == Self.endpoint)
    #expect(request.method == .post)
    #expect(request.path == "/v1/chat/completions")
    #expect(request.body == body)
    #expect(request.timeout == .seconds(20))

    // Any status other than 200 is the neutral transport failure, with no second attempt.
    let refused = Captured()
    await #expect(throws: LocalPolishTransportError.unavailable) {
      _ = try await LocalPolishTransport.send(
        endpoint: Self.endpoint, body: body,
        perform: { request, endpoint in
          refused.append(request, endpoint)
          return LocalPolishHelperResponse(status: 503, body: Data())
        }, retryPause: {})
    }
    #expect(refused.all.count == 1)
  }

  // MARK: - 2. readiness

  /// About two seconds: it starts the lifecycle fixture's fake helper as a real child and lets
  /// one readiness budget of one second run out.
  @Test("readiness: WIRE GET /health with the launch bearer; 200 is ready, 503 is not")
  func readiness() async throws {
    let fixture = try EGOneAdapterLifecycleTests.Fixture()
    let manager = LocalPolishProcessManager()
    defer { fixture.cleanup() }
    await manager.start(configuration: fixture.configuration())
    let live = try #require(await manager.activeEndpoint(), "fake helper never became ready")
    let gets = try Self.gets(fixture)
    try #require(!gets.isEmpty)
    for get in gets {
      #expect(get.path == "/health")
      #expect(get.authorization == "Bearer \(live.authToken)")
    }

    try Data("503".utf8).write(to: fixture.root.appendingPathComponent("get_status"))
    #expect(
      await LocalPolishProcessManager.awaitServerUp(endpoint: live, budgetSeconds: 1) == false)
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("get_status"))
    #expect(await LocalPolishProcessManager.awaitServerUp(endpoint: live, budgetSeconds: 1))
    await manager.stop()
  }

  @Test("readiness: SOURCE GUARD 2 s per request and a 500 ms pause between requests")
  func readinessLimits() throws {
    let text = try Self.functionText(
      in: "Sources/EnviousWisprLocalPolish/LocalPolishProcessManager.swift",
      signature: "static func awaitServerUp(")
    #expect(Self.count("LocalPolishHelperRequest(", in: text) == 1)
    #expect(
      text.contains(
        #"LocalPolishHelperRequest(method: .get, path: "/health", timeout: .seconds(2))"#))
    #expect(Self.count("Task.sleep(", in: text) == 1)
    #expect(text.contains("try? await Task.sleep(for: .milliseconds(500))"))
  }

  // MARK: - 3. EnviousDecode word check

  @Test("EnviousDecode word check: REQUEST-OBJECT POST /v1/wordcheck, 60 s default, answer read")
  func enviousDecodeWordCheck() async throws {
    let captured = Captured()
    let hold = EnviousDecodeWordChecker.Hold(endpoint: Self.endpoint) {}
    let answer = Data(#"{"scores":[{"id":7,"pA":0.25,"pB":0.75}]}"#.utf8)
    let checker = EnviousDecodeWordChecker(threshold: 0.5, hold: { hold }) { request, endpoint in
      captured.append(request, endpoint)
      return LocalPolishHelperResponse(status: 200, body: answer)
    }
    let decisions = try await checker.decide([Self.question()])
    #expect(decisions == [LearnedWordCheckDecision(questionID: 7, approved: true, score: 0.75)])
    let (request, endpoint) = try #require(captured.all.first)
    #expect(captured.all.count == 1)
    #expect(endpoint == Self.endpoint)
    #expect(request.method == .post)
    #expect(request.path == "/v1/wordcheck")
    // C0 observed `URLRequest`'s own 60 s here (no limit set at the site); C3 states it.
    #expect(request.timeout == .seconds(60))
    let expected = Data(
      #"{"model":"eg-1","questions":[{"id":7,"word":"Tuist","context":"I said toast","rewritten":"I said Tuist"}]}"#
        .utf8)
    #expect(try Self.canonical(try #require(request.body)) == Self.canonical(expected))

    let refused = EnviousDecodeWordChecker(threshold: 0.5, hold: { hold }) { _, _ in
      LocalPolishHelperResponse(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
    }
    await #expect(throws: EnviousDecodeWordChecker.CheckerError.invalidResponse) {
      _ = try await refused.decide([Self.question()])
    }
  }

  // MARK: - 4. summary

  @Test(
    "summary: REQUEST-OBJECT POST /v1/chat/completions, limit + 10 s, answer and failures read",
    arguments: [(50.0, 60.0), (0.5, 10.5)])
  func summary(limit: Double, expectedTimeout: Double) async throws {
    let captured = Captured()
    let answer = Data(
      #"{"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"  Title\nShip Friday.  "}}]}"#
        .utf8)
    let text = try await EGOneSummaryCall.complete(
      endpoint: Self.endpoint, instructions: "Summarize.", prompt: "Meeting text.",
      timeoutSeconds: limit
    ) { request, endpoint in
      captured.append(request, endpoint)
      return LocalPolishHelperResponse(status: 200, body: answer)
    }
    #expect(text == "Title\nShip Friday.")
    let (request, endpoint) = try #require(captured.all.first)
    #expect(endpoint == Self.endpoint)
    #expect(request.method == .post)
    #expect(request.path == "/v1/chat/completions")
    #expect(request.timeout == .seconds(expectedTimeout))
    let expected = Data(
      #"{"model":"eg-1","messages":[{"role":"system","content":"Summarize."},{"role":"user","content":"Meeting text."}],"max_tokens":1500,"temperature":0,"stream":false}"#
        .utf8)
    #expect(try Self.canonical(try #require(request.body)) == Self.canonical(expected))

    await #expect(throws: LLMError.requestFailed("EG-1 summary HTTP 500")) {
      _ = try await EGOneSummaryCall.complete(
        endpoint: Self.endpoint, instructions: "Summarize.", prompt: "Meeting text.",
        timeoutSeconds: limit
      ) { _, _ in LocalPolishHelperResponse(status: 500, body: Data(#"{"error":"boom"}"#.utf8)) }
    }
    await #expect(throws: MeetingSummary.Failure.timedOut) {
      _ = try await EGOneSummaryCall.complete(
        endpoint: Self.endpoint, instructions: "Summarize.", prompt: "Meeting text.",
        timeoutSeconds: limit
      ) { _, _ in throw LocalPolishHelperClientError.timedOut }
    }
  }

  // MARK: - 5. llama word check (S1-mini)

  /// About one second: it starts the lifecycle fixture's fake helper as a real child.
  @Test("llama word check: WIRE POST /completion with the bearer, answer bytes read, 500 refused")
  func llamaWordCheck() async throws {
    let fixture = try EGOneAdapterLifecycleTests.Fixture()
    let manager = LocalPolishProcessManager()
    defer { fixture.cleanup() }
    await manager.start(configuration: fixture.configuration())
    let live = try #require(await manager.activeEndpoint(), "fake helper never became ready")
    let endpoint = LocalPolishEndpoint(
      socketPath: live.socketPath, authToken: live.authToken, contextTokens: live.contextTokens,
      hasLearnedWordAdapter: true)
    let checker = LlamaLearnedWordChecker(threshold: 0.5, style: .s1Mini(language: nil)) {
      EGOneCheckerHold(endpoint: endpoint) {}
    }
    // ln(0.75) and ln(0.25): the answer the checker reads as pB 0.75 and pA 0.25.
    try Data(
      #"{"index":0,"content":"B","completion_probabilities":[{"id":33,"token":"B","logprob":-0.2876820724517809,"top_logprobs":[{"id":33,"token":"B","logprob":-0.2876820724517809},{"id":32,"token":"A","logprob":-1.3862943611198906}]}]}"#
        .utf8
    ).write(to: fixture.root.appendingPathComponent("completion_reply"))
    let decisions = try await checker.decide([Self.question()])
    let decision = try #require(decisions.first)
    #expect(decisions.count == 1)
    #expect(decision.questionID == 7)
    #expect(decision.approved)
    #expect(abs(try #require(decision.score) - 0.75) < 1e-9)

    let posts = try Self.posts(fixture)
    let post = try #require(posts.last)
    #expect(posts.count == 1)
    #expect(post.path == "/completion")
    #expect(post.authorization == "Bearer \(live.authToken)")
    #expect(post.content_type == "application/json")
    let prompt =
      "<|im_start|>system\n[Task: check] A word from the user's dictionary may have been misheard in a dictated sentence. A is the sentence as transcribed. B writes the dictionary word at one spot. Answer B only if the speaker meant the dictionary word there; otherwise answer A. Answer with one letter.<|im_end|>\n<|im_start|>user\nDictionary word: Tuist\nA: I said toast\nB: I said Tuist<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    let expected: [String: Any] = [
      "prompt": prompt, "id_slot": 1, "n_predict": 1, "n_probs": 20, "temperature": 0,
      "cache_prompt": true, "lora": [["id": 0, "scale": 1]],
    ]
    #expect(
      try Self.canonical(Data(post.body.utf8))
        == JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys]))

    try Data("500".utf8).write(to: fixture.root.appendingPathComponent("post_status"))
    await #expect(throws: LlamaLearnedWordChecker.CheckerError.invalidResponse) {
      _ = try await checker.decide([Self.question()])
    }
    await manager.stop()
  }

  /// C0 observed no limit at this site (`URLRequest`'s own 60 s); C3 states that value.
  @Test("llama word check: SOURCE GUARD 60 s, the limit the request always had")
  func llamaWordCheckLimit() throws {
    let text = try Self.functionText(
      in: "Sources/EnviousWisprLlamaEngine/LlamaLearnedWordChecker.swift",
      signature: "private func decide(")
    #expect(Self.count("LocalPolishHelperRequest(", in: text) == 1)
    #expect(Self.count("timeout: .seconds(60)", in: text) == 1)
    #expect(text.contains(#"method: .post, path: "/completion","#))
  }

  // MARK: - 6. DEBUG slots

  #if DEBUG
    @Test("DEBUG slots: REQUEST-OBJECT GET /slots with the bearer, 2 s, answer and refusal read")
    func slots() async throws {
      let captured = Captured()
      let answer = Data(
        #"[{"id":0,"is_processing":true,"id_task":12,"next_token":[{"n_decoded":5,"n_remain":59}]},{"id":1,"is_processing":false}]"#
          .utf8)
      let read = LlamaServerSlotReader.operation { request, endpoint in
        captured.append(request, endpoint)
        return LocalPolishHelperResponse(status: 200, body: answer)
      }
      let observed = try await read(Self.endpoint, 3)
      #expect(
        observed
          == .observed(
            EGOneSlotSnapshot(
              launchGeneration: 3,
              slots: [
                .init(
                  id: 0, isProcessing: true, taskID: 12, decodedTokens: 5, remainingTokens: 59),
                .init(
                  id: 1, isProcessing: false, taskID: nil, decodedTokens: nil,
                  remainingTokens: nil),
              ])))
      let (request, endpoint) = try #require(captured.all.first)
      #expect(endpoint == Self.endpoint)
      #expect(request.method == .get)
      #expect(request.path == "/slots")
      #expect(request.body == nil)
      #expect(request.timeout == .seconds(2))

      let refused = LlamaServerSlotReader.operation { _, _ in
        LocalPolishHelperResponse(status: 401, body: Data())
      }
      #expect(try await refused(Self.endpoint, 3) == .httpStatus(401))
    }
  #endif

  // MARK: - 7. the helper exchange on the private socket (C4)

  /// What every operation's request becomes on the private socket: C0's bearer, content type
  /// and body, as the bytes a helper receives.
  @Test(
    "OWNER WIRE: each operation's request bytes on the socket, and the answer returned",
    arguments: [
      (LocalPolishHelperRequest.Method.post, "/v1/chat/completions", true),
      (.get, "/health", false),
      (.post, "/v1/wordcheck", true),
      (.post, "/completion", true),
      (.get, "/slots", false),
    ])
  func ownerWire(method: LocalPolishHelperRequest.Method, path: String, hasBody: Bool)
    async throws
  {
    let answer = #"{"ok":true}"#
    let fake = try LocalPolishAFUnixFakeHelper(
      script: .reply(
        Data(
          ("HTTP/1.1 418 I'm a teapot\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(answer.utf8.count)\r\nConnection: close\r\n\r\n" + answer)
            .utf8)))
    defer { fake.stop() }
    let body = hasBody ? Data(#"{"b": 1}"#.utf8) : nil
    let endpoint = LocalPolishEndpoint(
      socketPath: fake.socketPath, authToken: Self.token, contextTokens: 8192)
    let response = try await LocalPolishHelperExchange.perform(
      LocalPolishHelperRequest(method: method, path: path, body: body, timeout: .seconds(10)),
      endpoint)
    #expect(response == LocalPolishHelperResponse(status: 418, body: Data(answer.utf8)))
    var expected =
      "\(method.rawValue) \(path) HTTP/1.1\r\nHost: localhost\r\n"
      + "Authorization: Bearer \(Self.token)\r\nConnection: close\r\n"
    if hasBody { expected += "Content-Type: application/json\r\nContent-Length: 8\r\n" }
    expected += "\r\n" + (hasBody ? #"{"b": 1}"# : "")
    #expect(fake.requests == [Data(expected.utf8)])
  }

  @Test("OWNER: a launch whose socket is gone is not connectable")
  func ownerMissingSocket() async {
    let endpoint = LocalPolishEndpoint(
      socketPath: TestTemporaryDirectory.url.appendingPathComponent("gone.sock").path,
      authToken: Self.token, contextTokens: 8192)
    await #expect(throws: LocalPolishHelperClientError.notConnectable) {
      _ = try await LocalPolishHelperExchange.perform(
        LocalPolishHelperRequest(method: .get, path: "/health", timeout: .seconds(2)), endpoint)
    }
  }

  // MARK: - Fixture records and source text

  private struct Get: Decodable {
    let path: String
    let authorization: String?
  }

  private struct Post: Decodable {
    let path: String
    let body: String
    let authorization: String?
    let content_type: String?
  }

  private static func lines(_ url: URL) throws -> [Data] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      Data($0.utf8)
    }
  }

  private static func gets(_ fixture: EGOneAdapterLifecycleTests.Fixture) throws -> [Get] {
    try lines(fixture.root.appendingPathComponent("gets.jsonl")).map {
      try JSONDecoder().decode(Get.self, from: $0)
    }
  }

  private static func posts(_ fixture: EGOneAdapterLifecycleTests.Fixture) throws -> [Post] {
    try lines(fixture.root.appendingPathComponent("posts.jsonl")).map {
      try JSONDecoder().decode(Post.self, from: $0)
    }
  }

  private static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // LLM
    .deletingLastPathComponent()  // EnviousWisprTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

  /// The text of one function: from its signature line to the closing brace at the
  /// signature's own indentation. Fails when the signature is absent or appears twice.
  private static func functionText(in path: String, signature: String) throws -> String {
    let source = try String(
      contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    let lines = source.components(separatedBy: "\n")
    let starts = lines.indices.filter { lines[$0].contains(signature) }
    try #require(starts.count == 1, "\(signature) found \(starts.count) times in \(path)")
    let start = starts[0]
    let indent = String(lines[start].prefix { $0 == " " })
    let end = try #require(
      lines[(start + 1)...].firstIndex { $0 == indent + "}" }, "no end of \(signature)")
    return lines[start...end].joined(separator: "\n") + "\n"
  }

  private static func count(_ needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
  }
}
