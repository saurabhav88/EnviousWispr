import ArgmaxOSS
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLocalPolish
import Foundation
import Testing

@testable import EnviousDecodeKit
@testable import EnviousWisprLlamaEngine

/// #4473 P2: the helper process itself. These tests start the helper binary the build puts in
/// the Dev app, with real model folders, and talk to it the way the app does: over loopback
/// HTTP, with the app's own request builders, transport and answer parsers.
///
/// When this fails, the user loses local polish or gets someone else's text: the helper does
/// not start for a model that the tests in the same process load without trouble, it answers
/// without the token, two requests run at once and mix their state, a cancelled dictation
/// keeps the GPU busy, or the helper stays alive after the app told it to stop. None of these
/// can be seen from inside the app's own process, so each check here starts the real helper.
@Suite(
  "EnviousDecode helper serves the app's requests over loopback and stops when told (#4473)",
  .serialized, .tags(.productOutcome))
struct EnviousDecodeHelperIntegrationTests {
  typealias Fixtures = DFlashRuntimeTests

  // MARK: - The helper binary and its process

  /// The helper inside the Dev app that the build puts beside the test bundle. Exactly one
  /// app there may hold a helper; with none or several the tests do not choose.
  static var helperCandidates: [URL] {
    guard let testBundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") })
    else { return [] }
    let products = testBundle.bundleURL.deletingLastPathComponent()
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: products, includingPropertiesForKeys: nil)) ?? []
    return entries.filter { $0.pathExtension == "app" }
      .map { $0.appendingPathComponent("Contents/MacOS/envious-decode") }
      .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  static var canRun: Bool {
    EnviousDecodeSessionTests.realInputsPresent && helperCandidates.count == 1
  }

  /// A deadline for every wait on the helper. A wait that passes it fails the test with its
  /// own message; no wait here is open-ended.
  struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
  }

  /// One started helper. It is this test's own child process and is stopped by its own handle.
  /// The helper is another process: the only signals it gives are its log lines, its answers
  /// and its exit, so the waits below look for those, each under a deadline.
  final class Helper: @unchecked Sendable {
    let process = Process()
    let port: UInt16
    let token = "test-" + UUID().uuidString
    let contextTokens: Int
    private let lock = NSLock()
    private var log = ""

    init(size: String, contextTokens: Int = 8192) throws {
      self.contextTokens = contextTokens
      port = try Self.freePort()
      process.executableURL = try #require(
        EnviousDecodeHelperIntegrationTests.helperCandidates.first)
      process.arguments = [
        "--model", try #require(Fixtures.targetFolders[size] ?? nil),
        "--draft-model", try #require(Fixtures.helperFolders[size] ?? nil),
        "--model-name", LLMProvider.egOneModelName, "--port", String(port), "--token", token,
        "--ctx-size", String(contextTokens), "--cache-limit-bytes", String(256 * 1024 * 1024),
      ]
      let pipe = Pipe()
      process.standardError = pipe
      process.standardOutput = FileHandle.nullDevice
      pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        guard !data.isEmpty, let self else { return }
        self.lock.withLock { self.log += String(decoding: data, as: UTF8.self) }
      }
      try process.run()
    }

    var lines: [String] { lock.withLock { log.split(separator: "\n").map(String.init) } }

    var endpoint: LocalPolishEndpoint {
      LocalPolishEndpoint(port: port, authToken: token, contextTokens: contextTokens)
    }

    /// A port nothing listens on now: the system picks it, and it is given back before the
    /// helper binds it.
    static func freePort() throws -> UInt16 {
      let descriptor = socket(AF_INET, SOCK_STREAM, 0)
      try #require(descriptor >= 0)
      defer { close(descriptor) }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
          bind(descriptor, pointer, length) == 0 && getsockname(descriptor, pointer, &length) == 0
        }
      }
      try #require(bound)
      return UInt16(bigEndian: address.sin_port)
    }

    /// Looks for a signal of the helper process (a log line, an exit) until it is there, and
    /// throws `TimedOut` when `seconds` pass first.
    func signal(
      _ what: String, within seconds: Double, _ present: @Sendable () -> Bool
    ) async throws {
      let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
      while !present() {
        guard ContinuousClock.now < deadline else { throw TimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(50))  // deadline-fallback: the helper is another process; its log and exit are read until the deadline
      }
    }

    /// The helper says `ready` only after both models are loaded and the port is bound.
    func untilReady() async throws {
      // deadline-fallback: the signal is the helper's own "ready" line (or its exit); 180 s bounds a model load
      try await signal("the helper to be ready or to exit", within: 180) {
        self.lines.contains { $0.contains("ready port=") } || !self.process.isRunning
      }
      try #require(process.isRunning, "the helper exited while starting: \(lines)")
    }

    func request(
      _ path: String, method: String = "GET", bearer: String?, body: Data? = nil
    ) async throws -> (status: Int, data: Data) {
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
      request.httpMethod = method
      request.timeoutInterval = 120
      if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
      request.httpBody = body
      let (data, response) = try await URLSession.shared.data(for: request)
      return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// Stops the helper if it still runs: SIGTERM, then SIGKILL of this child if it has not
    /// exited when the exit is awaited on another thread for 5 seconds.
    func stop() {
      guard process.isRunning else { return }
      process.terminate()
      let exited = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        self.process.waitUntilExit()
        exited.signal()
      }
      // deadline-fallback: the signal is the child's exit; 5 s bounds it before the child is killed
      if exited.wait(timeout: .now() + 5) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
      }
    }
  }

  // MARK: - Requests and the answers they must get

  struct Messages {
    let label: String
    let system: String
    let user: String
    let cap: Int
    let prefixTokens: Int
  }

  /// What the tests compare the helper with: the same folders loaded in this process.
  struct Reference {
    let session: EnviousDecodeSession
    let tokenizer: EnviousDecodeTokenizer
    let configuration: EnviousDecodeRequestConfiguration
    let cases: [Messages]

    static func load(size: String, contextTokens: Int = 8192) async throws -> Reference {
      let folder = URL(
        fileURLWithPath: try #require(Fixtures.targetFolders[size] ?? nil), isDirectory: true)
      let wrapper = try await AutoTokenizerWrapper.from(modelFolder: folder, strict: false)
      let tokenizer = EnviousDecodeTokenizer(
        encode: { wrapper.encode(text: $0, addSpecialTokens: false) },
        decode: { wrapper.decode(tokens: $0, skipSpecialTokens: false) })
      let configuration = try EnviousDecodeRequestConfiguration(
        modelName: LLMProvider.egOneModelName,
        templateSHA256: try EnviousDecodeRequestMapperTests.sha256(
          folder.appendingPathComponent("chat_template.jinja")),
        contextTokens: contextTokens, tokenID: { wrapper.convertTokenToId($0) })
      let session = try await EnviousDecodeSession.load(
        targetDirectory: folder,
        draftDirectory: URL(
          fileURLWithPath: try #require(Fixtures.helperFolders[size] ?? nil), isDirectory: true))

      // The frozen cases of this size, read back as the app's two messages.
      let frozen = try JSONDecoder().decode(
        [Fixtures.RealCase].self,
        from: Data(contentsOf: URL(fileURLWithPath: try #require(Fixtures.casesFile))))
      let prefixes = try JSONDecoder().decode(
        [DFlashPrefixSnapshotTests.InstructionPrefix].self,
        from: Data(contentsOf: try #require(DFlashPrefixSnapshotTests.prefixesURL)))
      var cases: [Messages] = []
      for testCase in frozen where testCase.model == size {
        let text = tokenizer.decode(testCase.promptTokenIDs)
        let tail = EnviousDecodeChatTemplate.assistantHeader
        // A case recorded with the other template is left out: the folder's own template is used.
        guard text.hasPrefix(EnviousDecodeChatTemplate.systemHeader), text.hasSuffix(tail) else {
          continue
        }
        let parts = String(
          text.dropFirst(EnviousDecodeChatTemplate.systemHeader.count).dropLast(tail.count)
        ).components(separatedBy: EnviousDecodeChatTemplate.userHeader)
        guard parts.count == 2 else { continue }
        let prefix = prefixes.first {
          $0.model == size && testCase.promptTokenIDs.starts(with: $0.tokenIDs)
        }
        cases.append(
          Messages(
            label: testCase.name, system: parts[0], user: parts[1], cap: testCase.maxNewTokens,
            prefixTokens: try #require(prefix).tokenIDs.count))
      }
      return Reference(
        session: session, tokenizer: tokenizer, configuration: configuration, cases: cases)
    }

    func named(_ fragment: String) throws -> Messages {
      try #require(cases.first { $0.label.contains(fragment) }, "no frozen case named \(fragment)")
    }

    /// The answer the engine gives in this process for a request body.
    func expected(_ body: Data) throws -> (content: String, finish: String) {
      let prepared = try EnviousDecodeRequestMapper.prepare(
        body: body, configuration: configuration, tokenizer: tokenizer)
      let result = try session.generate(
        promptTokenIDs: prepared.promptTokenIDs, maxNewTokens: prepared.maxNewTokens,
        stopTokenIDs: prepared.stopTokenIDs,
        instructionPrefixTokenIDs: prepared.instructionPrefixTokenIDs)
      return try EnviousDecodeHelperIntegrationTests.fields(
        try EnviousDecodeRequestMapper.response(
          for: result, configuration: configuration, tokenizer: tokenizer))
    }
  }

  static func polishBody(_ messages: Messages) throws -> Data {
    try EnviousDecodeRequestMapperTests.data(
      try EnviousDecodeRequestMapperTests.polishBody(
        system: messages.system, user: messages.user, cap: messages.cap))
  }

  static func fields(_ data: Data) throws -> (content: String, finish: String) {
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let choice = try #require((json["choices"] as? [[String: Any]])?.first)
    return (
      try #require((choice["message"] as? [String: Any])?["content"] as? String),
      try #require(choice["finish_reason"] as? String)
    )
  }

  static func errorType(_ data: Data) -> String? {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
      .flatMap { $0["error"] as? [String: Any] }?["type"] as? String
  }

  // MARK: - 1. Start, token, and the app's requests

  @Test(
    "the built helper starts, answers only with the token, and gives the app's polish and summary requests the engine's own answer",
    .enabled(if: EnviousDecodeHelperIntegrationTests.canRun))
  func theHelperStartsAndAnswersTheAppsRequests() async throws {
    let reference = try await Reference.load(size: "mini")
    let helper = try Helper(size: "mini")
    defer { helper.stop() }
    try await helper.untilReady()

    // Health, and the token on both routes.
    #expect(try await helper.request("/health", bearer: helper.token).status == 200)
    #expect(try await helper.request("/health", bearer: nil).status == 401)
    #expect(try await helper.request("/health", bearer: helper.token + "x").status == 401)
    let english = try reference.named("dist-14DE212C")
    let body = try Self.polishBody(english)
    for bearer in [nil, "wrong", String(helper.token.dropLast())] {
      let refused = try await helper.request(
        "/v1/chat/completions", method: "POST", bearer: bearer, body: body)
      #expect(refused.status == 401, "bearer \(String(describing: bearer))")
    }

    // Polish, through the app's own transport, against the engine in this process.
    let expected = try reference.expected(body)
    let answer = try Self.fields(
      try await LocalPolishTransport.send(endpoint: helper.endpoint, body: body))
    #expect(answer.content == expected.content, "helper: \(answer.content)")
    #expect(answer.finish == "stop" && expected.finish == "stop")
    #expect(!expected.content.isEmpty)

    // A summary, through the app's own summary call (it sends `stream: false` and its own cap).
    let summary = try await EGOneSummaryCall.complete(
      endpoint: helper.endpoint, instructions: english.system, prompt: english.user,
      timeoutSeconds: 60)
    let summaryBody = try EnviousDecodeRequestMapperTests.data(
      EGOneSummaryCall.requestBody(
        instructions: english.system, prompt: english.user, hasLearnedWordAdapter: false))
    #expect(
      summary
        == (try reference.expected(summaryBody)).content.trimmingCharacters(
          in: .whitespacesAndNewlines))

    // A prompt that does not fit: the app's summary call reads it as "input too long".
    do {
      _ = try await EGOneSummaryCall.complete(
        endpoint: helper.endpoint, instructions: english.system,
        prompt: String(repeating: "word ", count: 20_000), timeoutSeconds: 60)
      Issue.record("an overlong prompt was answered")
    } catch {
      guard case LLMError.classified(.inputTooLong) = error else {
        Issue.record("an overlong prompt gave \(error)")
        return
      }
    }
    // A setting the engine does not serve, a path it does not have, a method it does not take.
    var streamed = try #require(
      try JSONSerialization.jsonObject(with: body) as? [String: Any])
    streamed["stream"] = true
    let refusedStream = try await helper.request(
      "/v1/chat/completions", method: "POST", bearer: helper.token,
      body: try EnviousDecodeRequestMapperTests.data(streamed))
    #expect(refusedStream.status == 400)
    #expect(Self.errorType(refusedStream.data) == "invalid_request_error")
    #expect(try await helper.request("/v1/models", bearer: helper.token).status == 404)
    #expect(
      try await helper.request("/health", method: "POST", bearer: helper.token, body: Data())
        .status == 405)

    // The helper's own log holds no token and no request or answer text.
    let log = helper.lines.joined(separator: "\n")
    #expect(!log.contains(helper.token) && !log.contains("TRANSCRIPT"))
    #expect(!log.contains(expected.content))
    #expect(helper.process.isRunning)
  }

  // MARK: - 2. One request at a time, and instruction texts kept apart

  @Test(
    "requests that arrive together are served one after the other with the right answers, and requests of two instruction texts keep their own saved state",
    .enabled(if: EnviousDecodeHelperIntegrationTests.canRun))
  func requestsAreServedOneAtATimeAndInstructionTextsStayApart() async throws {
    let reference = try await Reference.load(size: "mini")
    let english = try reference.named("dist-14DE212C")
    let german = try reference.named("de-de")
    let otherEnglish = try reference.named("v9_restraint")
    let cases = [english, german, otherEnglish]
    let bodies = try cases.map(Self.polishBody)
    let expected = try bodies.map { try reference.expected($0).content }
    #expect(Set(expected).count == 3, "the three cases must have three answers")

    let helper = try Helper(size: "mini")
    defer { helper.stop() }
    try await helper.untilReady()
    let endpoint = helper.endpoint

    // Three requests at once.
    async let first = LocalPolishTransport.send(endpoint: endpoint, body: bodies[0])
    async let second = LocalPolishTransport.send(endpoint: endpoint, body: bodies[1])
    async let third = LocalPolishTransport.send(endpoint: endpoint, body: bodies[2])
    let together = [try await first, try await second, try await third]
    for (index, data) in together.enumerated() {
      #expect(try Self.fields(data).content == expected[index], "together, request \(index)")
    }
    // The helper's log shows each request finished before the next one began.
    let spans = helper.lines.compactMap { line -> String? in
      line.contains(" begin ") ? "begin" : (line.contains(" end status=") ? "end" : nil)
    }
    #expect(spans == ["begin", "end", "begin", "end", "begin", "end"], "\(spans)")

    // English, German, English again: each answer is its own, and each request started from
    // the saved state of its own instruction text.
    let before = helper.lines.count
    for index in [0, 1, 0] {
      let data = try await LocalPolishTransport.send(endpoint: endpoint, body: bodies[index])
      #expect(try Self.fields(data).content == expected[index], "in turn, request \(index)")
    }
    let restored = helper.lines.dropFirst(before).compactMap { line -> Int? in
      line.firstMatch(of: /restored_prefix_tokens=(\d+)/).flatMap { Int($0.1) }
    }
    #expect(
      restored == [english.prefixTokens, german.prefixTokens, english.prefixTokens],
      "\(restored)")
    #expect(english.prefixTokens != german.prefixTokens)
  }

  // MARK: - 3. A client that goes away, and SIGTERM

  @Test(
    "a request whose client goes away is stopped and gets no answer, the helper serves the next request, and SIGTERM during a request ends the process within its bound",
    .enabled(if: EnviousDecodeHelperIntegrationTests.canRun))
  func aDroppedRequestIsStoppedAndSIGTERMEndsTheProcess() async throws {
    // The full-size model's long capped case runs for seconds: long enough to interrupt.
    let reference = try await Reference.load(size: "full")
    let long = try Self.polishBody(try reference.named("LONG-20000"))
    let shortCase = try reference.named("dist-14DE212C")
    let short = try Self.polishBody(shortCase)
    let expectedShort = try reference.expected(short).content

    let helper = try Helper(size: "full")
    defer { helper.stop() }
    try await helper.untilReady()
    let endpoint = helper.endpoint
    @Sendable func begun() -> Int { helper.lines.filter { $0.contains(" begin ") }.count }
    @Sendable func ended(_ status: String) -> Int {
      helper.lines.filter { $0.contains(" end status=\(status)") }.count
    }

    // The client drops the long request once the helper has begun it.
    let dropped = Task { try await LocalPolishTransport.send(endpoint: endpoint, body: long) }
    // deadline-fallback: the signal is the helper's "begin" line for the long request
    try await helper.signal("the long request to begin", within: 60) { begun() == 1 }
    dropped.cancel()
    let droppedResult = await dropped.result
    #expect(throws: (any Error).self) { try droppedResult.get() }
    // deadline-fallback: the signal is the helper's "end status=cancelled" line
    try await helper.signal("the helper to stop the dropped request", within: 10) {
      ended("cancelled") == 1
    }
    #expect(ended("200") == 0, "a dropped request was answered")
    // The next request is served, with the right answer.
    let next = try await LocalPolishTransport.send(endpoint: endpoint, body: short)
    #expect(try Self.fields(next).content == expectedShort)
    #expect(ended("200") == 1)

    // SIGTERM while a long request is being worked on.
    let pending = Task { try await LocalPolishTransport.send(endpoint: endpoint, body: long) }
    // deadline-fallback: the signal is the helper's "begin" line for the second long request
    try await helper.signal("the second long request to begin", within: 60) { begun() == 3 }
    let identifier = helper.process.processIdentifier
    let sent = ContinuousClock.now
    helper.process.terminate()
    // deadline-fallback: the signal is the process exit; the helper's stated bound is 2 s and this allows twice that
    try await helper.signal("the helper to exit after SIGTERM", within: 4) {
      !helper.process.isRunning
    }
    // test-fixture-timer: the helper's shutdown bound is the thing under test here
    let took = ContinuousClock.now - sent
    #expect(took < .seconds(3), "the helper took \(took) to exit")
    #expect(kill(identifier, 0) != 0, "a helper process is still there")
    let pendingResult = await pending.result
    #expect(throws: (any Error).self) { try pendingResult.get() }
    #expect(ended("200") == 1, "the request in progress at SIGTERM was answered")
    #expect(helper.lines.contains { $0.contains("stopping") })
  }
}
