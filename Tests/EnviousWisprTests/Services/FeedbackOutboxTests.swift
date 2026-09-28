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
    readData: (@Sendable (URL) throws -> Data)? = nil
  ) -> FeedbackOutbox {
    let sender = http.map { http in
      FeedbackSender(dsn: dsn, http: { try http.call($0) }, now: { clock.now })
    }
    return FeedbackOutbox(
      directory: directory, sender: sender, path: path, now: { clock.now },
      sleep: { _ in throw CancellationError() },
      writeData: writeData ?? { data, url in
        try DurableJSONFile.write(data: data, to: url, tempPrefix: ".outbox")
      },
      readData: readData ?? { try Data(contentsOf: $0) })
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

  @Test("The 51st report is refused and nothing is evicted")
  func fullOutbox() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let outbox = Self.makeOutbox(directory, http: nil)
    for n in 1...50 { #expect(await outbox.enqueue(Self.record(n)) == .saved(offline: false)) }

    #expect(await outbox.enqueue(Self.record(51)) == .full)
    #expect(try Self.records(in: directory).count == 50)
  }

  @Test("A file that cannot be read is never replaced by a new report")
  func unreadableFileIsKept() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = Self.makeOutbox(directory, http: nil)
    _ = await first.enqueue(Self.record(1))
    let blocked = Self.makeOutbox(
      directory, http: nil, readData: { _ in throw CocoaError(.fileReadNoPermission) })

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

    let relaunched = Self.makeOutbox(directory, http: http, clock: clock)
    await relaunched.drain()
    #expect(http.sent.count == 1)

    clock.advance(61)
    await relaunched.drain()
    #expect(http.sent == [Self.eventID(1), Self.eventID(1)])
    #expect(try Self.records(in: directory).isEmpty)
  }

  @Test("A rate limit on a 200 holds every report until it expires, across a relaunch")
  func rateLimitHoldsAll() async throws {
    let directory = Self.tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Clock(Self.start)
    let http = HTTP([.status(200, ["X-Sentry-Rate-Limits": "600:feedback:organization"])])
    let outbox = Self.makeOutbox(directory, http: http, clock: clock)
    _ = await outbox.enqueue(Self.record(1))
    _ = await outbox.enqueue(Self.record(2))
    await outbox.drain()
    #expect(http.sent == [Self.eventID(1)])
    #expect(try Self.records(in: directory).count == 2)

    clock.advance(300)
    let relaunched = Self.makeOutbox(directory, http: http, clock: clock)
    await relaunched.drain()
    #expect(http.sent.count == 1)

    clock.advance(301)
    await relaunched.drain()
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
    #expect(await outbox.hasRejectedReports() == true)

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
    let path = FakePath(satisfied: false)
    let outbox = Self.makeOutbox(directory, http: http, path: path)
    await outbox.start()
    _ = await outbox.enqueue(Self.record(1))
    path.set(true)
    path.set(false)
    await outbox.drain()
    #expect(try Self.records(in: directory).count <= 1)

    path.set(true)
    await outbox.drain()
    #expect(try Self.records(in: directory).isEmpty)
    #expect(http.sent.contains(Self.eventID(1)))
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

  final class WriteSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool {
      get { lock.withLock { on } }
      set { lock.withLock { on = newValue } }
    }
  }
}
