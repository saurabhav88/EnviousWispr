import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #3269: the bug-report outbox. Temporary folders, a scripted HTTP recorder, a fake network path
/// and a settable clock; no real network. The scheduled wake never fires on its own here (the
/// sleeper throws), so each test drives `drain()` explicitly.
@Suite("Feedback outbox (#3269)", .tags(.productOutcome))
struct FeedbackOutboxTests {

  final class FakePath: FeedbackPathMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var satisfied: Bool
    private var handler: (@Sendable (Bool) -> Void)?
    init(satisfied: Bool) { self.satisfied = satisfied }
    var isSatisfied: Bool { lock.withLock { satisfied } }
    func start(onChange: @escaping @Sendable (Bool) -> Void) {
      lock.withLock { handler = onChange }
    }
    func cancel() { lock.withLock { handler = nil; cancelled = true } }
    private var cancelled = false
    var wasCancelled: Bool { lock.withLock { cancelled } }
    func set(_ value: Bool) {
      let callback = lock.withLock { () -> (@Sendable (Bool) -> Void)? in
        satisfied = value
        return handler
      }
      callback?(value)
    }
  }

  final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
  }

  /// Answers each request from a script and records the event id of every attempt.
  final class HTTP: @unchecked Sendable {
    enum Answer {
      case status(Int, [String: String])
      case networkError
    }
    private let lock = NSLock()
    private var script: [Answer]
    private(set) var eventIDs: [String] = []
    init(_ script: [Answer]) { self.script = script }
    var sent: [String] { lock.withLock { eventIDs } }
    func call(_ request: URLRequest) throws -> (status: Int, headers: [String: String]) {
      let answer: Answer = lock.withLock {
        let body = request.httpBody ?? Data()
        let firstLine = body.split(separator: 0x0A).first.map { Data($0) } ?? Data()
        let header = (try? JSONSerialization.jsonObject(with: firstLine)) as? [String: Any]
        eventIDs.append(header?["event_id"] as? String ?? "?")
        return script.isEmpty ? .status(200, [:]) : script.removeFirst()
      }
      switch answer {
      case .status(let code, let headers): return (code, headers)
      case .networkError: throw URLError(.notConnectedToInternet)
      }
    }
  }

  /// Holds the first request that enters until `release()`, so a test can act while a send is
  /// in flight. Later requests pass straight through.
  actor Gate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enter() async {
      // Keep the first waiter; concurrent extra sends must reach the HTTP recorder.
      if released || entered { return }
      entered = true
      for waiter in enteredWaiters { waiter.resume() }
      enteredWaiters = []
      await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
      if entered { return }
      await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
      released = true
      releaseWaiter?.resume()
      releaseWaiter = nil
    }
  }

  static let start = Date(timeIntervalSince1970: 1_790_000_000)
  static let dsn = FeedbackDSN("https://abc@o1.ingest.sentry.io/42")!

  static func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-3269-outbox-\(UUID().uuidString)", isDirectory: true)
  }

  static func record(_ n: Int, at date: Date = start) -> FeedbackRecord {
    FeedbackRecord(
      id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!,
      submittedAt: date, message: "report \(n)", email: nil, attachment: nil,
      context: FeedbackReporterTests.context, attempts: 0, nextAttemptAt: nil, state: .pending,
      rejectedStatus: nil)
  }

  static func eventID(_ n: Int) -> String { String(format: "00000000000040008000%012d", n) }

  static func records(in directory: URL) throws -> [FeedbackRecord] {
    let url = directory.appendingPathComponent("outbox.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode(FeedbackOutbox.Document.self, from: Data(contentsOf: url))
      .records
  }

  static func makeOutbox(
    _ directory: URL, http: HTTP?, path: FakePath = FakePath(satisfied: true),
    clock: Clock = Clock(start),
    writeData: (@Sendable (Data, URL) throws -> Void)? = nil,
    readData: (@Sendable (URL) throws -> Data)? = nil,
    gate: Gate? = nil,
    maxEncodedBytes: Int = FeedbackOutbox.maxEncodedBytes
  ) -> FeedbackOutbox {
    let sender = http.map { http in
      FeedbackSender(
        dsn: dsn,
        http: { request in
          await gate?.enter()
          return try http.call(request)
        }, now: { clock.now })
    }
    return FeedbackOutbox(
      directory: directory, sender: sender, path: path, now: { clock.now },
      sleep: { _ in throw CancellationError() },
      writeData: writeData ?? { data, url in
        try DurableJSONFile.write(data: data, to: url, tempPrefix: ".outbox")
      },
      readData: readData ?? { try Data(contentsOf: $0) }, maxEncodedBytes: maxEncodedBytes)
  }

  // MARK: - Enqueue

  @Test("A saved report is on disk and survives a new outbox (a restart)")
  func enqueueIsDurable() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = FakePath(satisfied: false)
    let outbox = Self.makeOutbox(directory, http: HTTP([]), path: path)

    #expect(await outbox.enqueue(Self.record(1)) == .saved(offline: true))
    #expect(try Self.records(in: directory).map(\.message) == ["report 1"])

    let reopened = Self.makeOutbox(directory, http: HTTP([]))
    await reopened.drain()
    #expect(try Self.records(in: directory).isEmpty)
  }

  // MARK: - Help-check outcome (#3275)

  /// A saved report exactly as #3269 wrote it, before help metadata existed. A literal, not an
  /// encoding of today's type, so it stays the old format whatever the type becomes.
  static let preHelpDocument = """
    {"records":[{"attempts":0,"context":{"appBuild":"252","appVersion":"2.5.2",\
    "environment":"production","osBuild":"24E248","osVersion":"15.4.0",\
    "release":"com.enviouswispr.app@2.5.2"},"id":"00000000-0000-4000-8000-000000000001",\
    "message":"report 1","state":"pending","submittedAt":811692800}],"schema_version":1}
    """

  @Test("A report saved before help metadata existed still loads, with none, and is delivered")
  func preHelpRecordDecodes() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(Self.preHelpDocument.utf8).write(to: directory.appendingPathComponent("outbox.json"))

    let loaded = try #require(try Self.records(in: directory).first)
    #expect(loaded.helpOutcome == nil)
    #expect(loaded.message == "report 1")
    #expect(loaded.submittedAt == Self.start)
    // Its envelope is the one the pre-help build would have sent: no tags.
    let payload = FeedbackSender.feedbackPayload(for: loaded)
    #expect(payload["tags"] == nil)
    #expect(payload["level"] as? String == "error")

    let http = HTTP([])
    await Self.makeOutbox(directory, http: http).drain()
    #expect(http.sent == [Self.eventID(1)])
    #expect(try Self.records(in: directory).isEmpty)
  }

  @Test("Help metadata that no longer decodes drops only the metadata; the report is kept and sent")
  func damagedHelpMetadataKeepsTheReport() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Six cards is out of bounds (at most three).
    let damaged = Self.preHelpDocument.replacingOccurrences(
      of: #""message":"report 1","#,
      with: #""helpOutcome":{"schemaVersion":1,"terminalOutcome":"still_sent","mode":"decomposed","overflow":false,"shownCardCount":6,"issues":[]},"message":"report 1","#)
    #expect(damaged != Self.preHelpDocument)
    try Data(damaged.utf8).write(to: directory.appendingPathComponent("outbox.json"))

    let loaded = try #require(try Self.records(in: directory).first)
    #expect(loaded.helpOutcome == nil)
    #expect(loaded.message == "report 1")
    let http = HTTP([])
    await Self.makeOutbox(directory, http: http).drain()
    #expect(http.sent == [Self.eventID(1)])
  }

  @Test("Help metadata frozen at Send survives a restart, a retry and a rejection unchanged")
  func helpMetadataSurvivesRetries() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let http = HTTP([.networkError, .status(413, [:])])
    let help = FeedbackSenderTests.helpOutcome
    let record = FeedbackRecord(
      id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, submittedAt: Self.start,
      message: "report 1", email: nil, attachment: nil, context: FeedbackReporterTests.context,
      attempts: 0, nextAttemptAt: nil, state: .pending, rejectedStatus: nil, helpOutcome: help)
    let outbox = Self.makeOutbox(directory, http: http, clock: clock)
    #expect(await outbox.enqueue(record) == .saved(offline: false))
    #expect(try Self.records(in: directory).first?.helpOutcome == help)

    await outbox.drain()  // network error: kept with a backoff
    let retried = try #require(try Self.records(in: directory).first)
    #expect(retried.attempts == 1)
    #expect(retried.helpOutcome == help)

    clock.advance(61)
    let relaunched = Self.makeOutbox(directory, http: http, clock: clock)
    await relaunched.drain()  // 413: kept as rejected
    let rejected = try #require(try Self.records(in: directory).first)
    #expect(rejected.state == .rejected)
    #expect(rejected.helpOutcome == help)
    #expect(http.sent == [Self.eventID(1), Self.eventID(1)])
  }

  @Test("The 51st report is refused and nothing is evicted")
  func fullOutbox() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = Self.makeOutbox(directory, http: HTTP([]), path: FakePath(satisfied: false))
    for n in 1...50 { #expect(await outbox.enqueue(Self.record(n)) == .saved(offline: true)) }

    #expect(await outbox.enqueue(Self.record(51)) == .full)
    #expect(try Self.records(in: directory).count == 50)
  }

  @Test("A file that cannot be read is never replaced by a new report")
  func unreadableFileIsKept() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let offline = FakePath(satisfied: false)
    let first = Self.makeOutbox(directory, http: HTTP([]), path: offline)
    #expect(await first.enqueue(Self.record(1)) == .saved(offline: true))
    let blocked = Self.makeOutbox(
      directory, http: HTTP([]), path: offline,
      readData: { _ in throw CocoaError(.fileReadNoPermission) })

    #expect(await blocked.enqueue(Self.record(2)) == .unavailable)
    #expect(try Self.records(in: directory).map(\.message) == ["report 1"])
  }

  // MARK: - Delivery

  @Test("Oldest first, one at a time; a report leaves only after Sentry accepts it")
  func fifoAndRemoval() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let http = HTTP([.status(200, [:]), .status(200, [:])])
    let path = FakePath(satisfied: false)
    let outbox = Self.makeOutbox(directory, http: http, path: path)
    _ = await outbox.enqueue(Self.record(1))
    _ = await outbox.enqueue(Self.record(2, at: Self.start.addingTimeInterval(5)))

    path.set(true)
    await outbox.drain()

    #expect(http.sent == [Self.eventID(1), Self.eventID(2)])
    #expect(try Self.records(in: directory).isEmpty)
  }

  @Test("Offline: nothing is sent; the report waits")
  func offlineSendsNothing() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let http = HTTP([])
    let outbox = Self.makeOutbox(directory, http: http, path: FakePath(satisfied: false))
    _ = await outbox.enqueue(Self.record(1))

    await outbox.drain()

    #expect(http.sent == [])
    #expect(try Self.records(in: directory).count == 1)
  }

  @Test("A network error keeps the report with a backoff that a new launch does not bypass")
  func networkErrorBacksOff() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let http = HTTP([.networkError])
    let outbox = Self.makeOutbox(directory, http: http, clock: clock)
    _ = await outbox.enqueue(Self.record(1))
    await outbox.drain()

    let kept = try #require(try Self.records(in: directory).first)
    #expect(kept.attempts == 1)
    #expect(kept.nextAttemptAt == Self.start.addingTimeInterval(60))

    // A relaunch replaces the old outbox. Stop it first, as quitting does: enqueue's own
    // background drain could otherwise run after the clock moves and send again (#3290).
    await outbox.stop()
    let relaunched = Self.makeOutbox(directory, http: http, clock: clock)
    await relaunched.drain()
    #expect(http.sent.count == 1)

    clock.advance(61)
    await relaunched.drain()
    #expect(http.sent == [Self.eventID(1), Self.eventID(1)])
    #expect(try Self.records(in: directory).isEmpty)
  }

  @Test("A 200 with a rate limit delivers that report and holds the rest until it expires")
  func rateLimitHoldsAll() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let http = HTTP([.status(200, ["X-Sentry-Rate-Limits": "600:feedback:organization"])])
    let outbox = Self.makeOutbox(directory, http: http, clock: clock)
    _ = await outbox.enqueue(Self.record(1))
    _ = await outbox.enqueue(Self.record(2))
    await outbox.drain()
    // The 200 delivered report 1; its rate limit holds report 2.
    #expect(http.sent == [Self.eventID(1)])
    #expect(try Self.records(in: directory).map(\.message) == ["report 2"])

    clock.advance(300)
    // A relaunch replaces the old outbox. Stop it first, as quitting does: enqueue's own
    // background drain could otherwise run after the clock moves and send again (#3290).
    await outbox.stop()
    let relaunched = Self.makeOutbox(directory, http: http, clock: clock)
    await relaunched.drain()
    #expect(http.sent.count == 1)

    clock.advance(301)
    await relaunched.drain()
    #expect(http.sent == [Self.eventID(1), Self.eventID(2)])
    #expect(try Self.records(in: directory).isEmpty)
  }

  @Test("A refused payload is kept as rejected and does not block later reports")
  func rejectedDoesNotBlock() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let http = HTTP([.status(413, [:]), .status(200, [:])])
    let outbox = Self.makeOutbox(directory, http: http)
    _ = await outbox.enqueue(Self.record(1))
    _ = await outbox.enqueue(Self.record(2))
    await outbox.drain()

    let left = try Self.records(in: directory)
    #expect(left.map(\.message) == ["report 1"])
    #expect(left.first?.state == .rejected)
    #expect(left.first?.rejectedStatus == 413)
    #expect(await outbox.hasUndeliverableReports() == true)

    await outbox.drain()
    #expect(http.sent == [Self.eventID(1), Self.eventID(2)])
  }

  @Test("An authentication failure pauses sending and marks no report as bad")
  func authFailurePauses() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let http = HTTP([.status(401, [:])])
    let outbox = Self.makeOutbox(directory, http: http)
    _ = await outbox.enqueue(Self.record(1))
    _ = await outbox.enqueue(Self.record(2))
    await outbox.drain()
    await outbox.drain()

    #expect(http.sent == [Self.eventID(1)])
    #expect(try Self.records(in: directory).map(\.state) == [.pending, .pending])
    #expect(await outbox.isPaused == true)
    #expect(await outbox.hasUndeliverableReports() == true)
  }

  @Test(
    "Accepted but the removal failed: the report stays and is sent again with the same id later")
  func failedRemovalResendsSameID() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let http = HTTP([.status(200, [:]), .status(200, [:])])
    let failWrites = WriteSwitch()
    let outbox = Self.makeOutbox(
      directory, http: http, clock: clock,
      writeData: { data, url in
        if failWrites.isOn { throw CocoaError(.fileWriteNoPermission) }
        try DurableJSONFile.write(data: data, to: url, tempPrefix: ".outbox")
      })
    _ = await outbox.enqueue(Self.record(1))
    failWrites.isOn = true
    await outbox.drain()
    #expect(try Self.records(in: directory).count == 1)

    await outbox.drain()
    #expect(http.sent.count == 1)

    failWrites.isOn = false
    clock.advance(61)
    await outbox.drain()
    #expect(http.sent == [Self.eventID(1), Self.eventID(1)])
    #expect(try Self.records(in: directory).isEmpty)
  }

  @Test("Going back online sends what waited while offline")
  func pathFlapping() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let http = HTTP([])
    let gate = Gate()
    let path = FakePath(satisfied: false)
    let outbox = Self.makeOutbox(directory, http: http, path: path, gate: gate)
    _ = await outbox.enqueue(Self.record(1))
    _ = await outbox.enqueue(Self.record(2))

    // Online just long enough for report 1 to start, then offline before it finishes.
    path.set(true)
    let firstPass = Task { await outbox.drain() }
    await gate.waitUntilEntered()
    path.set(false)
    await gate.release()
    await firstPass.value
    #expect(http.sent == [Self.eventID(1)])
    #expect(try Self.records(in: directory).map(\.id) == [Self.record(2).id])

    // Only coming back online sends report 2.
    path.set(true)
    await outbox.drain()
    #expect(http.sent == [Self.eventID(1), Self.eventID(2)])
    #expect(try Self.records(in: directory).isEmpty)
  }

  @Test("An outbox file that cannot be read counts as undeliverable, for the form's notice")
  func unreadableFileIsUndeliverable() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let offline = FakePath(satisfied: false)
    let first = Self.makeOutbox(directory, http: HTTP([]), path: offline)
    _ = await first.enqueue(Self.record(1))
    #expect(await first.hasUndeliverableReports() == false)

    let blocked = Self.makeOutbox(
      directory, http: HTTP([]), path: offline,
      readData: { _ in throw CocoaError(.fileReadNoPermission) })
    #expect(await blocked.hasUndeliverableReports() == true)
  }

  @Test("Reports saved at the same time are all kept, and each is sent exactly once")
  func concurrentEnqueueAndDrain() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let http = HTTP([])
    let outbox = Self.makeOutbox(directory, http: http)
    await withTaskGroup(of: Void.self) { group in
      for n in 1...20 { group.addTask { _ = await outbox.enqueue(Self.record(n)) } }
      for _ in 1...5 { group.addTask { await outbox.drain() } }
    }
    // Chained after every pass already requested, so it sends whatever they left.
    await outbox.drain()

    #expect(try Self.records(in: directory).isEmpty)
    #expect(http.sent.count == 20)
    #expect(Set(http.sent) == Set((1...20).map(Self.eventID)))
  }

  @Test("Shutdown stops watching the network and leaves saved reports on disk")
  func stopKeepsReports() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let http = HTTP([])
    let path = FakePath(satisfied: false)
    let outbox = Self.makeOutbox(directory, http: http, path: path)
    await outbox.start()
    _ = await outbox.enqueue(Self.record(1))

    await outbox.stop()

    #expect(path.wasCancelled)
    #expect(http.sent == [])
    #expect(try Self.records(in: directory).map(\.message) == ["report 1"])
  }

  @Test("Without a DSN a new report is refused, so the form keeps the words")
  func missingDSNRefuses() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = Self.makeOutbox(directory, http: nil)

    #expect(await outbox.enqueue(Self.record(1)) == .unavailable)
    #expect(try Self.records(in: directory).isEmpty)
  }

  @Test(
    "Shutdown or a lost network during a send: that report finishes, the next is not attempted",
    arguments: [true, false])
  func stopDuringSendHoldsTheNext(byShutdown: Bool) async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let http = HTTP([])
    let gate = Gate()
    let path = FakePath(satisfied: false)
    let outbox = Self.makeOutbox(directory, http: http, path: path, gate: gate)
    _ = await outbox.enqueue(Self.record(1))
    _ = await outbox.enqueue(Self.record(2))
    path.set(true)
    let pass = Task { await outbox.drain() }
    await gate.waitUntilEntered()

    if byShutdown { await outbox.stop() } else { path.set(false) }
    await gate.release()
    await pass.value

    #expect(http.sent == [Self.eventID(1)])
    #expect(try Self.records(in: directory).map(\.message) == ["report 2"])
  }

  @Test("A too-many-requests answer that could not be written still holds every report")
  func unwrittenRetryLimitHoldsAll() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let http = HTTP([.status(429, ["Retry-After": "600"])])
    let failWrites = WriteSwitch()
    let path = FakePath(satisfied: false)
    let outbox = Self.makeOutbox(
      directory, http: http, path: path, clock: clock,
      writeData: { data, url in
        if failWrites.isOn { throw CocoaError(.fileWriteNoPermission) }
        try DurableJSONFile.write(data: data, to: url, tempPrefix: ".outbox")
      })
    _ = await outbox.enqueue(Self.record(1))
    _ = await outbox.enqueue(Self.record(2))
    failWrites.isOn = true
    // Not started, so this changes the path without triggering a pass of its own.
    path.set(true)
    await outbox.drain()
    await outbox.drain()
    #expect(http.sent == [Self.eventID(1)], "the second report waits behind the limit")

    failWrites.isOn = false
    clock.advance(599)
    await outbox.drain()
    #expect(http.sent == [Self.eventID(1)])

    clock.advance(2)
    await outbox.drain()
    #expect(Set(http.sent) == [Self.eventID(1), Self.eventID(2)])
    #expect(try Self.records(in: directory).isEmpty)
  }

  @Test("A rate limit that could not be written still holds every report until it expires")
  func unwrittenRateLimitHoldsAll() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let http = HTTP([.status(200, ["X-Sentry-Rate-Limits": "600:feedback:organization"])])
    let failWrites = WriteSwitch()
    let path = FakePath(satisfied: false)
    let outbox = Self.makeOutbox(
      directory, http: http, path: path, clock: clock,
      writeData: { data, url in
        if failWrites.isOn { throw CocoaError(.fileWriteNoPermission) }
        try DurableJSONFile.write(data: data, to: url, tempPrefix: ".outbox")
      })
    _ = await outbox.enqueue(Self.record(1))
    _ = await outbox.enqueue(Self.record(2))
    failWrites.isOn = true
    // Not started, so this changes the path without triggering a pass of its own.
    path.set(true)
    await outbox.drain()
    await outbox.drain()
    #expect(http.sent == [Self.eventID(1)])

    failWrites.isOn = false
    clock.advance(599)
    await outbox.drain()
    #expect(http.sent == [Self.eventID(1)])

    clock.advance(2)
    await outbox.drain()
    #expect(Set(http.sent) == [Self.eventID(1), Self.eventID(2)])
    #expect(try Self.records(in: directory).isEmpty)
  }

  @Test("A full outbox stays within its byte limit after retries and rejections add details")
  func byteLimitHoldsAfterMetadata() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let limit = 6000
    let clock = Clock(Self.start)
    let http = HTTP(
      [.networkError] + Array(repeating: HTTP.Answer.status(400, [:]), count: 20))
    let path = FakePath(satisfied: false)
    let outbox = Self.makeOutbox(
      directory, http: http, path: path, clock: clock, maxEncodedBytes: limit)
    var admitted = 0
    while await outbox.enqueue(Self.record(admitted + 1)) == .saved(offline: true) {
      admitted += 1
    }
    #expect(admitted >= 2)

    // Every report gains a rejection; the first also gains an attempt count and next attempt.
    path.set(true)
    await outbox.drain()
    clock.advance(61)
    await outbox.drain()

    let records = try Self.records(in: directory)
    #expect(records.count == admitted)
    #expect(records.allSatisfy { $0.state == .rejected && $0.rejectedStatus == 400 })
    #expect(records.first?.attempts == 1)
    let bytes = try Data(contentsOf: directory.appendingPathComponent("outbox.json")).count
    #expect(bytes <= limit)
  }

  @Test(
    "A refused report's rate limit holds the next report, even when the limit could not be written",
    arguments: [false, true])
  func rejectedLimitHoldsNext(writesFail: Bool) async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let http = HTTP([.status(413, ["X-Sentry-Rate-Limits": "600:feedback:organization"])])
    let failWrites = WriteSwitch()
    let path = FakePath(satisfied: false)
    let outbox = Self.makeOutbox(
      directory, http: http, path: path, clock: clock,
      writeData: { data, url in
        if failWrites.isOn { throw CocoaError(.fileWriteNoPermission) }
        try DurableJSONFile.write(data: data, to: url, tempPrefix: ".outbox")
      })
    _ = await outbox.enqueue(Self.record(1))
    _ = await outbox.enqueue(Self.record(2))
    failWrites.isOn = writesFail
    path.set(true)
    await outbox.drain()
    await outbox.drain()
    #expect(http.sent == [Self.eventID(1)])

    failWrites.isOn = false
    clock.advance(601)
    await outbox.drain()
    #expect(http.sent == [Self.eventID(1), Self.eventID(2)])
  }

  @Test("A credentials failure keeps its rate limit across a relaunch")
  func configurationFailureKeepsLimit() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let http = HTTP([.status(401, ["X-Sentry-Rate-Limits": "600:feedback:organization"])])
    let path = FakePath(satisfied: false)
    let outbox = Self.makeOutbox(directory, http: http, path: path, clock: clock)
    _ = await outbox.enqueue(Self.record(1))
    path.set(true)
    await outbox.drain()
    #expect(await outbox.isPaused == true)

    // A new launch is no longer paused, but the stored limit still holds the report.
    clock.advance(300)
    // A relaunch replaces the old outbox. Stop it first, as quitting does: enqueue's own
    // background drain could otherwise run after the clock moves and send again (#3290).
    await outbox.stop()
    let relaunched = Self.makeOutbox(directory, http: http, clock: clock)
    await relaunched.drain()
    #expect(http.sent == [Self.eventID(1)])

    clock.advance(301)
    await relaunched.drain()
    #expect(http.sent == [Self.eventID(1), Self.eventID(1)])
  }

  final class WriteSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool {
      get { lock.withLock { on } }
      set { lock.withLock { on = newValue } }
    }
  }
}
