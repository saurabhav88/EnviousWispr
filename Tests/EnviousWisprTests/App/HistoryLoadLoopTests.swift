import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// #4598: History spun, loaded and blanked in a loop for minutes after launch because every
/// file-system notice withdrew the list, re-created the folder watcher on the main thread and
/// re-walked every source. These tests guard the founder-visible loop and the safety rules the
/// fix must keep (a changed or deleted recording is never shown as current).
@MainActor
@Suite("History keeps its list while it re-checks outside changes", .tags(.productOutcome))
struct HistoryLoadLoopTests {
  private struct Fixture {
    let root: URL
    let changes: HistorySourceChanges
    let store: TranscriptStore
    let session: HistoryCatalogSession
    let coordinator: TranscriptCoordinator
    var transcripts: URL { root.appendingPathComponent("transcripts") }
  }

  private func fixture(rows: Int) async throws -> Fixture {
    let root = TestTemporaryDirectory.url.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    let changes = HistorySourceChanges()
    let store = TranscriptStore(
      directory: root.appendingPathComponent("transcripts"), historyChanges: changes)
    let meetings = MeetingStore(
      root: root.appendingPathComponent("Meetings"), historyChanges: changes)
    let base = Date(timeIntervalSinceReferenceDate: 750_000_000)
    for index in 0..<rows {
      try store.save(
        Transcript(
          text: "row \(index)", processingTime: 0, backendType: .parakeet,
          createdAt: base.addingTimeInterval(Double(index))))
    }
    let session = HistoryCatalogSession(
      changes: changes, sources: store.historyCatalogSources(meetings: meetings),
      directory: root.appendingPathComponent("catalog"))
    let coordinator = TranscriptCoordinator(store: store)
    coordinator.catalogSession = session
    coordinator.startHistoryCatalog()
    await session.waitForIndexingForTesting()
    return Fixture(
      root: root, changes: changes, store: store, session: session, coordinator: coordinator)
  }

  @Test("A burst of outside notices keeps the shown page and the one folder watcher")
  func burstKeepsList() async throws {
    let f = try await fixture(rows: 40)
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(f.session.watcherRegistrations == 1)
    #expect(f.session.watcherIsInstalledForTesting)
    #expect(f.session.status == .ready)
    let key = f.coordinator.historyQueryKey(
      for: .dictations, state: f.coordinator.requestedHistoryState(for: .dictations))
    let shown = try #require(await f.coordinator.historyResults(for: key))
    #expect(shown.items.count == 30)

    // Another process rewrites one shown dictation, then a storm of notices arrives.
    guard case .catalog(let edited) = try #require(shown.items.first) else {
      Issue.record("The catalog page did not return catalog rows")
      return
    }
    let file = f.transcripts.appendingPathComponent("\(edited.key.id.uuidString).json")
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\n".utf8))
    try handle.close()
    for _ in 0..<50 { f.changes.externalChange(.transcript(UUID())) }
    for _ in 0..<10 { f.changes.externalChange() }

    // Before any newer page arrives, the screen keeps every unaffected row and hides only the
    // row whose file changed; the kept page cannot page or authorize selection.
    let kept = try #require(await f.coordinator.retainedHistoryResult(shown))
    #expect(kept.items.count == 29)
    #expect(!kept.ids.contains(.transcript(edited.key.id)))
    #expect(kept.continuation == nil && kept.catalogDayCounts == nil)
    #expect(!f.coordinator.isCurrentHistoryResult(kept))

    // During an in-process write the source revision is unknown; a second shown row changed
    // in that interval is still hidden on the next render (Codex code review r1).
    f.changes.begin()
    _ = try #require(await f.coordinator.retainedHistoryResult(shown))
    guard case .catalog(let second) = shown.items[1] else {
      Issue.record("The catalog page did not return catalog rows")
      return
    }
    let secondFile = f.transcripts.appendingPathComponent("\(second.key.id.uuidString).json")
    let secondHandle = try FileHandle(forWritingTo: secondFile)
    try secondHandle.seekToEnd()
    try secondHandle.write(contentsOf: Data("\n".utf8))
    try secondHandle.close()
    let keptAgain = try #require(await f.coordinator.retainedHistoryResult(shown))
    #expect(keptAgain.items.count == 28)
    #expect(!keptAgain.ids.contains(.transcript(second.key.id)))
    f.changes.finish(.transcript(second.key.id))

    await f.session.waitForIndexingForTesting()
    #expect(f.session.watcherRegistrations == 1)
    #expect(f.session.status == .ready)
    let fresh = try #require(
      await f.coordinator.historyResults(
        for: f.coordinator.historyQueryKey(
          for: .dictations, state: f.coordinator.requestedHistoryState(for: .dictations))))
    #expect(fresh.items.count == 30)
  }

  /// What the History list stores for one tab, as the diary's `results[tab]` does, with a signal
  /// for every store so the test waits on the subject, never on time.
  @MainActor
  private final class Shown {
    var result: HistoryQueryResult?
    var checks = 0
    /// Every result the retained verification itself stored (not a replacement read's page).
    var verifierStores: [HistoryQueryResult] = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func store(_ next: HistoryQueryResult) {
      result = next
      let ready = waiters
      waiters.removeAll()
      for waiter in ready.values { waiter.resume() }
    }

    /// Returns once a stored page satisfies `done`; throws when the test is cancelled (its time
    /// limit), so a failure ends instead of waiting forever.
    func until(_ done: (HistoryQueryResult) -> Bool) async throws {
      while result.map(done) != true {
        try Task.checkCancellation()
        let id = UUID()
        await withTaskCancellationHandler {
          await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            if Task.isCancelled { waiter.resume() } else { waiters[id] = waiter }
          }
        } onCancel: {
          Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume() }
        }
      }
    }
  }

  /// Holds the loop's reads while closed; every wait ends on release or cancellation.
  @MainActor
  private final class ReadGate {
    var closed = false
    private(set) var holding = false
    private var parked: CheckedContinuation<Void, Never>?

    func pass() async {
      guard closed else { return }
      holding = true
      await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          if Task.isCancelled || !closed { continuation.resume() } else { parked = continuation }
        }
      } onCancel: {
        Task { @MainActor in self.open() }
      }
    }

    func open() {
      closed = false
      parked?.resume()
      parked = nil
    }
  }

  /// The loop task and the flag it sets when `run()` returns, so a test never joins the task.
  @MainActor
  private final class RunningLoop {
    var ended = false
    var task: Task<Void, Never>!

    func untilEnded() async throws {
      task.cancel()
      while !ended {
        try Task.checkCancellation()
        await Task.yield()
      }
    }
  }

  private func startLoop(_ f: Fixture, _ shown: Shown, gate: ReadGate? = nil) -> RunningLoop {
    let coordinator = f.coordinator
    let session = f.session
    let key: @MainActor @Sendable () -> TranscriptCoordinator.HistoryQueryKey = { coordinator.historyQueryKey(for: .dictations, state: coordinator.requestedHistoryState(for: .dictations)) }
    let verification = HistoryRetainedVerification(
      stamp: {
        guard let saved = shown.result, saved.catalogSourceRevision != session.stableSourceRevision else { return nil }
        return .init(
          key: key(), notices: session.noticeCount, source: session.stableSourceRevision, grouping: 0,
          stored: saved.identity)
      },
      stored: { shown.result },
      verify: { saved in
        shown.checks += 1
        return await coordinator.retainedHistoryResult(saved)
      },
      store: {
        shown.verifierStores.append($0)
        shown.store($0)
      })
    final class Done { var stamp: HistoryRetainedVerification.Stamp? }
    let done = Done()
    let running = RunningLoop()
    running.task = Task { @MainActor in
      await HistoryRefreshLoop(
        beforeRead: { done.stamp = await verification.run(done: done.stamp) },
        counters: {
          .init(content: session.revision, notices: session.noticeCount, source: session.stableSourceRevision)
        },
        currentKey: key,
        storedKey: { shown.result?.key },
        storedSource: { shown.result?.catalogSourceRevision },
        read: { key in
          await gate?.pass()
          if let page = await coordinator.historyResults(for: key) { shown.store(page) }
        },
        wait: { content, notices in await session.waitForChange(revision: content, notices: notices) },
        pace: { try? await Task.sleep(for: $0) },
        now: { .now }
      ).run()
      running.ended = true
    }
    return running
  }

  @Test(
    "The refresh loop hides a changed row of a kept page on each change notice, while a writer is active",
    .timeLimit(.minutes(1)))
  // Uses a real catalog, folder watcher and indexing passes (the path this protects); 0.7-3.5 s
  // measured on the M5 Max under load, bounded by the time limit.
  func loopVerifiesKeptPage() async throws {
    let f = try await fixture(rows: 40)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let shown = Shown()
    let coordinator = f.coordinator
    let loop = startLoop(f, shown)
    defer { loop.task.cancel() }
    try await shown.until { $0.items.count == 30 }
    let page = try #require(shown.result)
    guard case .catalog(let first) = page.items[0], case .catalog(let second) = page.items[1] else {
      Issue.record("The catalog page did not return catalog rows")
      return
    }

    // A writer is active (the source revision is unknown); another process removes one shown
    // file and its notice arrives. The list hides only that row (a display-only re-read or the
    // kept page's re-check).
    f.changes.begin()
    var writing = true
    defer { if writing { f.changes.finish(.transcript(second.key.id)) } }
    try removeShownFile(to: first.key.id, in: f)
    f.changes.externalChange(.transcript(first.key.id))
    try await shown.until { !$0.ids.contains(.transcript(first.key.id)) }
    #expect(shown.result?.ids.contains(.transcript(first.key.id)) == false)
    #expect(shown.result.map(coordinator.isCurrentHistoryResult) == false)

    // A second change in the same writer interval is hidden on its own notice.
    let checks = shown.checks
    try removeShownFile(to: second.key.id, in: f)
    f.changes.externalChange(.transcript(second.key.id))
    try await shown.until { !$0.ids.contains(.transcript(second.key.id)) }
    #expect(shown.checks > checks)
    #expect(shown.result?.ids.contains(.transcript(second.key.id)) == false)

    writing = false
    f.changes.finish(.transcript(second.key.id))
    try await loop.untilEnded()
  }

  @Test(
    "The loop publishes the kept page's removal before any replacement read",
    .timeLimit(.minutes(1)))
  func loopPublishesRemovalBeforeReplacementRead() async throws {
    let f = try await fixture(rows: 40)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let shown = Shown()
    let gate = ReadGate()
    defer { gate.open() }
    let loop = startLoop(f, shown, gate: gate)
    defer { loop.task.cancel() }
    try await shown.until { $0.items.count == 30 }
    // The loop is parked (no read in flight) before reads are held and the file is removed.
    while f.session.changeWaiterCountForTesting == 0 {
      try Task.checkCancellation()
      await Task.yield()
    }
    let page = try #require(shown.result)
    guard case .catalog(let first) = page.items[0], case .catalog(let second) = page.items[1] else {
      Issue.record("The catalog page did not return catalog rows")
      return
    }
    gate.closed = true
    f.changes.begin()
    var writing = true
    defer { if writing { f.changes.finish(.transcript(second.key.id)) } }
    try removeShownFile(to: first.key.id, in: f)
    try removeShownFile(to: second.key.id, in: f)
    f.changes.externalChange(.transcript(first.key.id))
    f.changes.externalChange(.transcript(second.key.id))

    // The loop reached its replacement read. A change notice arriving while the verification was
    // checking files makes it correctly discard that answer, so release the read and let the next
    // wake verify again; the verifier's own store must then lack both removed rows, whatever the
    // replacement reads show.
    while !gate.holding {
      try Task.checkCancellation()
      await Task.yield()
    }
    gate.open()
    let lacksRemoved: (HistoryQueryResult) -> Bool = {
      !$0.ids.contains(.transcript(first.key.id)) && !$0.ids.contains(.transcript(second.key.id))
    }
    while !shown.verifierStores.contains(where: lacksRemoved) {
      try Task.checkCancellation()
      await Task.yield()
    }
    let verified = try #require(
      shown.verifierStores.first(where: lacksRemoved))
    #expect(verified.items.count == 28)
    #expect(!verified.ids.contains(.transcript(first.key.id)))
    #expect(!verified.ids.contains(.transcript(second.key.id)))

    gate.open()
    writing = false
    f.changes.finish(.transcript(second.key.id))
    try await loop.untilEnded()
  }

  private func removeShownFile(to id: UUID, in f: Fixture) throws {
    // Another process removes the shown file. (An appended byte no longer works: the display no
    // longer waits for a stable source, so a re-read can show a changed row once the catalog
    // re-indexed it.)
    try FileManager.default.removeItem(at: f.transcripts.appendingPathComponent("\(id.uuidString).json"))
  }

  @Test("An outside deletion of one dictation removes that row and restores coverage")
  func scopedDeletion() async throws {
    let f = try await fixture(rows: 5)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let key = f.coordinator.historyQueryKey(
      for: .dictations, state: f.coordinator.requestedHistoryState(for: .dictations))
    let before = try #require(await f.coordinator.historyResults(for: key))
    guard case .catalog(let gone) = try #require(before.items.last) else {
      Issue.record("The catalog page did not return catalog rows")
      return
    }
    // An older app deletes the file; only the notice for that file reaches this session.
    try TranscriptStore(directory: f.transcripts).delete(id: gone.key.id)
    f.changes.externalChange(.transcript(gone.key.id))
    await f.session.waitForIndexingForTesting()
    let after = try #require(
      await f.coordinator.historyResults(
        for: f.coordinator.historyQueryKey(
          for: .dictations, state: f.coordinator.requestedHistoryState(for: .dictations))))
    #expect(after.items.count == 4)
    #expect(!after.ids.contains(.transcript(gone.key.id)))
    #expect(try await f.session.itemCount(now: Date())?.count == 4)
  }

  @Test("A named outside notice never certifies coverage on its own")
  func externalNeverCertifies() {
    var settled = HistorySourceChanges.Delta()
    settled.include(.admitted(1))
    settled.include(.settled(2, .transcript(UUID())))
    #expect(settled.spans(after: 0, through: 2))
    var outside = settled
    outside.include(.external(.transcript(UUID())))
    #expect(!outside.spans(after: 0, through: 2))
  }

  @Test("The folder watcher reports a root created later and a root replaced by another process")
  func watcherSeesRootChanges() async throws {
    let parent = TestTemporaryDirectory.url.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("transcripts", isDirectory: true)
    let roots = OSAllocatedUnfairLock(initialState: 0)
    let watch = try #require(
      HistoryDiskWatch(directories: [root], scope: { _ in .all }) { events in
        if events.contains(.rootChanged) { roots.withLock { $0 += 1 } }
      })
    // Another process (the stream ignores this process's own file events).
    try run("/bin/mkdir", root.path)
    #expect(
      await waitUntil { roots.withLock { $0 } >= 1 }, "creating the missing root was not reported")
    let seen = roots.withLock { $0 }
    try run("/bin/mv", root.path, parent.appendingPathComponent("moved").path)
    try run("/bin/mkdir", root.path)
    #expect(await waitUntil { roots.withLock { $0 } > seen }, "replacing the root was not reported")
    withExtendedLifetime(watch) {}
  }

  private func run(_ tool: String, _ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }

  /// Polls a signal the FSEvents queue sets; the deadline is only a fallback.
  private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))  // deadline-fallback: poll inside a 10 s bounded signal wait
    }
    return condition()
  }
}
