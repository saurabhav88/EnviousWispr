import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprServices

/// #4013 (generic since reading resilience §3.5): when these fail, a call app's broken page or a bad download leaves the app with no
/// talker rules, the app asks enviouswispr.com more than once a day, or a recording's rules
/// change under it after it started.
///
/// Every store here uses its own temporary folder, an injected clock and a fake transport; no test
/// touches the network or the real Application Support folder.
@Suite("Rules store", .tags(.productOutcome))
struct RemoteRulesStoreTests {

  private static let start = Date(timeIntervalSince1970: 1_800_000_000)

  private static func document(revision: Int, lagMs: Int = 0) -> Data {
    Data(#"{"schema":1,"revision":\#(revision),"lagMs":{"meet":\#(lagMs)},"selectors":[]}"#.utf8)
  }

  private static func ok(_ body: Data, url: URL = TalkerRulesSnapshot.endpoint, status: Int = 200)
    -> (response: HTTPURLResponse, body: Data)
  {
    (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
  }

  /// A temporary folder, removed when the test ends.
  private final class Folder {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("talker-rules-\(UUID().uuidString)", isDirectory: true)
    var cache: URL { url.appendingPathComponent(TalkerRulesSnapshot.cacheFileName) }
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
    var send: RemoteRules.Transport {
      { request, _ in
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
  ) -> RemoteRulesStore<TalkerRulesSnapshot> {
    RemoteRulesStore(
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
    #expect(request.url == TalkerRulesSnapshot.endpoint)
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

    clock.advance(RemoteRules.refreshInterval - 1)
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

  @Test("a lag at the smallest 64-bit integer is refused in a saved copy and in a download")
  func extremeLagIsRefused() async throws {
    let extreme = Data(
      #"{"schema":1,"revision":9,"lagMs":{"meet":-9223372036854775808},"selectors":[]}"#.utf8)
    let folder = Folder()
    try folder.writeCache(extreme)
    let transport = Transport { Self.ok(extreme) }
    let subject = store(folder, transport: transport, clock: Clock(Self.start))
    let before = await subject.current()
    #expect(before.origin == .bundled)
    #expect(before.rules.revision == 1)
    #expect(await subject.refreshIfDue() == before)
    #expect(transport.count == 1)
  }

  @Test("when the saved copy cannot be replaced, the download is still used and the old copy stays")
  func cacheWriteFailure() async throws {
    let folder = Folder()
    let saved = Self.document(revision: 3)
    try folder.writeCache(saved)
    // A read-only folder refuses the atomic replacement (and the attempt record).
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.url.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: folder.url.path)
    }
    let subject = store(
      folder, transport: Transport { Self.ok(Self.document(revision: 8, lagMs: 30)) },
      clock: Clock(Self.start))
    let fresh = await subject.refreshIfDue()
    #expect(fresh.origin == .downloaded)
    #expect(fresh.rules.revision == 8)
    #expect(await subject.current() == fresh)
    #expect(try Data(contentsOf: folder.cache) == saved)
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
    #expect(names == [TalkerRulesSnapshot.cacheFileName])
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
    let subject = RemoteRulesStore<TalkerRulesSnapshot>(
      directory: folder.url, bundledData: { Self.document(revision: 1) },
      transport: { _, _ in try await gate.park() }, now: { clock.now },
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

  // MARK: - One store per document

  /// A second document with a small cap and its own files, to prove the store keeps documents
  /// apart and asks each one's limits.
  struct ProbeRules: RemoteRulesDocument {
    static let endpoint = URL(string: "https://enviouswispr.com/meet/probe-rules.json")!
    static let cacheFileName = "probe-rules.json"
    static let attemptFileName = "probe-rules-attempt.json"
    static let maximumBytes = 64
    static let bundledURL: URL? = nil
    static let empty = ProbeRules(revision: 0, origin: .empty)

    let revision: Int
    let origin: RemoteRulesOrigin

    private init(revision: Int, origin: RemoteRulesOrigin) {
      self.revision = revision
      self.origin = origin
    }

    init(validating data: Data, origin: RemoteRulesOrigin) throws {
      guard let text = String(data: data, encoding: .utf8), text.hasPrefix("probe "),
        let revision = Int(text.dropFirst(6).trimmingCharacters(in: .whitespaces)), revision > 0
      else { throw URLError(.cannotParseResponse) }
      self.init(revision: revision, origin: origin)
    }
  }

  private static func probe(_ revision: Int, padding: Int = 0) -> Data {
    Data(("probe \(revision)" + String(repeating: " ", count: padding)).utf8)
  }

  @Test("two documents in one folder keep their own files, daily limits and size caps")
  func documentsStayApart() async throws {
    let folder = Folder()
    let clock = Clock(Self.start)
    let caps = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])
    let transport: RemoteRules.Transport = { request, maximumBytes in
      let path = request.url?.lastPathComponent ?? ""
      caps.withLock { $0[path] = maximumBytes }
      let body = path == "probe-rules.json" ? Self.probe(4) : Self.document(revision: 5)
      return Self.ok(body, url: request.url!)
    }
    let talker = RemoteRulesStore<TalkerRulesSnapshot>(
      directory: folder.url, bundledData: { Self.document(revision: 1) }, transport: transport,
      now: { clock.now })
    let probe = RemoteRulesStore<ProbeRules>(
      directory: folder.url, bundledData: { nil }, transport: transport, now: { clock.now })
    #expect(await probe.current() == ProbeRules.empty)
    #expect(await talker.refreshIfDue().rules.revision == 5)
    // The talker download's attempt does not use up the probe's day.
    let fresh = await probe.refreshIfDue()
    #expect(fresh.revision == 4)
    #expect(fresh.origin == .downloaded)
    #expect(
      caps.withLock { $0 }
        == ["talker-rules.json": TalkerRules.maximumBytes, "probe-rules.json": 64])
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.url.path))
    #expect(
      names == [
        "talker-rules.json", "talker-rules-attempt.json", "probe-rules.json",
        "probe-rules-attempt.json",
      ])
    #expect(try Data(contentsOf: folder.url.appendingPathComponent("probe-rules.json")) == Self.probe(4))
    // A relaunch reads each document's own cache.
    let relaunched = RemoteRulesStore<ProbeRules>(
      directory: folder.url, bundledData: { nil }, transport: transport, now: { clock.now })
    #expect(await relaunched.current().origin == .cached)
    #expect(await relaunched.current().revision == 4)
  }

  @Test("a document's own cap refuses an oversized download and an oversized saved copy")
  func documentCapApplies() async throws {
    // Valid apart from its size: only the store's cap can refuse it.
    let oversized = Self.probe(9, padding: 64)
    #expect(oversized.count > ProbeRules.maximumBytes)
    #expect(try ProbeRules(validating: oversized, origin: .downloaded).revision == 9)
    let clock = Date(timeIntervalSince1970: 1_800_000_000)

    let folder = Folder()
    try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
    try oversized.write(to: folder.url.appendingPathComponent(ProbeRules.cacheFileName))
    let subject = RemoteRulesStore<ProbeRules>(
      directory: folder.url, bundledData: { Self.probe(1) },
      transport: { request, _ in Self.ok(oversized, url: request.url!) }, now: { clock })
    let before = await subject.current()
    #expect(before.origin == .bundled, "the oversized saved copy is refused")
    #expect(before.revision == 1)
    #expect(await subject.refreshIfDue() == before, "the oversized download is refused")

    // Control through the store: the same revision within the cap is cached and downloaded.
    let fitting = Self.probe(9, padding: 64 - Self.probe(9).count)
    #expect(fitting.count == ProbeRules.maximumBytes)
    let accepting = Folder()
    try FileManager.default.createDirectory(at: accepting.url, withIntermediateDirectories: true)
    try fitting.write(to: accepting.url.appendingPathComponent(ProbeRules.cacheFileName))
    let cached = RemoteRulesStore<ProbeRules>(
      directory: accepting.url, bundledData: { Self.probe(1) },
      transport: { request, _ in Self.ok(Self.probe(12), url: request.url!) }, now: { clock })
    #expect(await cached.current().origin == .cached)
    #expect(await cached.current().revision == 9)
    let downloaded = await cached.refreshIfDue()
    #expect(downloaded.origin == .downloaded)
    #expect(downloaded.revision == 12)
    let empty = Folder()
    let fresh = RemoteRulesStore<ProbeRules>(
      directory: empty.url, bundledData: { Self.probe(1) },
      transport: { request, _ in Self.ok(fitting, url: request.url!) }, now: { clock })
    #expect(await fresh.refreshIfDue().revision == 9)
  }

  // MARK: - The self-mute rules document (#4013 reading resilience §3.5)

  private static func muteDocument(revision: Int, schema: Int = 1, role: String = "AXButton")
    -> Data
  {
    Data(
      #"{"schema":\#(schema),"revision":\#(revision),"surfaces":{"meet":{"role":"\#(role)","labels":{"Turn on microphone":"muted","Turn off microphone":"unmuted"}}}}"#
        .utf8)
  }

  private func muteStore(
    _ folder: Folder, bundled: Data? = muteDocument(revision: 1), transport: Transport,
    clock: Clock
  ) -> RemoteRulesStore<CallMuteRules> {
    RemoteRulesStore(
      directory: folder.url, bundledData: { bundled }, transport: transport.send,
      now: { clock.now })
  }

  @Test("mute rules: bundled first, a higher saved revision wins, a tie keeps the bundle")
  func muteBundledAndCache() async throws {
    let none = Transport { throw URLError(.timedOut) }
    let clock = Clock(Self.start)
    let fresh = await muteStore(Folder(), transport: none, clock: clock).current()
    #expect(fresh.origin == .bundled)
    #expect(fresh.revision == 1)
    for (saved, origin, revision) in [(3, RemoteRulesOrigin.cached, 3), (1, .bundled, 1)] {
      let folder = Folder()
      try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
      try Self.muteDocument(revision: saved, role: "AXCheckBox").write(
        to: folder.url.appendingPathComponent(CallMuteRules.cacheFileName))
      let current = await muteStore(folder, transport: none, clock: clock).current()
      #expect(current.origin == origin)
      #expect(current.revision == revision)
    }
  }

  @Test("mute rules: a saved copy of another schema falls back; no valid copy follows nothing")
  func muteFallbacks() async throws {
    let none = Transport { throw URLError(.timedOut) }
    let clock = Clock(Self.start)
    let folder = Folder()
    try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
    try Self.muteDocument(revision: 9, schema: 2).write(
      to: folder.url.appendingPathComponent(CallMuteRules.cacheFileName))
    #expect(await muteStore(folder, transport: none, clock: clock).current().revision == 1)
    let empty = await muteStore(
      Folder(), bundled: Data("broken".utf8), transport: none, clock: clock
    ).current()
    #expect(empty == .empty)
    #expect(empty.rules.isEmpty)
  }

  @Test("mute rules: a higher download is used, saved and its roles reach protection")
  func muteDownload() async throws {
    let folder = Folder()
    let clock = Clock(Self.start)
    let transport = Transport {
      Self.ok(Self.muteDocument(revision: 4, role: "AXCheckBox"), url: CallMuteRules.endpoint)
    }
    let subject = muteStore(folder, transport: transport, clock: clock)
    let atStart = await subject.current()
    let fresh = await subject.refreshIfDue()
    #expect(fresh.origin == .downloaded)
    #expect(fresh.protectedRoles == ["AXCheckBox"])
    #expect(atStart.protectedRoles == ["AXButton"], "a value already handed out never changes")
    #expect(transport.requests.first?.url == CallMuteRules.endpoint)
    #expect(
      try Data(contentsOf: folder.url.appendingPathComponent(CallMuteRules.cacheFileName))
        == Self.muteDocument(revision: 4, role: "AXCheckBox"))
    // The talker document's address is refused for the mute document.
    let wrong = Transport { Self.ok(Self.muteDocument(revision: 8)) }
    let other = await muteStore(Folder(), transport: wrong, clock: clock).refreshIfDue()
    #expect(other.revision == 1)
  }

  // MARK: - Shared characterizations for both shipped documents (#4013 reading resilience §11)

  /// The two documents the app downloads. Every behavior the store owns runs for both; the
  /// talker-only parts (lag values, the frozen payload text) stay in the talker tests above.
  enum Kind: String, CaseIterable, Sendable {
    case talker, mute
  }

  /// A valid document of `kind` at `revision`; `variant` changes its content, not its revision.
  private static func body(_ kind: Kind, revision: Int, variant: Bool = false) -> Data {
    switch kind {
    case .talker: document(revision: revision, lagMs: variant ? 50 : 0)
    case .mute: muteDocument(revision: revision, role: variant ? "AXCheckBox" : "AXButton")
    }
  }

  private static func endpoint(_ kind: Kind) -> URL {
    kind == .talker ? TalkerRulesSnapshot.endpoint : CallMuteRules.endpoint
  }

  private static func cacheName(_ kind: Kind) -> String {
    kind == .talker ? TalkerRulesSnapshot.cacheFileName : CallMuteRules.cacheFileName
  }

  private static func maximumBytes(_ kind: Kind) -> Int {
    kind == .talker ? TalkerRulesSnapshot.maximumBytes : CallMuteRules.maximumBytes
  }

  /// A store of `D` over `folder`, bundling revision 1.
  private func generic<D: RemoteRulesDocument>(
    _: D.Type, _ kind: Kind, _ folder: Folder, transport: @escaping RemoteRules.Transport, clock: Clock,
    onJoined: (@Sendable () -> Void)? = nil
  ) -> RemoteRulesStore<D> {
    RemoteRulesStore<D>(
      directory: folder.url, bundledData: { Self.body(kind, revision: 1) }, transport: transport,
      now: { clock.now }, onJoinedRefresh: onJoined)
  }

  @Test("both documents: one download a day across a relaunch, and a newer one is kept", arguments: Kind.allCases)
  func bothDailyLimitAndRelaunch(kind: Kind) async throws {
    switch kind {
    case .talker: try await dailyLimitAndRelaunch(TalkerRulesSnapshot.self, kind)
    case .mute: try await dailyLimitAndRelaunch(CallMuteRules.self, kind)
    }
  }

  private func dailyLimitAndRelaunch<D: RemoteRulesDocument>(_ type: D.Type, _ kind: Kind)
    async throws
  {
    let folder = Folder()
    let clock = Clock(Self.start)
    let transport = Transport { Self.ok(Self.body(kind, revision: 5), url: Self.endpoint(kind)) }
    let first = generic(type, kind, folder, transport: transport.send, clock: clock)
    let fresh = await first.refreshIfDue()
    #expect(fresh.origin == .downloaded)
    #expect(fresh.revision == 5)
    _ = await first.refreshIfDue()
    #expect(transport.count == 1)
    let request = try #require(transport.requests.first)
    #expect(request.url == Self.endpoint(kind))
    #expect(request.httpMethod == "GET" && request.httpBody == nil)
    #expect(request.httpShouldHandleCookies == false && request.timeoutInterval == 5)
    let relaunched = generic(type, kind, folder, transport: transport.send, clock: clock)
    #expect(await relaunched.current().origin == .cached)
    #expect(await relaunched.current().revision == 5)
    clock.advance(RemoteRules.refreshInterval - 1)
    _ = await relaunched.refreshIfDue()
    #expect(transport.count == 1)
    clock.advance(1)
    _ = await generic(type, kind, folder, transport: transport.send, clock: clock).refreshIfDue()
    #expect(transport.count == 2)
  }

  @Test("both documents: a clock set back does not block refreshes", arguments: Kind.allCases)
  func bothClockSetBack(kind: Kind) async throws {
    switch kind {
    case .talker: try await bothClockSetBack(TalkerRulesSnapshot.self, kind)
    case .mute: try await bothClockSetBack(CallMuteRules.self, kind)
    }
  }

  private func bothClockSetBack<D: RemoteRulesDocument>(_ type: D.Type, _ kind: Kind)
    async throws
  {
    let folder = Folder()
    let clock = Clock(Self.start)
    let transport = Transport { Self.ok(Self.body(kind, revision: 1), url: Self.endpoint(kind)) }
    _ = await generic(type, kind, folder, transport: transport.send, clock: clock).refreshIfDue()
    clock.advance(-60)
    _ = await generic(type, kind, folder, transport: transport.send, clock: clock).refreshIfDue()
    #expect(transport.count == 2)
  }

  @Test(
    "both documents: every failed download keeps the rules and the saved copy, and waits a day",
    arguments: Kind.allCases, [
      "offline", "timeout", "cancelled", "http 500", "http 304", "another host", "another path",
      "invalid", "oversized", "older revision", "same revision",
    ])
  func bothFailedDownloads(kind: Kind, failure: String) async throws {
    switch kind {
    case .talker: try await bothFailedDownloads(TalkerRulesSnapshot.self, kind, failure: failure)
    case .mute: try await bothFailedDownloads(CallMuteRules.self, kind, failure: failure)
    }
  }

  private func bothFailedDownloads<D: RemoteRulesDocument>(_ type: D.Type, _ kind: Kind, failure: String)
    async throws
  {
    let folder = Folder()
    let saved = Self.body(kind, revision: 3)
    try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
    try saved.write(to: folder.url.appendingPathComponent(Self.cacheName(kind)))
    let endpoint = Self.endpoint(kind)
    let transport = Transport {
      switch failure {
      case "offline": throw URLError(.notConnectedToInternet)
      case "timeout": throw URLError(.timedOut)
      case "cancelled": throw CancellationError()
      case "http 500": return Self.ok(Self.body(kind, revision: 8), url: endpoint, status: 500)
      case "http 304": return Self.ok(Self.body(kind, revision: 8), url: endpoint, status: 304)
      case "another host":
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.host = "example.com"
        return Self.ok(Self.body(kind, revision: 8), url: parts.url!)
      case "another path":
        return Self.ok(
          Self.body(kind, revision: 8), url: URL(string: "https://enviouswispr.com/other.json")!)
      case "invalid": return Self.ok(Data(#"{"schema":1}"#.utf8), url: endpoint)
      case "oversized":
        return Self.ok(Data(repeating: 0x20, count: Self.maximumBytes(kind) + 1), url: endpoint)
      case "older revision": return Self.ok(Self.body(kind, revision: 2), url: endpoint)
      default: return Self.ok(Self.body(kind, revision: 3, variant: true), url: endpoint)
      }
    }
    let subject = generic(type, kind, folder, transport: transport.send, clock: Clock(Self.start))
    let before = await subject.current()
    let after = await subject.refreshIfDue()
    #expect(after == before)
    #expect(after.origin == .cached)
    #expect(
      try Data(contentsOf: folder.url.appendingPathComponent(Self.cacheName(kind))) == saved)
    _ = await subject.refreshIfDue()
    #expect(transport.count == 1)
  }

  @Test("both documents: a cache that cannot be replaced keeps the old copy", arguments: Kind.allCases)
  func bothCacheWriteFailure(kind: Kind) async throws {
    switch kind {
    case .talker: try await bothCacheWriteFailure(TalkerRulesSnapshot.self, kind)
    case .mute: try await bothCacheWriteFailure(CallMuteRules.self, kind)
    }
  }

  private func bothCacheWriteFailure<D: RemoteRulesDocument>(_ type: D.Type, _ kind: Kind)
    async throws
  {
    let folder = Folder()
    let saved = Self.body(kind, revision: 3)
    try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
    try saved.write(to: folder.url.appendingPathComponent(Self.cacheName(kind)))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: folder.url.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: folder.url.path)
    }
    let transport = Transport {
      Self.ok(Self.body(kind, revision: 8, variant: true), url: Self.endpoint(kind))
    }
    let subject = generic(type, kind, folder, transport: transport.send, clock: Clock(Self.start))
    let fresh = await subject.refreshIfDue()
    #expect(fresh.origin == .downloaded)
    #expect(fresh.revision == 8)
    #expect(await subject.current() == fresh)
    #expect(
      try Data(contentsOf: folder.url.appendingPathComponent(Self.cacheName(kind))) == saved)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == [
        Self.cacheName(kind)
      ])
  }

  @Test("both documents: a value handed out never changes when a newer one arrives", arguments: Kind.allCases)
  func bothSnapshotsAreFrozen(kind: Kind) async throws {
    switch kind {
    case .talker: try await bothSnapshotsAreFrozen(TalkerRulesSnapshot.self, kind)
    case .mute: try await bothSnapshotsAreFrozen(CallMuteRules.self, kind)
    }
  }

  private func bothSnapshotsAreFrozen<D: RemoteRulesDocument>(_ type: D.Type, _ kind: Kind)
    async throws
  {
    let transport = Transport {
      Self.ok(Self.body(kind, revision: 2, variant: true), url: Self.endpoint(kind))
    }
    let subject = generic(
      type, kind, Folder(), transport: transport.send, clock: Clock(Self.start))
    let atRecordingStart = await subject.current()
    let copy = atRecordingStart
    _ = await subject.refreshIfDue()
    #expect(atRecordingStart == copy)
    #expect(atRecordingStart.revision == 1)
    #expect(await subject.current().revision == 2)
  }

  @Test("both documents: callers during a download share it", arguments: Kind.allCases)
  func bothConcurrentCallersShareOneDownload(kind: Kind) async throws {
    switch kind {
    case .talker: try await bothConcurrentCallersShareOneDownload(TalkerRulesSnapshot.self, kind)
    case .mute: try await bothConcurrentCallersShareOneDownload(CallMuteRules.self, kind)
    }
  }

  private func bothConcurrentCallersShareOneDownload<D: RemoteRulesDocument>(_ type: D.Type, _ kind: Kind)
    async throws
  {
    let gate = Gate()
    let (joins, joined) = AsyncStream<Void>.makeStream()
    let subject = generic(
      type, kind, Folder(), transport: { _, _ in try await gate.park() },
      clock: Clock(Self.start), onJoined: { joined.yield() })
    let first = Task { await subject.refreshIfDue().revision }
    #expect(await gate.arrived(within: .seconds(5)))
    let second = Task { await subject.refreshIfDue().revision }
    let third = Task { await subject.refreshIfDue().revision }
    #expect(await Self.signals(2, from: joins, within: .seconds(5)))
    gate.release(Self.ok(Self.body(kind, revision: 6), url: Self.endpoint(kind)))
    for task in [first, second, third] {
      #expect(await task.value == 6)
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
      await RemoteRulesStoreTests.signals(1, from: arrivals, within: limit)
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
