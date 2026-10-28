import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4013: when these fail, a call app's broken page or a bad download leaves the app with no
/// talker rules, the app asks enviouswispr.com more than once a day, or a recording's rules
/// change under it after it started.
///
/// Every store here uses its own temporary folder, an injected clock and a fake transport; no test
/// touches the network or the real Application Support folder.
@Suite("Talker rules store", .tags(.productOutcome))
struct TalkerRulesStoreTests {

  private static let start = Date(timeIntervalSince1970: 1_800_000_000)

  private static func document(revision: Int, lagMs: Int = 0) -> Data {
    Data(#"{"schema":1,"revision":\#(revision),"lagMs":{"meet":\#(lagMs)},"selectors":[]}"#.utf8)
  }

  private static func ok(_ body: Data, url: URL = TalkerRulesStore.endpoint, status: Int = 200)
    -> (response: HTTPURLResponse, body: Data)
  {
    (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
  }

  /// A temporary folder, removed when the test ends.
  private final class Folder {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("talker-rules-\(UUID().uuidString)", isDirectory: true)
    var cache: URL { url.appendingPathComponent(TalkerRulesStore.cacheFileName) }
    deinit { try? FileManager.default.removeItem(at: url) }
    func writeCache(_ data: Data) throws {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try data.write(to: cache)
    }
  }

  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
  }

  /// Answers every request with `reply` and counts requests.
  private final class Transport: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: @Sendable () throws -> (response: HTTPURLResponse, body: Data)
    private(set) var requests: [URLRequest] = []
    init(_ reply: @escaping @Sendable () throws -> (response: HTTPURLResponse, body: Data)) {
      self.reply = reply
    }
    var count: Int { lock.withLock { requests.count } }
    func answer(_ reply: @escaping @Sendable () throws -> (response: HTTPURLResponse, body: Data)) {
      lock.withLock { self.reply = reply }
    }
    var send: TalkerRulesStore.Transport {
      { request in
        let reply = self.lock.withLock {
          self.requests.append(request)
          return self.reply
        }
        return try reply()
      }
    }
  }

  private func store(
    _ folder: Folder, bundled: Data? = document(revision: 1), transport: Transport, clock: Clock
  ) -> TalkerRulesStore {
    TalkerRulesStore(
      directory: folder.url, bundledData: { bundled }, transport: transport.send,
      now: { clock.now })
  }

  @Test("with no saved copy the bundled rules are in force, without the network")
  func bundledFirst() async {
    let folder = Folder()
    let transport = Transport { Self.ok(Self.document(revision: 9)) }
    let snapshot = await store(folder, transport: transport, clock: Clock(Self.start)).current()
    #expect(snapshot.origin == .bundled)
    #expect(snapshot.rules.revision == 1)
    #expect(transport.count == 0)
  }

  @Test("the higher revision of the bundle and the saved copy wins")
  func higherRevisionWins() async throws {
    let newer = Folder()
    try newer.writeCache(Self.document(revision: 4))
    let transport = Transport { throw URLError(.notConnectedToInternet) }
    let clock = Clock(Self.start)
    let fromCache = await store(
      newer, bundled: Self.document(revision: 2), transport: transport, clock: clock
    ).current()
    #expect(fromCache.origin == .cached)
    #expect(fromCache.rules.revision == 4)

    let older = Folder()
    try older.writeCache(Self.document(revision: 1))
    let fromBundle = await store(
      older, bundled: Self.document(revision: 2), transport: transport, clock: clock
    ).current()
    #expect(fromBundle.origin == .bundled)
    #expect(fromBundle.rules.revision == 2)
  }

  @Test("a damaged, oversized or newer-schema saved copy falls back to the bundle")
  func badCache() async throws {
    let oversized = Data(
      (#"{"schema":1,"revision":9,"lagMs":{},"selectors":[]}"#
        + String(repeating: " ", count: TalkerRules.maximumBytes)).utf8)
    for bad in [
      Data("{not json".utf8), oversized,
      Data(#"{"schema":2,"revision":9,"lagMs":{},"selectors":[]}"#.utf8),
    ] {
      let folder = Folder()
      try folder.writeCache(bad)
      let snapshot = await store(
        folder, transport: Transport { throw URLError(.timedOut) }, clock: Clock(Self.start)
      ).current()
      #expect(snapshot.origin == .bundled)
      #expect(snapshot.rules.revision == 1)
    }
  }

  @Test("with no valid bundle and no saved copy every surface is unconfigured")
  func emptyFallback() async {
    let snapshot = await store(
      Folder(), bundled: Data("broken".utf8), transport: Transport { throw URLError(.timedOut) },
      clock: Clock(Self.start)
    ).current()
    #expect(snapshot == .empty)
  }

  @Test("a newer download is used, saved, and still used after a relaunch")
  func downloadAndRelaunch() async throws {
    let folder = Folder()
    let clock = Clock(Self.start)
    let transport = Transport { Self.ok(Self.document(revision: 5, lagMs: 90)) }
    let first = store(folder, transport: transport, clock: clock)
    let fresh = await first.refreshIfDue()
    #expect(fresh.origin == .downloaded)
    #expect(fresh.rules.lag(for: .meet) == CallSpeakerLag(milliseconds: 90))
    #expect(await first.current() == fresh)
    #expect(try Data(contentsOf: folder.cache) == Self.document(revision: 5, lagMs: 90))

    let request = try #require(transport.requests.first)
    #expect(request.url == TalkerRulesStore.endpoint)
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.httpShouldHandleCookies == false)
    #expect(request.timeoutInterval == 5)

    let relaunched = await store(folder, transport: transport, clock: clock).current()
    #expect(relaunched.origin == .cached)
    #expect(relaunched.rules == fresh.rules)
  }

  @Test("at most one download a day, also across a relaunch; a day later it asks again")
  func dailyLimit() async {
    let folder = Folder()
    let clock = Clock(Self.start)
    let transport = Transport { Self.ok(Self.document(revision: 1)) }
    let first = store(folder, transport: transport, clock: clock)
    _ = await first.refreshIfDue()
    _ = await first.refreshIfDue()
    #expect(transport.count == 1)

    clock.advance(TalkerRulesStore.refreshInterval - 1)
    _ = await store(folder, transport: transport, clock: clock).refreshIfDue()
    #expect(transport.count == 1)

    clock.advance(1)
    _ = await store(folder, transport: transport, clock: clock).refreshIfDue()
    #expect(transport.count == 2)
  }

  @Test("a clock set back before the last attempt does not block refreshes")
  func clockSetBack() async {
    let folder = Folder()
    let clock = Clock(Self.start)
    let transport = Transport { Self.ok(Self.document(revision: 1)) }
    _ = await store(folder, transport: transport, clock: clock).refreshIfDue()
    clock.advance(-60)
    _ = await store(folder, transport: transport, clock: clock).refreshIfDue()
    #expect(transport.count == 2)
  }

  @Test(
    "every failed download keeps the rules in force and the saved copy, and waits a day",
    arguments: [
      "offline", "timeout", "cancelled", "http 500", "http 304", "another host", "another path",
      "invalid", "oversized", "older revision", "same revision",
    ])
  func failedDownloads(_ failure: String) async throws {
    let folder = Folder()
    let saved = Self.document(revision: 3)
    try folder.writeCache(saved)
    let clock = Clock(Self.start)
    let transport = Transport {
      switch failure {
      case "offline": throw URLError(.notConnectedToInternet)
      case "timeout": throw URLError(.timedOut)
      case "cancelled": throw CancellationError()
      case "http 500": return Self.ok(Self.document(revision: 8), status: 500)
      case "http 304": return Self.ok(Self.document(revision: 8), status: 304)
      case "another host":
        return Self.ok(
          Self.document(revision: 8),
          url: URL(string: "https://example.com/meet/talker-rules.json")!)
      case "another path":
        return Self.ok(
          Self.document(revision: 8), url: URL(string: "https://enviouswispr.com/other.json")!)
      case "invalid": return Self.ok(Data(#"{"schema":1}"#.utf8))
      case "oversized": return Self.ok(Data(repeating: 0x20, count: TalkerRules.maximumBytes + 1))
      case "older revision": return Self.ok(Self.document(revision: 2))
      default: return Self.ok(Self.document(revision: 3, lagMs: 50))
      }
    }
    let subject = store(folder, transport: transport, clock: clock)
    let before = await subject.current()
    let after = await subject.refreshIfDue()
    #expect(after == before)
    #expect(after.origin == .cached)
    #expect(try Data(contentsOf: folder.cache) == saved)
    _ = await subject.refreshIfDue()
    #expect(transport.count == 1)
  }

  @Test("a snapshot already handed out never changes when newer rules arrive")
  func snapshotsAreFrozen() async {
    let folder = Folder()
    let clock = Clock(Self.start)
    let transport = Transport { Self.ok(Self.document(revision: 2, lagMs: 40)) }
    let subject = store(folder, transport: transport, clock: clock)
    let atRecordingStart = await subject.current()
    let frozenText = atRecordingStart.frozen.payload
    _ = await subject.refreshIfDue()
    #expect(atRecordingStart.rules.revision == 1)
    #expect(atRecordingStart.frozen.payload == frozenText)
    #expect(await subject.current().rules.revision == 2)
  }

  @Test("callers that ask while a download is running share it")
  func concurrentCallersShareOneDownload() async throws {
    let gate = Gate()
    let (joins, joined) = AsyncStream<Void>.makeStream()
    let clock = Clock(Self.start)
    let folder = Folder()
    let subject = TalkerRulesStore(
      directory: folder.url, bundledData: { Self.document(revision: 1) },
      transport: { _ in try await gate.park() }, now: { clock.now },
      onJoinedRefresh: { joined.yield() })

    let first = Task { await subject.refreshIfDue() }
    #expect(await gate.arrived(within: .seconds(5)))
    let second = Task { await subject.refreshIfDue() }
    let third = Task { await subject.refreshIfDue() }
    #expect(await Self.signals(2, from: joins, within: .seconds(5)))
    gate.release(Self.ok(Self.document(revision: 6)))

    for task in [first, second, third] {
      #expect(await task.value.rules.revision == 6)
    }
    #expect(gate.parkCount == 1)
  }

  @Test("the signal wait gives up when nothing is sent")
  func signalWaitDeadline() async {
    let (stream, _) = AsyncStream<Void>.makeStream()
    #expect(await Self.signals(1, from: stream, within: .milliseconds(50)) == false)
  }

  // MARK: - Signals

  /// True when `count` signals arrive before the deadline.
  private static func signals(_ count: Int, from stream: AsyncStream<Void>, within limit: Duration)
    async -> Bool
  {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        var seen = 0
        for await _ in stream {
          seen += 1
          if seen == count { return true }
        }
        return false
      }
      group.addTask {
        try? await Task.sleep(for: limit)  // deadline-fallback: bounds the signal wait above
        return false
      }
      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
  }

  /// A transport that parks the first request until the test releases it. Arrival is published
  /// in the same locked step that parks the continuation, so a release never meets an empty gate.
  private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: CheckedContinuation<(response: HTTPURLResponse, body: Data), Error>?
    private var parks = 0
    private let (arrivals, arrival) = AsyncStream<Void>.makeStream()

    var parkCount: Int { lock.withLock { parks } }

    func park() async throws -> (response: HTTPURLResponse, body: Data) {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock {
          parks += 1
          parked = continuation
          arrival.yield()
        }
      }
    }

    func arrived(within limit: Duration) async -> Bool {
      await TalkerRulesStoreTests.signals(1, from: arrivals, within: limit)
    }

    func release(_ reply: (response: HTTPURLResponse, body: Data)) {
      let continuation = lock.withLock {
        defer { parked = nil }
        return parked
      }
      continuation?.resume(returning: reply)
    }
  }
}
