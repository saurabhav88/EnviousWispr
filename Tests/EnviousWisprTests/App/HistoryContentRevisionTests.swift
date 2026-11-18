import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

#if DEBUG
  /// #4586 H1: indexing progress and status changes must not throw away the History page being
  /// read. A content publish while a page is read keeps that page (it shows, but cannot select or
  /// page until the next read lands); only a source change refuses it.
  @MainActor
  @Suite(
    "History keeps a page read while the catalog publishes", .tags(.productOutcome),
    .timeLimit(.minutes(1)))
  struct HistoryContentRevisionTests {
    private struct Fixture {
      let root: URL
      let changes: HistorySourceChanges
      let session: HistoryCatalogSession
      let coordinator: TranscriptCoordinator
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
      return Fixture(root: root, changes: changes, session: session, coordinator: coordinator)
    }

    private func key(_ f: Fixture) -> TranscriptCoordinator.HistoryQueryKey {
      f.coordinator.historyQueryKey(
        for: .dictations, state: f.coordinator.requestedHistoryState(for: .dictations))
    }

    @Test(
      "Only changed rows or a restored certificate are content",
      arguments: [
        (false, false, false), (true, false, true), (false, true, true), (true, true, true),
      ])
    func publishClassification(changed: Bool, newCertificate: Bool, advances: Bool) {
      #expect(
        HistoryCatalogSession.advancesContent(changed: changed, newCertificate: newCertificate)
          == advances)
    }

    @Test("A status-only publish leaves the content revision; changed rows advance it")
    func statusOnlyPublishKeepsRevision() async throws {
      let f = try await fixture(rows: 3)
      defer { try? FileManager.default.removeItem(at: f.root) }
      #expect(f.session.status == .ready)
      // An unreadable History file makes the next pass report the source unavailable without
      // changing a catalog row: a status-only publish.
      let bad = UUID()
      let transcripts = f.root.appendingPathComponent("transcripts")
      try Data("not a transcript".utf8).write(to: transcripts.appendingPathComponent("\(bad.uuidString).json"))
      let before = f.session.revision
      f.changes.externalChange(.transcript(bad))
      await f.session.waitForIndexingForTesting()
      #expect(f.session.status == .unavailable)
      #expect(f.session.revision == before)
      // A real row change is content.
      try FileManager.default.removeItem(at: transcripts.appendingPathComponent("\(bad.uuidString).json"))
      let saved = Transcript(text: "new row", processingTime: 0, backendType: .parakeet)
      try TranscriptStore(directory: transcripts).save(saved)
      f.changes.externalChange(.transcript(saved.id))
      await f.session.waitForIndexingForTesting()
      #expect(f.session.revision != before)
    }

    /// What the ordering tests observe, all on the main actor: the events in order, and the gate
    /// that holds one page read before its catalog call.
    @MainActor
    private final class ReadOrder {
      var events: [String] = []
      var readRefused: Bool?
      /// The page the held read returned, stored by the read itself.
      var page: HistoryCatalog.Page?
      /// The result the list loop stored, as `HistoryDiaryView.results[tab]` does.
      var stored: HistoryQueryResult?
      var reconciles = 0
      private var gate: CheckedContinuation<Void, Never>?
      private(set) var holding = false

      /// Holds the calling read until `release()` or until its task is cancelled.
      func hold() async {
        holding = true
        await withTaskCancellationHandler {
          await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if Task.isCancelled { continuation.resume() } else { gate = continuation }
          }
        } onCancel: {
          Task { @MainActor in self.release() }
        }
      }

      func release() {
        gate?.resume()
        gate = nil
      }

      /// Waits until `event` was recorded; throws on test cancellation (its time limit).
      func until(_ event: String) async throws {
        while events.contains(event) == false {
          try Task.checkCancellation()
          await Task.yield()
        }
      }

      func untilHolding() async throws {
        while holding == false {
          try Task.checkCancellation()
          await Task.yield()
        }
      }
    }

    /// Holds a page read before its catalog call, then asks for a full re-check (no source
    /// change, as at launch) whose backend hook runs `whenPassOpens`. Records "catalog read" when
    /// the read's catalog call returned (the post-catalog hook), "reconcile" the FIRST time a
    /// full pass reaches `reconcile`, and counts every `reconcile`.
    private func holdReadThenRequestPass(
      _ f: Fixture, _ order: ReadOrder, whenPassOpens: @escaping @MainActor (Task<HistoryCatalog.Page?, Never>) -> Void
    ) async throws -> Task<HistoryCatalog.Page?, Never> {
      f.session.beforePageCatalogForTesting = { await order.hold() }
      f.session.beforePageFenceForTesting = { order.events.append("catalog read") }
      // The read reports its own end, so no extra task waits on it.
      let read = Task { @MainActor in
        let page = try? await f.session.page(.init(tab: .dictations))
        order.readRefused = page == nil
        order.page = page
        order.events.append("read done")
        return page
      }
      do {
        try await order.untilHolding()
      } catch {
        read.cancel()
        order.release()
        throw error
      }
      f.session.beforePageCatalogForTesting = nil
      f.session.afterPassOpenForTesting = { whenPassOpens(read) }
      f.session.beforeReconcileForTesting = {
        order.reconciles += 1
        if order.events.contains("reconcile") == false { order.events.append("reconcile") }
      }
      f.session.requestFullPassForTesting()
      return read
    }

    private func clearHooks(_ f: Fixture) {
      f.session.beforePageCatalogForTesting = nil
      f.session.beforePageFenceForTesting = nil
      f.session.afterPassOpenForTesting = nil
      f.session.beforeReconcileForTesting = nil
      f.session.beforeWatcherInstallForTesting = nil
      f.coordinator.afterBuildResultForTesting = nil
    }

    @Test("A page read already waiting when a full re-check starts reaches the catalog first")
    func waitingReadGoesBeforeFullPass() async throws {
      let f = try await fixture(rows: 3)
      defer { try? FileManager.default.removeItem(at: f.root) }
      let order = ReadOrder()
      defer { clearHooks(f) }
      // The held read is let go only once the pass has its backend; a pass that does not wait
      // reaches `reconcile` before the read's catalog call returns.
      let read = try await holdReadThenRequestPass(f, order) { _ in
        Task { @MainActor in order.release() }
      }
      defer {
        read.cancel()
        order.release()
      }
      try await order.until("reconcile")
      try await order.until("catalog read")
      #expect(order.events.firstIndex(of: "catalog read")! < order.events.firstIndex(of: "reconcile")!)
      // Nothing changed the source, so the rows reach the list.
      try await order.until("read done")
      #expect(order.readRefused == false)
      #expect(order.page?.summaries.count == 3)
      await f.session.waitForIndexingForTesting()
    }

    @Test("A waiting page read that is cancelled lets the re-check go on")
    func cancelledReadReleasesPass() async throws {
      let f = try await fixture(rows: 3)
      defer { try? FileManager.default.removeItem(at: f.root) }
      let order = ReadOrder()
      defer { clearHooks(f) }
      let source = f.changes.revision
      // The view leaves: its read is cancelled while held, exits, and the pass proceeds. The
      // source stays put, so only the cancellation can refuse the read.
      let read = try await holdReadThenRequestPass(f, order) { read in read.cancel() }
      defer { order.release() }
      try await order.until("reconcile")
      try await order.until("read done")
      #expect(f.changes.revision == source)
      #expect(order.readRefused == true)
      await f.session.waitForIndexingForTesting()
    }

    @Test("A first page asked for while the watcher starts waits for it, then reaches the list")
    func firstPageWaitsForWatcher() async throws {
      let f = try await fixture(rows: 3)
      defer { try? FileManager.default.removeItem(at: f.root) }
      let order = ReadOrder()
      defer { clearHooks(f) }
      f.session.beforeWatcherInstallForTesting = { await order.hold() }
      f.session.beforePageCatalogForTesting = { order.events.append("catalog") }
      f.session.rewatchForTesting()
      defer { order.release() }
      try await order.untilHolding()
      // The real list loop, wired as `HistoryDiaryView.refresh(tab:)` wires it. It reports its
      // own progress through `order`, so nothing awaits the task itself.
      let session = f.session
      let coordinator = f.coordinator
      let loop = Task { @MainActor in
        await HistoryRefreshLoop(
          beforeRead: {},
          counters: {
            .init(
              content: session.revision, notices: session.noticeCount,
              source: session.stableSourceRevision)
          },
          currentKey: { key(f) },
          storedKey: { order.stored?.key },
          read: { key in
            if let result = await coordinator.historyResults(for: key) { order.stored = result }
          },
          wait: { content, notices in
            await session.waitForChange(revision: content, notices: notices)
          }
        ).run()
      }
      defer { loop.cancel() }
      // The read parks on the registration: it never reads rows the watcher does not cover.
      while f.session.taskEndWaiterCountForTesting == 0 {
        try Task.checkCancellation()
        await Task.yield()
      }
      #expect(order.events.contains("catalog") == false)
      #expect(order.stored == nil)
      f.session.beforeWatcherInstallForTesting = nil
      order.release()
      while order.stored == nil {
        try Task.checkCancellation()
        await Task.yield()
      }
      let result = try #require(order.stored)
      #expect(result.items.count == 3)
      #expect(result.catalogSourceRevision == f.session.stableSourceRevision)
      #expect(f.session.watcherIsInstalledForTesting)
      loop.cancel()
      await f.session.waitForIndexingForTesting()
    }

    @Test("A watcher registered while a full pass waits for reads adds no second full scan")
    func registrationDuringWaitingPassIsCoalesced() async throws {
      let f = try await fixture(rows: 3)
      defer { try? FileManager.default.removeItem(at: f.root) }
      let order = ReadOrder()
      defer { clearHooks(f) }
      let read = try await holdReadThenRequestPass(f, order) { _ in order.events.append("pass open") }
      defer {
        read.cancel()
        order.release()
      }
      try await order.until("pass open")
      #expect(f.session.fullPassAwaitingStartForTesting)
      f.session.rewatchForTesting()
      while !f.session.watcherIsInstalledForTesting {
        try Task.checkCancellation()
        await Task.yield()
      }
      order.release()
      try await order.until("read done")
      await f.session.waitForIndexingForTesting()
      #expect(order.reconciles == 1)
      #expect(f.session.status == .ready)
    }

    @Test("A page whose source moves while its result is built is refused")
    func pageRefusedWhenSourceMovesDuringBuild() async throws {
      let f = try await fixture(rows: 5)
      defer { try? FileManager.default.removeItem(at: f.root) }
      defer { clearHooks(f) }
      let order = ReadOrder()
      // The hook runs only after the read was accepted, so the source moves mid-build.
      f.coordinator.afterBuildResultForTesting = { [changes = f.changes] in
        order.events.append("built")
        changes.begin()
      }
      let refused = await f.coordinator.historyResults(for: key(f))
      #expect(order.events == ["built"])
      #expect(refused == nil)
      f.changes.finish(.transcript(UUID()))
    }

    @Test("A page read across a content publish is kept, shown and not yet current")
    func pageSurvivesContentPublish() async throws {
      let f = try await fixture(rows: 5)
      defer { try? FileManager.default.removeItem(at: f.root) }
      let before = key(f)
      f.session.beforePageFenceForTesting = { [session = f.session] in
        session.advanceContentForTesting()
      }
      let kept = try #require(await f.coordinator.historyResults(for: before))
      f.session.beforePageFenceForTesting = nil
      #expect(kept.items.count == 5)
      #expect(kept.key == before)
      #expect(key(f) != before)
      #expect(key(f).request == before.request)
      // It may display, but an overtaken page authorizes nothing until the next read.
      #expect(f.coordinator.isCurrentHistoryResult(kept) == false)
      let fresh = try #require(await f.coordinator.historyResults(for: key(f)))
      #expect(f.coordinator.isCurrentHistoryResult(fresh))
    }

    @Test("A page read across a source change is refused")
    func pageRefusedWhenSourceMoves() async throws {
      let f = try await fixture(rows: 5)
      defer { try? FileManager.default.removeItem(at: f.root) }
      f.session.beforePageFenceForTesting = { [changes = f.changes] in changes.begin() }
      let refused = await f.coordinator.historyResults(for: key(f))
      f.session.beforePageFenceForTesting = nil
      #expect(refused == nil)
      f.changes.finish(.transcript(UUID()))
    }

    @Test("A page extension never joins two content generations")
    func extensionRefusedAcrossContentPublish() async throws {
      let f = try await fixture(rows: 40)
      defer { try? FileManager.default.removeItem(at: f.root) }
      let first = try #require(await f.coordinator.historyResults(for: key(f)))
      #expect(first.continuation != nil)
      f.session.advanceContentForTesting()
      let joined = await f.coordinator.historyResults(for: first.key, extending: first)
      #expect(joined == nil)
    }

    @Test("Waiting for a change ends on a content publish, a notice, or cancellation")
    func waitForChangeWakes() async throws {
      let f = try await fixture(rows: 1)
      defer { try? FileManager.default.removeItem(at: f.root) }
      let session = f.session

      // Already moved: returns at once.
      await session.waitForChange(revision: session.revision &+ 1, notices: session.noticeCount)

      // A content publish wakes a registered waiter.
      let content = Task {
        await session.waitForChange(revision: session.revision, notices: session.noticeCount)
      }
      defer { content.cancel() }
      try await waitUntilRegistered(session)
      session.advanceContentForTesting()
      await joined(content)

      // A change notice wakes it too, with no content publish.
      let notices = session.noticeCount
      let notice = Task {
        await session.waitForChange(revision: session.revision, notices: notices)
      }
      defer { notice.cancel() }
      try await waitUntilRegistered(session)
      f.changes.externalChange(.transcript(UUID()))
      await joined(notice)
      #expect(session.noticeCount != notices)

      // Cancellation after registration resumes and removes the waiter.
      let registered = Task {
        await session.waitForChange(revision: session.revision, notices: session.noticeCount)
      }
      defer { registered.cancel() }
      try await waitUntilRegistered(session)
      registered.cancel()
      await joined(registered)
      #expect(session.changeWaiterCountForTesting == 0)

      // Cancellation before the waiter registers ends it as well.
      let early = Task {
        await session.waitForChange(revision: session.revision, notices: session.noticeCount)
      }
      defer { early.cancel() }
      early.cancel()
      await joined(early)
      #expect(session.changeWaiterCountForTesting == 0)
      await session.waitForIndexingForTesting()
    }

    /// Awaits `task`, cancelling it when the test is cancelled (its time limit), so a waiter that
    /// never wakes fails the test instead of hanging it.
    private func joined(_ task: Task<Void, Never>) async {
      await withTaskCancellationHandler {
        await task.value
      } onCancel: {
        task.cancel()
      }
    }

    /// Waits on the subject's own registration signal; yields only while that signal is absent.
    private func waitUntilRegistered(_ session: HistoryCatalogSession) async throws {
      while session.changeWaiterCountForTesting == 0 {
        try Task.checkCancellation()
        await Task.yield()
      }
    }
  }
#endif
