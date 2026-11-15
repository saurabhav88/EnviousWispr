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
    let kept = try #require(f.coordinator.retainedHistoryResult(shown))
    #expect(kept.items.count == 29)
    #expect(!kept.ids.contains(.transcript(edited.key.id)))
    #expect(kept.continuation == nil && kept.catalogDayCounts == nil)
    #expect(!f.coordinator.isCurrentHistoryResult(kept))

    await f.session.waitForIndexingForTesting()
    #expect(f.session.watcherRegistrations == 1)
    #expect(f.session.status == .ready)
    let fresh = try #require(
      await f.coordinator.historyResults(
        for: f.coordinator.historyQueryKey(
          for: .dictations, state: f.coordinator.requestedHistoryState(for: .dictations))))
    #expect(fresh.items.count == 30)
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
