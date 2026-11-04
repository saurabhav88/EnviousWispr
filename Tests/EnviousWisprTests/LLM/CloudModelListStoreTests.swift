import EnviousWisprAppKitTestSupport
import Foundation
import Testing
import os

@testable import EnviousWisprLLM

/// #4353 D6 (plan §11 U20): which cloud model list the app uses, how it is fetched and kept.
///
/// When this fails the user gets an older list than the one we published, loses the list when
/// offline, or has a good saved list replaced by a broken answer from the network.
@Suite("Cloud model list store and client (#4353)", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct CloudModelListStoreTests {

  // MARK: - Fixtures

  /// A valid document. Different `ids` on the same `updated` give a different revision.
  static func document(updated: String, ids: [String] = ["claude-row-a"]) -> Data {
    let rows = ids.map {
      #"{"provider":"claude","id":"\#($0)","recommended":false,"hidden":false,"request":{"claudeShape":"thinkingDisabled"},"supportsChatCompletions":false,"allowsFileBatch":true}"#
    }.joined(separator: ",")
    return Data(#"{"schema":1,"updated":"\#(updated)","models":[\#(rows)]}"#.utf8)
  }

  static func list(_ data: Data) throws -> CloudModelList {
    try CloudModelList.validated(from: data).get()
  }

  /// A fresh folder per test; the persisted file is not created until a test writes it.
  struct Folder {
    let url = TestTemporaryDirectory.url.appending(path: "cloud-model-list-\(UUID().uuidString)")
    var file: URL { url.appending(path: CloudModelListStore.persistedFileName) }

    func write(_ data: Data) throws {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try data.write(to: file)
    }

    func read() -> Data? { try? Data(contentsOf: file) }
    func remove() { try? FileManager.default.removeItem(at: url) }
  }

  /// Answers fetches from a queue, counts them, and can hold one open until released.
  final class FakeFetch: Sendable {
    private let answers: OSAllocatedUnfairLock<[Result<CloudModelList, any Error>]>
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    let gate: Gate?

    init(_ answers: [Result<CloudModelList, any Error>], gate: Gate? = nil) {
      self.answers = OSAllocatedUnfairLock(initialState: answers)
      self.gate = gate
    }

    var count: Int { calls.withLock { $0 } }

    func callAsFunction() async throws -> CloudModelList {
      calls.withLock { $0 += 1 }
      if let gate { await gate.enter() }
      let answer = answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
      guard let answer else { throw CloudModelListClient.FetchError.notHTTP }
      return try answer.get()
    }
  }

  /// Signals that a fetch started and holds it until the test releases it. Every wait here is
  /// bounded by the suite's time limit.
  actor Gate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
      entered = true
      enteredWaiters.forEach { $0.resume() }
      enteredWaiters = []
      if released { return }
      await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
      if entered { return }
      await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
      released = true
      releaseWaiters.forEach { $0.resume() }
      releaseWaiters = []
    }
  }

  struct WriteFailed: Error {}

  static let start = Date(timeIntervalSince1970: 1_800_000_000)

  static func store(
    bundled: Data?, folder: Folder, fetch: FakeFetch,
    clock: OSAllocatedUnfairLock<Date> = OSAllocatedUnfairLock(initialState: start),
    write: @escaping CloudModelListStore.Write = CloudModelListStore.atomicWrite,
    onJoinedRefresh: (@Sendable () -> Void)? = nil
  ) -> CloudModelListStore {
    CloudModelListStore(
      bundled: bundled, persistedURL: folder.file, fetch: { try await fetch() },
      now: { clock.withLock { $0 } }, write: write, onJoinedRefresh: onJoinedRefresh)
  }

  // MARK: - Local copies (U20)

  @Test("no saved copy: the bundled list is used")
  func noPersistedUsesBundle() throws {
    let folder = Folder()
    defer { folder.remove() }
    let bundled = Self.document(updated: "2026-11-04")
    let store = Self.store(bundled: bundled, folder: folder, fetch: FakeFetch([]))
    #expect(store.initialSnapshot?.source == .bundled)
    #expect(store.initialSnapshot?.list.documentBytes == bundled)
    #expect(store.localReport == .init(bundled: .valid, persisted: .absent))
  }

  @Test("a newer bundled list beats an older saved one, and a newer saved one beats the bundle")
  func newerUpdatedWins() throws {
    let older = Self.document(updated: "2026-11-01")
    let newer = Self.document(updated: "2026-11-04")

    let a = Folder()
    defer { a.remove() }
    try a.write(older)
    let bundleWins = Self.store(bundled: newer, folder: a, fetch: FakeFetch([]))
    #expect(bundleWins.initialSnapshot?.source == .bundled)
    #expect(bundleWins.initialSnapshot?.list.documentBytes == newer)

    let b = Folder()
    defer { b.remove() }
    try b.write(newer)
    let savedWins = Self.store(bundled: older, folder: b, fetch: FakeFetch([]))
    #expect(savedWins.initialSnapshot?.source == .persisted)
    #expect(savedWins.initialSnapshot?.list.documentBytes == newer)
  }

  @Test("on the same date with different contents the saved copy wins")
  func equalDatePrefersPersisted() throws {
    let folder = Folder()
    defer { folder.remove() }
    let saved = Self.document(updated: "2026-11-04", ids: ["claude-row-a", "claude-row-b"])
    let bundled = Self.document(updated: "2026-11-04")
    try folder.write(saved)
    let store = Self.store(bundled: bundled, folder: folder, fetch: FakeFetch([]))
    #expect(try Self.list(saved).revision != Self.list(bundled).revision)
    #expect(store.initialSnapshot?.source == .persisted)
    #expect(store.initialSnapshot?.list.documentBytes == saved)
  }

  @Test("a corrupt or oversized saved copy falls back to the bundle")
  func badPersistedFallsBack() throws {
    let bundled = Self.document(updated: "2026-11-01")

    let corrupt = Folder()
    defer { corrupt.remove() }
    try corrupt.write(Data("{\"schema\":1,".utf8))
    let a = Self.store(bundled: bundled, folder: corrupt, fetch: FakeFetch([]))
    #expect(a.initialSnapshot?.source == .bundled)
    #expect(a.localReport.persisted == .invalid)

    // Valid JSON at its start, then far past the limit: refused by the bounded read alone.
    let oversized = Folder()
    defer { oversized.remove() }
    var big = Self.document(updated: "2026-12-01")
    big.append(Data(repeating: 0x20, count: 2 * CloudModelList.maxDocumentBytes))
    try oversized.write(big)
    #expect(CloudModelListStore.boundedRead(oversized.file) == .tooLarge)
    let b = Self.store(bundled: bundled, folder: oversized, fetch: FakeFetch([]))
    #expect(b.initialSnapshot?.source == .bundled)
    #expect(b.localReport.persisted == .tooLarge)

    // Exactly at the limit is still read.
    let atLimit = Folder()
    defer { atLimit.remove() }
    var edge = Self.document(updated: "2026-12-01")
    edge.append(Data(repeating: 0x20, count: CloudModelList.maxDocumentBytes - edge.count))
    try atLimit.write(edge)
    #expect(CloudModelListStore.boundedRead(atLimit.file) == .bytes(edge))
  }

  @Test("no valid copy anywhere: no list, so readers keep the compiled rules")
  func nothingValid() {
    let folder = Folder()
    defer { folder.remove() }
    let store = Self.store(bundled: Data("nope".utf8), folder: folder, fetch: FakeFetch([]))
    #expect(store.initialSnapshot == nil)
    #expect(store.localReport == .init(bundled: .invalid, persisted: .absent))
  }

  // MARK: - Fetch, publish, persist

  @Test("a valid fetch is published and saved with the same bytes and revision")
  func validFetchPublishesAndPersists() async throws {
    let folder = Folder()
    defer { folder.remove() }
    try folder.write(Self.document(updated: "2026-11-01"))
    let fetched = try Self.list(Self.document(updated: "2026-11-05", ids: ["claude-row-z"]))
    let store = Self.store(
      bundled: Self.document(updated: "2026-11-01"), folder: folder,
      fetch: FakeFetch([.success(fetched)]))

    let outcome = await store.refreshIfDue()
    #expect(outcome.result == .fetched(.written))
    #expect(outcome.snapshot?.source == .fresh)
    #expect(outcome.snapshot?.list.revision == fetched.revision)
    #expect(outcome.snapshot?.sequence == 2)
    #expect(folder.read() == fetched.documentBytes)
    #expect(await store.current == outcome.snapshot)
  }

  @Test("a fresh valid fetch wins even when older than the bundle or on the same date (plan D6 order)")
  func freshOlderThanBundleStillWins() async throws {
    let folder = Folder()
    defer { folder.remove() }
    let fetched = try Self.list(Self.document(updated: "2026-10-01"))
    let store = Self.store(
      bundled: Self.document(updated: "2026-11-04"), folder: folder,
      fetch: FakeFetch([.success(fetched)]))
    let outcome = await store.refreshIfDue()
    #expect(outcome.snapshot?.source == .fresh)
    #expect(outcome.snapshot?.list.updated == "2026-10-01")

    // Same date, different content: the website's correction replaces the saved copy.
    let sameDay = Folder()
    defer { sameDay.remove() }
    let saved = Self.document(updated: "2026-11-04")
    try sameDay.write(saved)
    let corrected = try Self.list(
      Self.document(updated: "2026-11-04", ids: ["claude-row-a", "claude-row-fix"]))
    let sameDayStore = Self.store(
      bundled: saved, folder: sameDay, fetch: FakeFetch([.success(corrected)]))
    #expect(try Self.list(saved).revision != corrected.revision)
    let replaced = await sameDayStore.refreshIfDue()
    #expect(replaced.result == .fetched(.written))
    #expect(replaced.snapshot?.source == .fresh)
    #expect(replaced.snapshot?.list.revision == corrected.revision)
    #expect(sameDay.read() == corrected.documentBytes)
  }

  @Test("an invalid answer from the website keeps the active list and the saved file")
  func invalidFetchChangesNothing() async throws {
    let folder = Folder()
    defer { folder.remove() }
    let saved = Self.document(updated: "2026-11-03")
    try folder.write(saved)
    let client = CloudModelListClient { request, _ in
      (
        Data(#"{"schema":2,"updated":"2026-11-09","models":[]}"#.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let store = CloudModelListStore(
      bundled: Self.document(updated: "2026-11-01"), persistedURL: folder.file,
      fetch: { try await client.fetch() })
    let before = await store.current

    let outcome = await store.refreshIfDue()
    guard case .failed = outcome.result else {
      Issue.record("expected a failure, got \(outcome.result)")
      return
    }
    #expect(outcome.snapshot == before)
    #expect(before?.source == .persisted)
    #expect(folder.read() == saved)
  }

  @Test("a list that cannot be saved is still used, and the previous file is untouched")
  func writeFailureKeepsPreviousFile() async throws {
    let folder = Folder()
    defer { folder.remove() }
    let saved = Self.document(updated: "2026-11-01")
    try folder.write(saved)
    let fetched = try Self.list(Self.document(updated: "2026-11-05"))
    let store = Self.store(
      bundled: nil, folder: folder, fetch: FakeFetch([.success(fetched)]),
      write: { _, _ in throw WriteFailed() })

    let outcome = await store.refreshIfDue()
    guard case .fetched(.failed) = outcome.result else {
      Issue.record("expected a save failure, got \(outcome.result)")
      return
    }
    #expect(outcome.snapshot?.source == .fresh)
    #expect(outcome.snapshot?.list.revision == fetched.revision)
    #expect(folder.read() == saved)
  }

  @Test("a fetch identical to the saved file is not written again")
  func alreadyCurrentSkipsWrite() async throws {
    let folder = Folder()
    defer { folder.remove() }
    let saved = Self.document(updated: "2026-11-04")
    try folder.write(saved)
    let writes = OSAllocatedUnfairLock(initialState: 0)
    let store = Self.store(
      bundled: nil, folder: folder, fetch: FakeFetch([.success(try Self.list(saved))]),
      write: { _, _ in writes.withLock { $0 += 1 } })
    let outcome = await store.refreshIfDue()
    #expect(outcome.result == .fetched(.alreadyCurrent))
    #expect(writes.withLock { $0 } == 0)
  }

  // MARK: - Concurrency

  @Test("concurrent refreshes share one fetch and get the same answer")
  func concurrentRefreshesShareOneFetch() async throws {
    let folder = Folder()
    defer { folder.remove() }
    let gate = Gate()
    let fetched = try Self.list(Self.document(updated: "2026-11-05"))
    let fetch = FakeFetch([.success(fetched), .success(fetched)], gate: gate)
    let (joined, joinedContinuation) = AsyncStream.makeStream(of: Void.self)
    let store = Self.store(
      bundled: Self.document(updated: "2026-11-01"), folder: folder, fetch: fetch,
      onJoinedRefresh: { joinedContinuation.yield() })

    async let first = store.refreshIfDue()
    await gate.waitUntilEntered()
    async let second = store.refreshIfDue()
    // Release only once the second caller has joined the fetch in flight.
    var joins = joined.makeAsyncIterator()
    _ = await joins.next()
    await gate.release()
    let (a, b) = await (first, second)

    #expect(fetch.count == 1)
    #expect(a == b)
    #expect(a.snapshot?.sequence == 2, "one publication, not two")
  }

  @Test("a snapshot held before a newer publication keeps its whole list")
  func heldSnapshotSurvivesPublication() async throws {
    let folder = Folder()
    defer { folder.remove() }
    let bundled = Self.document(updated: "2026-11-01")
    let fetched = try Self.list(Self.document(updated: "2026-11-05", ids: ["claude-row-z"]))
    let store = Self.store(bundled: bundled, folder: folder, fetch: FakeFetch([.success(fetched)]))
    let held = try #require(await store.current)
    _ = await store.refreshIfDue()
    #expect(held.list.documentBytes == bundled)
    #expect(held.list.models.map(\.id) == ["claude-row-a"])
    #expect(await store.current?.list.revision == fetched.revision)
  }

  // MARK: - Cadence

  @Test("launch fetches; then at most once per 24 hours, counting failures; relaunch fetches")
  func cadence() async throws {
    let folder = Folder()
    defer { folder.remove() }
    let clock = OSAllocatedUnfairLock(initialState: Self.start)
    let good = try Self.list(Self.document(updated: "2026-11-05"))
    let fetch = FakeFetch([
      .failure(CloudModelListClient.FetchError.httpStatus(503)), .success(good), .success(good),
    ])
    let store = Self.store(bundled: nil, folder: folder, fetch: fetch, clock: clock)

    guard case .failed = await store.refreshIfDue().result else {
      Issue.record("the launch fetch should run and fail")
      return
    }
    clock.withLock { $0 = Self.start.addingTimeInterval(60 * 60) }
    #expect(await store.refreshIfDue().result == .notDue, "a failure counts as the attempt")
    clock.withLock { $0 = Self.start.addingTimeInterval(CloudModelListStore.refreshInterval) }
    #expect(await store.refreshIfDue().result == .fetched(.written))
    #expect(fetch.count == 2)

    // A clock moved back before the last attempt makes a fetch due.
    clock.withLock { $0 = Self.start }
    #expect(await store.refreshIfDue().result == .fetched(.alreadyCurrent))
    #expect(fetch.count == 3)

    // Relaunch: a new store fetches at once, and starts from the saved copy.
    let relaunchFetch = FakeFetch([.success(good)])
    let relaunched = Self.store(bundled: nil, folder: folder, fetch: relaunchFetch, clock: clock)
    #expect(relaunched.initialSnapshot?.source == .persisted)
    #expect(await relaunched.refreshIfDue().result == .fetched(.alreadyCurrent))
    #expect(relaunchFetch.count == 1)
  }

  @Test("a cancelled fetch changes nothing")
  func cancelledFetch() async throws {
    let folder = Folder()
    defer { folder.remove() }
    let store = Self.store(
      bundled: Self.document(updated: "2026-11-01"), folder: folder,
      fetch: FakeFetch([.failure(CancellationError())]))
    let before = await store.current
    let outcome = await store.refreshIfDue()
    #expect(outcome.result == .cancelled)
    #expect(outcome.snapshot == before)
    #expect(folder.read() == nil)
  }

  // MARK: - Client

  @Test("the request is a bare GET to the list URL and carries nothing about the user")
  func requestShape() async throws {
    let seen = OSAllocatedUnfairLock<[(URLRequest, Int)]>(initialState: [])
    let body = Self.document(updated: "2026-11-04")
    let client = CloudModelListClient { request, maximumBytes in
      seen.withLock { $0.append((request, maximumBytes)) }
      return (
        body,
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let list = try await client.fetch()
    #expect(list.documentBytes == body)

    let (request, maximumBytes) = try #require(seen.withLock { $0.first })
    #expect(request.url?.absoluteString == "https://enviouswispr.com/cloud-models.json")
    #expect(request.url?.query == nil)
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil && request.httpBodyStream == nil)
    #expect((request.allHTTPHeaderFields ?? [:]).isEmpty)
    #expect(maximumBytes == CloudModelList.maxDocumentBytes)
    #expect(CloudModelListClient.allowedHost == request.url?.host)
  }

  @Test("transport, HTTP and content failures stay failures; cancellation stays cancellation")
  func clientFailures() async {
    func client(_ answer: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse))
      -> CloudModelListClient
    {
      CloudModelListClient { request, _ in try answer(request) }
    }
    @Sendable func http(_ request: URLRequest, _ status: Int) -> URLResponse {
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
    let good = Self.document(updated: "2026-11-04")

    await #expect(throws: CancellationError.self) {
      try await client { _ in throw CancellationError() }.fetch()
    }
    await #expect(throws: CancellationError.self) {
      try await client { _ in throw URLError(.cancelled) }.fetch()
    }
    do {
      _ = try await client { _ in throw URLError(.notConnectedToInternet) }.fetch()
      Issue.record("offline should throw")
    } catch let error as CloudModelListClient.FetchError {
      if case .transport = error {} else { Issue.record("got \(error)") }
    } catch { Issue.record("got \(error)") }
    await #expect(throws: CloudModelListClient.FetchError.httpStatus(500)) {
      try await client { (good, http($0, 500)) }.fetch()
    }
    await #expect(throws: CloudModelListClient.FetchError.notHTTP) {
      try await client {
        (
          good,
          URLResponse(url: $0.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        )
      }.fetch()
    }
    do {
      _ = try await client { (Data("[]".utf8), http($0, 200)) }.fetch()
      Issue.record("an invalid document should throw")
    } catch let error as CloudModelListClient.FetchError {
      if case .invalid = error {} else { Issue.record("got \(error)") }
    } catch { Issue.record("got \(error)") }
  }
}
