import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

#if DEBUG
  /// #4586 H1: indexing progress and status changes must not throw away the History page being
  /// read. A content publish while a page is read keeps that page (it shows, but cannot select or
  /// page until the next read lands). #4586 r6: a source change no longer refuses a first page
  /// either; it is shown, stamped with the source it started from, and is current only while that
  /// stamp is the current source.
  @MainActor
  @Suite(
    "History keeps a page read while the catalog publishes", .tags(.productOutcome),
    .timeLimit(.minutes(1)))
  struct HistoryContentRevisionTests {
    private struct Fixture {
      let root: URL
      let changes: HistorySourceChanges
      let store: TranscriptStore
      let meetings: MeetingStore
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
      return Fixture(
        root: root, changes: changes, store: store, meetings: meetings, session: session,
        coordinator: coordinator)
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

    /// What the list loop stored and how many reads it ran, as `HistoryDiaryView` keeps them.
    @MainActor
    private final class LoopBox {
      var result: HistoryQueryResult?
      var reads = 0
      var ended = false
    }

    /// What the ordering tests observe, all on the main actor: the events in order, and the gate
    /// that holds one page read before its catalog call.
    @MainActor
    private final class ReadOrder {
      var events: [String] = []
      var readRefused: Bool?
      /// The page the held read returned, stored by the read itself.
      var page: HistoryCatalog.Page?
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

    /// A second session and coordinator over the fixture's existing catalog (an app relaunch),
    /// with the watcher install held before it can finish.
    private func relaunch(_ f: Fixture, _ order: ReadOrder) async throws -> Fixture {
      let session = HistoryCatalogSession(
        changes: f.changes, sources: f.store.historyCatalogSources(meetings: f.meetings),
        directory: f.root.appendingPathComponent("catalog"))
      let coordinator = TranscriptCoordinator(store: f.store)
      coordinator.catalogSession = session
      session.beforeWatcherInstallForTesting = { await order.hold() }
      session.beforeReconcileForTesting = {
        if order.events.contains("reconcile") == false { order.events.append("reconcile") }
      }
      coordinator.startHistoryCatalog()
      try await order.untilHolding()
      return Fixture(
        root: f.root, changes: f.changes, store: f.store, meetings: f.meetings, session: session,
        coordinator: coordinator)
    }

    @Test("A first page while the watcher install is held shows the file-checked rows and is not final")
    func firstPageWhileWatcherInstallHeld() async throws {
      let f = try await fixture(rows: 5)
      defer { try? FileManager.default.removeItem(at: f.root) }
      let seen = try #require(await f.coordinator.historyResults(for: key(f)))
      guard case .transcript(let gone) = seen.items[0].id else {
        Issue.record("expected a transcript row")
        return
      }
      try FileManager.default.removeItem(
        at: f.root.appendingPathComponent("transcripts").appendingPathComponent("\(gone.uuidString).json"))
      let order = ReadOrder()
      let r = try await relaunch(f, order)
      defer {
        r.session.beforeWatcherInstallForTesting = nil
        r.session.beforeReconcileForTesting = nil
        order.release()
      }
      let page = try #require(await r.coordinator.historyResults(for: key(r)))
      #expect(page.items.count == 4)
      #expect(page.ids.contains(.transcript(gone)) == false)
      #expect(page.catalogDayCounts == nil)
      let held = HistoryPaging.finality(
        result: page, key: key(r), source: r.session.stableSourceRevision)
      #expect(held.isFinal == false)
      // The full pass reaches `reconcile` while the install is still held.
      try await order.until("reconcile")
      #expect(r.session.watcherIsInstalledForTesting == false)
      r.session.beforeWatcherInstallForTesting = nil
      order.release()
      await r.session.waitForIndexingForTesting()
      let again = try #require(await r.coordinator.historyResults(for: key(r)))
      #expect(again.items.count == 4)
      let done = HistoryPaging.finality(
        result: again, key: key(r), source: r.session.stableSourceRevision)
      #expect(done.isFinal)
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

    enum Mover: String, CaseIterable, Sendable { case writer, external, install }
    enum Moment: String, CaseIterable, Sendable { case duringRead, afterBuild }

    /// Moves the source with `mover` from inside a hook: a writer that begins and finishes, an
    /// outside change, or the watcher install (held beforehand, released here, then awaited).
    private func moveSource(_ f: Fixture, _ mover: Mover, _ order: ReadOrder) async {
      switch mover {
      case .writer:
        f.changes.begin()
        f.changes.finish(.transcript(UUID()))
      case .external:
        f.changes.externalChange()
      case .install:
        order.release()
        while !f.session.watcherIsInstalledForTesting, !Task.isCancelled { await Task.yield() }
      }
    }

    @Test(
      "A first page whose source moves during the read or the build is shown, not current, and the next read is current",
      arguments: Mover.allCases, Moment.allCases)
    func firstPageShownWhenSourceMoves(mover: Mover, moment: Moment) async throws {
      let f = try await fixture(rows: 5)
      defer { try? FileManager.default.removeItem(at: f.root) }
      let order = ReadOrder()
      defer {
        order.release()
        clearHooks(f)
      }
      if mover == .install {
        f.session.beforeWatcherInstallForTesting = { await order.hold() }
        f.session.rewatchForTesting()
        try await order.untilHolding()
      }
      let hook: @MainActor () async -> Void = { await moveSource(f, mover, order) }
      switch moment {
      case .duringRead: f.session.beforePageFenceForTesting = hook
      case .afterBuild: f.coordinator.afterBuildResultForTesting = hook
      }
      let shown = try #require(await f.coordinator.historyResults(for: key(f)))
      clearHooks(f)
      #expect(shown.items.count == 5)
      #expect(f.coordinator.isCurrentHistoryResult(shown) == false)
      #expect(shown.catalogSourceRevision != f.session.stableSourceRevision)
      // The following read for the current request is current once indexing has settled.
      await f.session.waitForIndexingForTesting()
      let next = try #require(await f.coordinator.historyResults(for: key(f)))
      #expect(next.items.count == 5)
      #expect(f.coordinator.isCurrentHistoryResult(next))
    }

    @Test("A real search change inside the page hook or the build drops the first page")
    func searchChangeDropsFirstPage() async throws {
      for moment in Moment.allCases {
        let f = try await fixture(rows: 5)
        defer { try? FileManager.default.removeItem(at: f.root) }
        defer { clearHooks(f) }
        let hook: @MainActor () async -> Void = { [coordinator = f.coordinator] in
          var state = coordinator.requestedHistoryState(for: .dictations)
          state.query = "row 1"
          coordinator.setHistoryState(state, for: .dictations)
        }
        switch moment {
        case .duringRead: f.session.beforePageFenceForTesting = hook
        case .afterBuild: f.coordinator.afterBuildResultForTesting = hook
        }
        let result = await f.coordinator.historyResults(for: key(f))
        #expect(result == nil)
      }
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

    @Test("A save that opens during the read leaves the page display-only")
    func writerOpeningDuringReadIsDisplayOnly() async throws {
      let f = try await fixture(rows: 40)
      defer { try? FileManager.default.removeItem(at: f.root) }
      f.session.beforePageFenceForTesting = { f.changes.begin() }
      defer {
        f.session.beforePageFenceForTesting = nil
        f.changes.finish(.transcript(UUID()))
      }
      let shown = try #require(await f.coordinator.historyResults(for: key(f)))
      #expect(shown.items.count == 30)
      #expect(shown.catalogDayCounts == nil)
      #expect(shown.continuation == nil)
      #expect(shown.newerContinuation == nil)
      #expect(f.coordinator.isCurrentHistoryResult(shown) == false)
    }

    @Test("A page read while a writer is open shows its rows as display-only until the writer finishes")
    func writerHeldOpenPageIsDisplayOnly() async throws {
      let f = try await fixture(rows: 40)
      defer { try? FileManager.default.removeItem(at: f.root) }
      var writing = true
      f.changes.begin()
      defer { if writing { f.changes.finish(.transcript(UUID())) } }
      let shown = try #require(await f.coordinator.historyResults(for: key(f)))
      #expect(shown.items.count == 30)
      // 40 rows: the read itself saw a continuation, which a display-only page must not keep.
      #expect(shown.catalogDayCounts == nil)
      #expect(shown.continuation == nil)
      #expect(shown.newerContinuation == nil)
      #expect(f.coordinator.isCurrentHistoryResult(shown) == false)
      let held = HistoryPaging.finality(
        result: shown, key: shown.key, source: f.session.stableSourceRevision)
      #expect(held.canPage == false)
      #expect(held.isFinal == false)

      // A search that matches nothing is not a final empty state while the writer is open.
      var state = f.coordinator.requestedHistoryState(for: .dictations)
      state.query = "nothing matches this"
      f.coordinator.setHistoryState(state, for: .dictations)
      let empty = try #require(await f.coordinator.historyResults(for: key(f)))
      #expect(empty.items.isEmpty)
      let emptyHeld = HistoryPaging.finality(
        result: empty, key: empty.key, source: f.session.stableSourceRevision)
      #expect(emptyHeld.isFinal == false)

      // The real refresh loop, wired as `HistoryDiaryView.refresh(tab:)` wires it, shows that
      // display-only page and parks while the writer is open; the writer's finish alone wakes it.
      let box = LoopBox()
      let coordinator = f.coordinator
      let session = f.session
      let queryKey: @MainActor @Sendable () -> TranscriptCoordinator.HistoryQueryKey = {
        coordinator.historyQueryKey(
          for: .dictations, state: coordinator.requestedHistoryState(for: .dictations))
      }
      let loop = Task { @MainActor in
        await HistoryRefreshLoop(
          beforeRead: {},
          counters: {
            .init(
              content: session.revision, notices: session.noticeCount,
              source: session.stableSourceRevision)
          },
          currentKey: queryKey,
          storedKey: { box.result?.key },
          storedSource: { box.result?.catalogSourceRevision },
          read: { key in
            if let page = await coordinator.historyResults(for: key) { box.result = page }
            box.reads += 1
          },
          wait: { content, notices in
            await session.waitForChange(revision: content, notices: notices)
          },
          pace: { try? await Task.sleep(for: $0) },
          now: { .now }
        ).run()
        box.ended = true
      }
      defer { loop.cancel() }
      while box.result == nil || session.changeWaiterCountForTesting == 0 {
        try Task.checkCancellation()
        await Task.yield()
      }
      let parked = try #require(box.result)
      #expect(coordinator.isCurrentHistoryResult(parked) == false)
      let readsWhileOpen = box.reads
      writing = false
      f.changes.finish(.transcript(UUID()))
      while box.reads <= readsWhileOpen {
        try Task.checkCancellation()
        await Task.yield()
      }
      loop.cancel()
      while !box.ended {
        try Task.checkCancellation()
        await Task.yield()
      }
      await f.session.waitForIndexingForTesting()
      await f.session.waitForIndexingForTesting()
      let final = try #require(await f.coordinator.historyResults(for: key(f)))
      #expect(final.items.isEmpty)
      let emptyDone = HistoryPaging.finality(
        result: final, key: final.key, source: f.session.stableSourceRevision)
      #expect(emptyDone.canPage)
      #expect(emptyDone.isFinal)

      state.query = ""
      f.coordinator.setHistoryState(state, for: .dictations)
      let rows = try #require(await f.coordinator.historyResults(for: key(f)))
      #expect(rows.items.count == 30)
      #expect(f.coordinator.isCurrentHistoryResult(rows))
      let done = HistoryPaging.finality(
        result: rows, key: rows.key, source: f.session.stableSourceRevision)
      #expect(done.isFinal)
    }

    @Test("An extension read across a source move is refused")
    func extensionRefusedAcrossSourceMove() async throws {
      let f = try await fixture(rows: 40)
      defer { try? FileManager.default.removeItem(at: f.root) }
      defer { clearHooks(f) }
      let first = try #require(await f.coordinator.historyResults(for: key(f)))
      #expect(first.continuation != nil)
      f.session.beforePageFenceForTesting = { [changes = f.changes] in changes.externalChange() }
      let joined = await f.coordinator.historyResults(for: first.key, extending: first)
      #expect(joined == nil)
    }

    /// API-level, not the UI path: after a file is deleted with no notice, the retained page
    /// drops its row, and the delivery and detail paths refuse it.
    @Test("A file deleted after its page was published is refused by retained, delivery and detail checks")
    func deletedFileAfterPublish() async throws {
      let f = try await fixture(rows: 3)
      defer { try? FileManager.default.removeItem(at: f.root) }
      let page = try #require(await f.coordinator.historyResults(for: key(f)))
      guard case .transcript(let id) = page.items[0].id else {
        Issue.record("expected a transcript row")
        return
      }
      #expect(await f.coordinator.loadCatalogDetail(id, authoritative: true) != nil)
      #expect(f.coordinator.verifiedRowForDelivery(id: id) != nil)
      try FileManager.default.removeItem(
        at: f.root.appendingPathComponent("transcripts").appendingPathComponent("\(id.uuidString).json"))
      let kept = try #require(await f.coordinator.retainedHistoryResult(page))
      #expect(kept.ids.contains(.transcript(id)) == false)
      #expect(kept.items.count == 2)
      #expect(f.coordinator.verifiedRowForDelivery(id: id) == nil)
      #expect(await f.coordinator.loadCatalogDetail(id, authoritative: true) == nil)
      let fresh = try #require(await f.coordinator.historyResults(for: key(f)))
      #expect(fresh.ids.contains(.transcript(id)) == false)
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
      let content = spawnWaiter(session, revision: session.revision, notices: session.noticeCount)
      defer { content.task.cancel() }
      try await waitUntilRegistered(session)
      session.advanceContentForTesting()
      try await joined(content)

      // A change notice wakes it too, with no content publish.
      let notices = session.noticeCount
      let notice = spawnWaiter(session, revision: session.revision, notices: notices)
      defer { notice.task.cancel() }
      try await waitUntilRegistered(session)
      f.changes.externalChange(.transcript(UUID()))
      try await joined(notice)
      #expect(session.noticeCount != notices)

      // Cancellation after registration resumes and removes the waiter.
      let registered = spawnWaiter(
        session, revision: session.revision, notices: session.noticeCount)
      defer { registered.task.cancel() }
      try await waitUntilRegistered(session)
      registered.task.cancel()
      try await joined(registered)
      #expect(session.changeWaiterCountForTesting == 0)

      // Cancellation before the waiter registers ends it as well.
      let early = spawnWaiter(session, revision: session.revision, notices: session.noticeCount)
      defer { early.task.cancel() }
      early.task.cancel()
      try await joined(early)
      #expect(session.changeWaiterCountForTesting == 0)
      await session.waitForIndexingForTesting()
    }

    /// A change waiter and a flag it sets when `waitForChange` returns.
    @MainActor
    private final class Waiter {
      var ended = false
      var task: Task<Void, Never>!
    }

    private func spawnWaiter(
      _ session: HistoryCatalogSession, revision: UInt64, notices: UInt64
    ) -> Waiter {
      let waiter = Waiter()
      waiter.task = Task { @MainActor in
        await session.waitForChange(revision: revision, notices: notices)
        waiter.ended = true
      }
      return waiter
    }

    /// Waits for the waiter's own end signal; throws on test cancellation (its time limit), so a
    /// waiter that never wakes fails the test instead of hanging it.
    private func joined(_ waiter: Waiter) async throws {
      while !waiter.ended {
        try Task.checkCancellation()
        await Task.yield()
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
