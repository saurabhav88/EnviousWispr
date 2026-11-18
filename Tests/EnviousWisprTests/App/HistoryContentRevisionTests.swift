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

    /// Holds a page read before its catalog call, then asks for a full re-check whose backend
    /// hook runs `whenPassOpens`. Records "catalog read" when the read's catalog call returned
    /// (the post-catalog hook) and "reconcile" the FIRST time a full pass reaches `reconcile`.
    private func holdReadThenRequestPass(
      _ f: Fixture, _ order: ReadOrder, whenPassOpens: @escaping @MainActor (Task<HistoryCatalog.Page?, Never>) -> Void
    ) async throws -> Task<HistoryCatalog.Page?, Never> {
      f.session.beforePageCatalogForTesting = { await order.hold() }
      f.session.beforePageFenceForTesting = { order.events.append("catalog read") }
      let read = Task { try? await f.session.page(.init(tab: .dictations)) }
      try await order.untilHolding()
      f.session.beforePageCatalogForTesting = nil
      f.session.afterPassOpenForTesting = { whenPassOpens(read) }
      f.session.beforeReconcileForTesting = {
        if order.events.contains("reconcile") == false { order.events.append("reconcile") }
      }
      f.changes.externalChange()
      return read
    }

    private func clearHooks(_ f: Fixture) {
      f.session.beforePageCatalogForTesting = nil
      f.session.beforePageFenceForTesting = nil
      f.session.afterPassOpenForTesting = nil
      f.session.beforeReconcileForTesting = nil
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
      // The read finishes either way; the outside change it overlapped may refuse it (a valid
      // source-change refusal), which this ordering test does not judge.
      _ = await read.value
      await f.session.waitForIndexingForTesting()
    }

    @Test("A waiting page read that is cancelled lets the re-check go on")
    func cancelledReadReleasesPass() async throws {
      let f = try await fixture(rows: 3)
      defer { try? FileManager.default.removeItem(at: f.root) }
      let order = ReadOrder()
      defer { clearHooks(f) }
      // The view leaves: its read is cancelled while held, exits, and the pass proceeds.
      let read = try await holdReadThenRequestPass(f, order) { read in read.cancel() }
      defer { order.release() }
      try await order.until("reconcile")
      #expect(await read.value == nil)
      await f.session.waitForIndexingForTesting()
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
