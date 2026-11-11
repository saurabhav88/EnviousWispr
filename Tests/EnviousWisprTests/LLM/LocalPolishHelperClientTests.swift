import Foundation
import Testing

@testable import EnviousWisprLocalPolish

/// The one owner of app-to-helper requests (#4493). When these fail, a user with a healthy
/// local polish helper gets unpolished text, a cancelled dictation keeps the helper busy, or
/// every request leaks a connection until the app runs out of them.
///
/// The helper side is `LocalPolishAFUnixFakeHelper`, which shares no code with the client:
/// request bytes are compared with literals written from the HTTP contract, and responses are
/// literal bytes.
@Suite("Local polish helper client over a Unix socket (#4493)", .tags(.productOutcome))
struct LocalPolishHelperClientTests {

  // MARK: - Fixtures

  /// Collects what one request did with its descriptors.
  final class Ledger: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LocalPolishHelperClient.ResourceEvent] = []
    let ioFinished = BoundedWait.Signal()

    var observer: LocalPolishHelperClient.ResourceObserver {
      { [self] event in
        lock.withLock { events.append(event) }
        if event == .ioFinished { ioFinished.fire() }
      }
    }

    var isEmpty: Bool { lock.withLock { events.isEmpty } }

    func count(_ event: LocalPolishHelperClient.ResourceEvent) -> Int {
      lock.withLock { events.filter { $0 == event }.count }
    }

    /// Every descriptor the request opened was closed exactly once, and nothing was closed
    /// that was not opened. `socket` says whether the request was expected to open a socket.
    func expectBalanced(socket: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
      #expect(count(.opened(.cancelReader)) == 1, sourceLocation: sourceLocation)
      #expect(count(.closed(.cancelReader)) == 1, sourceLocation: sourceLocation)
      #expect(count(.opened(.cancelWriter)) == 1, sourceLocation: sourceLocation)
      #expect(count(.closed(.cancelWriter)) == 1, sourceLocation: sourceLocation)
      #expect(count(.opened(.socket)) == (socket ? 1 : 0), sourceLocation: sourceLocation)
      #expect(count(.closed(.socket)) == (socket ? 1 : 0), sourceLocation: sourceLocation)
      #expect(count(.ioFinished) == 1, sourceLocation: sourceLocation)
    }
  }

  static let token = "test-bearer-0123456789"
  static let queue = DispatchQueue(label: "helper-client-tests", attributes: .concurrent)

  static func response(_ status: String, headers: [String], body: String) -> Data {
    Data(("HTTP/1.1 \(status)\r\n" + headers.map { $0 + "\r\n" }.joined() + "\r\n" + body).utf8)
  }

  static let okBody = #"{"ok":true}"#
  static let ok = response(
    "200 OK",
    headers: ["Content-Type: application/json", "Content-Length: 11", "Connection: close"],
    body: okBody)

  /// Runs one request against `fake` and waits until the request has released everything.
  static func run(
    _ request: LocalPolishHelperRequest, on fake: LocalPolishAFUnixFakeHelper, ledger: Ledger
  ) async throws -> LocalPolishHelperResponse {
    defer { fake.stop() }
    do {
      let response = try await LocalPolishHelperClient.perform(
        request, at: .init(socketPath: fake.socketPath, authToken: token), ioQueue: queue,
        observer: ledger.observer)
      try await BoundedWait.until(ledger.ioFinished)
      return response
    } catch {
      try await BoundedWait.until(ledger.ioFinished)
      throw error
    }
  }

  /// Proves that nothing connected to `fake` before now. It sends one ordinary request and waits
  /// for its answer. The fake accepts connections one at a time in arrival order, so an earlier
  /// connection would have been counted before this one was answered.
  static func expectOnlyTheSentinelConnected(
    to fake: LocalPolishAFUnixFakeHelper, sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let response = try await LocalPolishHelperClient.perform(
      .init(method: .get, path: "/sentinel", timeout: .seconds(60)),
      at: .init(socketPath: fake.socketPath, authToken: token))
    #expect(response.status == 200, sourceLocation: sourceLocation)
    #expect(fake.acceptedConnections == 1, sourceLocation: sourceLocation)
  }

  // MARK: - The wire contract

  @Test("a POST goes out as exactly these bytes, and a 200 comes back as its status and body")
  func postBytesAndOKResponse() async throws {
    let fake = try LocalPolishAFUnixFakeHelper(script: .reply(Self.ok))
    let ledger = Ledger()
    let body = Data(#"{"messages":[]}"#.utf8)
    let response = try await Self.run(
      .init(method: .post, path: "/v1/chat/completions", body: body, timeout: .seconds(10)),
      on: fake, ledger: ledger)

    #expect(response == LocalPolishHelperResponse(status: 200, body: Data(Self.okBody.utf8)))
    let expected =
      "POST /v1/chat/completions HTTP/1.1\r\n"
      + "Host: localhost\r\n"
      + "Authorization: Bearer test-bearer-0123456789\r\n"
      + "Connection: close\r\n"
      + "Content-Type: application/json\r\n"
      + "Content-Length: 15\r\n"
      + "\r\n"
      + #"{"messages":[]}"#
    #expect(fake.requests == [Data(expected.utf8)])
    ledger.expectBalanced(socket: true)
  }

  @Test("a GET carries no body headers, and a 401 is returned as a response, not thrown")
  func getBytesAndUnauthorized() async throws {
    let denied = #"{"error":{"type":"authentication_error"}}"#
    let fake = try LocalPolishAFUnixFakeHelper(
      script: .reply(
        Self.response(
          "401 Unauthorized",
          headers: ["Content-Type: application/json", "Content-Length: \(denied.utf8.count)"],
          body: denied)))
    let ledger = Ledger()
    let response = try await Self.run(
      .init(method: .get, path: "/health", timeout: .seconds(10)), on: fake, ledger: ledger)

    #expect(response == LocalPolishHelperResponse(status: 401, body: Data(denied.utf8)))
    let expected =
      "GET /health HTTP/1.1\r\n"
      + "Host: localhost\r\n"
      + "Authorization: Bearer test-bearer-0123456789\r\n"
      + "Connection: close\r\n"
      + "\r\n"
    #expect(fake.requests == [Data(expected.utf8)])
    ledger.expectBalanced(socket: true)
  }

  @Test("a path or token that could break the request line is refused before any connection")
  func unsafeRequestIsRefused() async throws {
    let fake = try LocalPolishAFUnixFakeHelper(script: .reply(Self.ok))
    defer { fake.stop() }
    for path in ["/health HTTP/1.1\r\nX: y", "health", "/a b", "/a\r\nX: y", "/a\nb", "/a\rb"] {
      await #expect(throws: LocalPolishHelperClientError.failed) {
        _ = try await LocalPolishHelperClient.perform(
          .init(method: .get, path: path, timeout: .seconds(5)),
          at: .init(socketPath: fake.socketPath, authToken: Self.token))
      }
    }
    // A carriage-return-line-feed pair is ONE Character in Swift; it must still be refused.
    for token in ["a\r\nX-Injected: 1", "a\nb", "a\rb", "a b", ""] {
      await #expect(throws: LocalPolishHelperClientError.failed) {
        _ = try await LocalPolishHelperClient.perform(
          .init(method: .get, path: "/health", timeout: .seconds(5)),
          at: .init(socketPath: fake.socketPath, authToken: token))
      }
    }
    #expect(fake.requests.isEmpty)
  }

  // MARK: - Nothing to connect to

  @Test("a missing socket file and a socket nobody listens on are both 'not connectable'")
  func notConnectable() async throws {
    for path in [
      LocalPolishAFUnixFakeHelper.freshSocketPath(),
      try LocalPolishAFUnixFakeHelper.deadSocketPath(),
    ] {
      let ledger = Ledger()
      await #expect(throws: LocalPolishHelperClientError.notConnectable) {
        _ = try await LocalPolishHelperClient.perform(
          .init(method: .get, path: "/health", timeout: .seconds(10)),
          at: .init(socketPath: path, authToken: Self.token), ioQueue: Self.queue,
          observer: ledger.observer)
      }
      try await BoundedWait.until(ledger.ioFinished)
      ledger.expectBalanced(socket: true)
    }
  }

  @Test("a socket path too long for the system is refused, not truncated")
  func overlongPath() async throws {
    let ledger = Ledger()
    await #expect(throws: LocalPolishHelperClientError.failed) {
      _ = try await LocalPolishHelperClient.perform(
        .init(method: .get, path: "/health", timeout: .seconds(10)),
        at: .init(socketPath: "/" + String(repeating: "x", count: 104), authToken: Self.token),
        ioQueue: Self.queue, observer: ledger.observer)
    }
    try await BoundedWait.until(ledger.ioFinished)
    ledger.expectBalanced(socket: true)
  }

  @Test("what a failed connect means")
  func connectErrors() {
    #expect(LocalPolishHelperClient.connectError(ENOENT) == .notConnectable)
    #expect(LocalPolishHelperClient.connectError(ECONNREFUSED) == .notConnectable)
    #expect(LocalPolishHelperClient.connectError(ETIMEDOUT) == .timedOut)
    #expect(LocalPolishHelperClient.connectError(EACCES) == .failed)
  }

  // MARK: - Responses the client must and must not accept

  struct ResponseCase: Sendable, CustomTestStringConvertible {
    let name: String
    let bytes: Data
    let expected: Result<LocalPolishHelperResponse, LocalPolishHelperClientError>
    var testDescription: String { name }
  }

  static let body11 = #"{"ok":true}"#
  static let responseCases: [ResponseCase] = [
    ResponseCase(
      name: "one Content-Length, body of that length", bytes: ok,
      expected: .success(.init(status: 200, body: Data(body11.utf8)))),
    ResponseCase(
      name: "an empty body with Content-Length 0",
      bytes: response("200 OK", headers: ["Content-Length: 0"], body: ""),
      expected: .success(.init(status: 200, body: Data()))),
    ResponseCase(
      name: "the same Content-Length twice",
      bytes: response(
        "200 OK", headers: ["Content-Length: 11", "Content-Length: 11"], body: body11),
      expected: .failure(.failed)),
    ResponseCase(
      name: "two different Content-Lengths",
      bytes: response(
        "200 OK", headers: ["Content-Length: 11", "Content-Length: 5"], body: body11),
      expected: .failure(.failed)),
    ResponseCase(
      name: "Content-Length twice in different letter case",
      bytes: response(
        "200 OK", headers: ["content-length: 11", "CONTENT-LENGTH: 11"], body: body11),
      expected: .failure(.failed)),
    ResponseCase(
      name: "no Content-Length",
      bytes: response("200 OK", headers: ["Content-Type: application/json"], body: body11),
      expected: .failure(.failed)),
    ResponseCase(
      name: "a Content-Length that is not a number",
      bytes: response("200 OK", headers: ["Content-Length: eleven"], body: body11),
      expected: .failure(.failed)),
    ResponseCase(
      name: "a negative Content-Length",
      bytes: response("200 OK", headers: ["Content-Length: -1"], body: body11),
      expected: .failure(.failed)),
    ResponseCase(
      name: "more body than Content-Length says",
      bytes: response("200 OK", headers: ["Content-Length: 5"], body: body11),
      expected: .failure(.failed)),
    ResponseCase(
      name: "a Transfer-Encoding header",
      bytes: response(
        "200 OK", headers: ["Transfer-Encoding: chunked", "Content-Length: 11"], body: body11),
      expected: .failure(.failed)),
    ResponseCase(
      name: "a first line with an unknown HTTP version",
      bytes: Data("HTTP/9.9 200 OK\r\nContent-Length: 0\r\n\r\n".utf8), expected: .failure(.failed)),
    ResponseCase(
      name: "a status that is not a number",
      bytes: Data("HTTP/1.1 abc OK\r\nContent-Length: 0\r\n\r\n".utf8), expected: .failure(.failed)),
    ResponseCase(
      name: "a status below 100",
      bytes: Data("HTTP/1.1 99 X\r\nContent-Length: 0\r\n\r\n".utf8), expected: .failure(.failed)),
    ResponseCase(
      name: "a status above 599",
      bytes: Data("HTTP/1.1 600 X\r\nContent-Length: 0\r\n\r\n".utf8), expected: .failure(.failed)),
    ResponseCase(
      name: "only a blank line", bytes: Data("\r\n\r\n".utf8), expected: .failure(.failed)),
    ResponseCase(
      name: "bytes that are not an HTTP response",
      bytes: Data("HELLO\r\nContent-Length: 0\r\n\r\n".utf8), expected: .failure(.failed)),
    ResponseCase(
      name: "the connection closes after half the body",
      bytes: response("200 OK", headers: ["Content-Length: 11"], body: String(body11.prefix(5))),
      expected: .failure(.connectionLost)),
    ResponseCase(
      name: "the connection closes inside the headers",
      bytes: Data("HTTP/1.1 200 OK\r\nContent-Len".utf8), expected: .failure(.connectionLost)),
    ResponseCase(
      name: "the connection closes with nothing sent", bytes: Data(),
      expected: .failure(.connectionLost)),
  ]

  @Test("the helper's answer, then end of connection", arguments: responseCases)
  func responseAcceptance(_ testCase: ResponseCase) async throws {
    let fake = try LocalPolishAFUnixFakeHelper(script: .reply(testCase.bytes))
    let ledger = Ledger()
    let outcome: Result<LocalPolishHelperResponse, LocalPolishHelperClientError>
    do {
      outcome = .success(
        try await Self.run(
          .init(method: .get, path: "/health", timeout: .seconds(10)), on: fake, ledger: ledger))
    } catch let error as LocalPolishHelperClientError {
      outcome = .failure(error)
    }
    #expect(outcome == testCase.expected)
    // Every case, accepted or refused, releases the same resources.
    ledger.expectBalanced(socket: true)
  }

  // MARK: - Time limit and cancellation

  @Test("a helper that never answers costs the request's time limit, then the connection closes")
  func timeLimit() async throws {
    let fake = try LocalPolishAFUnixFakeHelper(script: .hold)
    defer { fake.stop() }
    let ledger = Ledger()
    let task = Task {
      try await LocalPolishHelperClient.perform(
        // test-fixture-timer: the client's own time limit is the thing under test
        .init(method: .get, path: "/health", timeout: .milliseconds(300)),
        at: .init(socketPath: fake.socketPath, authToken: Self.token), ioQueue: Self.queue,
        observer: ledger.observer)
    }
    try await BoundedWait.until(fake.requestReceived)
    let result = try await BoundedWait.result(of: task)
    #expect(throws: LocalPolishHelperClientError.timedOut) { try result.get() }
    // The helper sees the client go away, which is how it learns to stop working.
    try await BoundedWait.until(fake.peerDisconnected)
    try await BoundedWait.until(ledger.ioFinished)
    ledger.expectBalanced(socket: true)
  }

  @Test("cancelling a request in flight throws CancellationError and closes the connection")
  func cancelInFlight() async throws {
    let fake = try LocalPolishAFUnixFakeHelper(script: .hold)
    defer { fake.stop() }
    let ledger = Ledger()
    let task = Task {
      try await LocalPolishHelperClient.perform(
        .init(
          method: .post, path: "/v1/chat/completions", body: Data("{}".utf8), timeout: .seconds(60)),
        at: .init(socketPath: fake.socketPath, authToken: Self.token), ioQueue: Self.queue,
        observer: ledger.observer)
    }
    try await BoundedWait.until(fake.requestReceived)
    task.cancel()
    let result = try await BoundedWait.result(of: task)
    #expect(throws: CancellationError.self) { try result.get() }
    try await BoundedWait.until(fake.peerDisconnected)
    try await BoundedWait.until(ledger.ioFinished)
    ledger.expectBalanced(socket: true)
  }

  @Test("a task that is already cancelled opens nothing and never reaches the helper")
  func cancelledBeforeStart() async throws {
    let fake = try LocalPolishAFUnixFakeHelper(script: .reply(Self.ok))
    defer { fake.stop() }
    let ledger = Ledger()
    let task = Task {
      // The task cancels itself, so it IS cancelled when the client is called.
      withUnsafeCurrentTask { $0?.cancel() }
      return try await LocalPolishHelperClient.perform(
        .init(method: .get, path: "/health", timeout: .seconds(60)),
        at: .init(socketPath: fake.socketPath, authToken: Self.token), ioQueue: Self.queue,
        observer: ledger.observer)
    }
    let result = try await BoundedWait.result(of: task)
    #expect(throws: CancellationError.self) { try result.get() }
    // No pipe, no socket, no queued work: the request stopped at its first line.
    #expect(ledger.isEmpty)
    try await Self.expectOnlyTheSentinelConnected(to: fake)
  }

  @Test("cancelled after its socket exists but before it connects: it never connects")
  func cancelledAfterSocketCreation() async throws {
    let fake = try LocalPolishAFUnixFakeHelper(script: .reply(Self.ok))
    defer { fake.stop() }
    let ledger = Ledger()
    let socketOpened = BoundedWait.Signal()
    let proceed = DispatchSemaphore(value: 0)
    // Holds the I/O thread at the moment the socket exists and nothing was sent on it.
    let gate: LocalPolishHelperClient.ResourceObserver = { event in
      ledger.observer(event)
      if event == .opened(.socket) {
        socketOpened.fire()
        proceed.wait()
      }
    }
    let task = Task {
      try await LocalPolishHelperClient.perform(
        .init(
          method: .post, path: "/v1/chat/completions", body: Data("{}".utf8), timeout: .seconds(60)),
        at: .init(socketPath: fake.socketPath, authToken: Self.token), ioQueue: Self.queue,
        observer: gate)
    }
    do {
      try await BoundedWait.until(socketOpened)
    } catch {
      proceed.signal()
      throw error
    }
    task.cancel()
    let result = try await BoundedWait.result(of: task)
    proceed.signal()
    #expect(throws: CancellationError.self) { try result.get() }
    try await BoundedWait.until(ledger.ioFinished)
    ledger.expectBalanced(socket: true)
    try await Self.expectOnlyTheSentinelConnected(to: fake)
  }

  @Test("a request with no time left times out without connecting")
  func noTimeLeft() async throws {
    let fake = try LocalPolishAFUnixFakeHelper(script: .reply(Self.ok))
    defer { fake.stop() }
    let ledger = Ledger()
    await #expect(throws: LocalPolishHelperClientError.timedOut) {
      _ = try await LocalPolishHelperClient.perform(
        .init(method: .get, path: "/health", timeout: .zero),
        at: .init(socketPath: fake.socketPath, authToken: Self.token), ioQueue: Self.queue,
        observer: ledger.observer)
    }
    try await BoundedWait.until(ledger.ioFinished)
    ledger.expectBalanced(socket: false)
    try await Self.expectOnlyTheSentinelConnected(to: fake)
  }

  @Test("cancelled while its I/O is still queued: it does not connect, and it releases its pipe")
  func cancelledWhileQueued() async throws {
    let fake = try LocalPolishAFUnixFakeHelper(script: .reply(Self.ok))
    defer { fake.stop() }
    let ledger = Ledger()
    let parked = DispatchQueue(label: "helper-client-tests.parked", attributes: .initiallyInactive)
    let queued = BoundedWait.Signal()
    let gate: LocalPolishHelperClient.ResourceObserver = { event in
      ledger.observer(event)
      if event == .opened(.cancelWriter) { queued.fire() }
    }
    let task = Task {
      try await LocalPolishHelperClient.perform(
        .init(method: .get, path: "/health", timeout: .seconds(60)),
        at: .init(socketPath: fake.socketPath, authToken: Self.token), ioQueue: parked,
        observer: gate)
    }
    try await BoundedWait.until(queued)
    task.cancel()
    let result = try await BoundedWait.result(of: task)
    #expect(throws: CancellationError.self) { try result.get() }
    parked.activate()
    try await BoundedWait.until(ledger.ioFinished)
    ledger.expectBalanced(socket: false)
    #expect(fake.requests.isEmpty)
  }

  @Test("the time limit ends a request whose I/O never started, and nothing is left open")
  func deadlineBeforeIOStarts() async throws {
    let fake = try LocalPolishAFUnixFakeHelper(script: .reply(Self.ok))
    defer { fake.stop() }
    let ledger = Ledger()
    let parked = DispatchQueue(label: "helper-client-tests.parked", attributes: .initiallyInactive)
    await #expect(throws: LocalPolishHelperClientError.timedOut) {
      _ = try await LocalPolishHelperClient.perform(
        // test-fixture-timer: the client's own time limit is the thing under test
        .init(method: .get, path: "/health", timeout: .milliseconds(100)),
        at: .init(socketPath: fake.socketPath, authToken: Self.token), ioQueue: parked,
        observer: ledger.observer)
    }
    #expect(ledger.count(.ioFinished) == 0)
    parked.activate()
    try await BoundedWait.until(ledger.ioFinished)
    ledger.expectBalanced(socket: false)
    #expect(fake.requests.isEmpty)
  }

  @Test("finishing twice, or cancelling after the answer, changes nothing and closes nothing twice")
  func finishIsFirstWins() throws {
    var ends: [Int32] = [-1, -1]
    try #require(pipe(&ends) == 0)
    defer { close(ends[0]) }
    let ledger = Ledger()
    let state = LocalPolishHelperClient.RequestState(
      cancelWriter: ends[1], observer: ledger.observer)
    #expect(!state.isFinished)
    state.finish(.success(.init(status: 200, body: Data())))
    #expect(state.isFinished)
    state.retireCancelWriter()
    // After the answer and after retirement: a late cancellation and a second retirement.
    state.finish(.failure(CancellationError()))
    state.finish(.failure(LocalPolishHelperClientError.timedOut))
    state.retireCancelWriter()
    #expect(ledger.count(.closed(.cancelWriter)) == 1)
    // The first finish woke the reader with exactly one byte; the late ones wrote nothing.
    _ = fcntl(ends[0], F_SETFL, fcntl(ends[0], F_GETFL) | O_NONBLOCK)
    var buffer = [UInt8](repeating: 0, count: 8)
    #expect(read(ends[0], &buffer, buffer.count) == 1)
    #expect(read(ends[0], &buffer, buffer.count) == 0)  // write end closed, nothing more
  }

  @Test("a result that is already delivered survives cancelling the caller afterwards")
  func cancelAfterCompletion() async throws {
    let fake = try LocalPolishAFUnixFakeHelper(script: .reply(Self.ok))
    let ledger = Ledger()
    let task = Task {
      try await Self.run(
        .init(method: .get, path: "/health", timeout: .seconds(10)), on: fake, ledger: ledger)
    }
    let response = try await BoundedWait.result(of: task).get()
    task.cancel()
    #expect(response.status == 200)
    ledger.expectBalanced(socket: true)
  }

  // MARK: - Concurrency

  @Test("eight requests at once each get their own answer")
  func eightConcurrent() async throws {
    // The fake answers nobody until all eight are waiting, so they provably overlap.
    let fake = try LocalPolishAFUnixFakeHelper(script: .answerTogether(count: 8))
    defer { fake.stop() }
    let address = LocalPolishHelperAddress(socketPath: fake.socketPath, authToken: Self.token)
    let ledgers = (0..<8).map { _ in Ledger() }
    let work = Task {
      try await withThrowingTaskGroup(of: (Int, LocalPolishHelperResponse).self) { group in
        for index in 0..<8 {
          group.addTask {
            let response = try await LocalPolishHelperClient.perform(
              .init(method: .get, path: "/r/\(index)", timeout: .seconds(30)), at: address,
              ioQueue: Self.queue, observer: ledgers[index].observer)
            return (index, response)
          }
        }
        var answers: [Int: LocalPolishHelperResponse] = [:]
        for try await (index, response) in group { answers[index] = response }
        return answers
      }
    }
    let answers = try await BoundedWait.result(of: work, onExpiry: { fake.stop() }).get()
    #expect(answers.count == 8)
    for index in 0..<8 {
      #expect(answers[index] == .init(status: 200, body: Data(#"{"path":"/r/\#(index)"}"#.utf8)))
      try await BoundedWait.until(ledgers[index].ioFinished)
      ledgers[index].expectBalanced(socket: true)
    }
    #expect(fake.requests.count == 8)
  }

  // MARK: - The deadline as a poll timeout

  @Test("time left is rounded up to a whole millisecond, and no time left is zero")
  func pollTimeoutRounding() {
    #expect(LocalPolishHelperClient.pollTimeoutMilliseconds(remaining: .microseconds(1)) == 1)
    #expect(LocalPolishHelperClient.pollTimeoutMilliseconds(remaining: .microseconds(999)) == 1)
    #expect(LocalPolishHelperClient.pollTimeoutMilliseconds(remaining: .milliseconds(1)) == 1)
    #expect(LocalPolishHelperClient.pollTimeoutMilliseconds(remaining: .microseconds(1001)) == 2)
    #expect(LocalPolishHelperClient.pollTimeoutMilliseconds(remaining: .seconds(20)) == 20_000)
    #expect(LocalPolishHelperClient.pollTimeoutMilliseconds(remaining: .zero) == 0)
    #expect(LocalPolishHelperClient.pollTimeoutMilliseconds(remaining: .milliseconds(-5)) == 0)
    #expect(
      LocalPolishHelperClient.pollTimeoutMilliseconds(remaining: .seconds(10_000_000_000))
        == Int32.max)
  }
}
