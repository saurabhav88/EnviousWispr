import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4586: the History list's refresh loop finishes a read that a content publish overtook and then
/// reads again; a read that came back empty is retried on the next notice, never in a tight loop.
/// And a new search opens at the top of its results, while a return to the tab restores its place.
@MainActor
@Suite(
  "History list refreshes without dropping a read and opens a new search at the top",
  .tags(.productOutcome), .timeLimit(.minutes(1)))
struct HistoryRefreshLoopTests {
  /// A stand-in for the session and the stored result, driven step by step by the test.
  @MainActor
  private final class World {
    var content: UInt64 = 0
    var notices: UInt64 = 0
    var source: UInt64? = 1
    var stored: TranscriptCoordinator.HistoryQueryKey?
    var reads: [TranscriptCoordinator.HistoryQueryKey] = []
    var pendingRead: CheckedContinuation<Bool, Never>?
    var pendingWait: CheckedContinuation<Void, Never>?
    var waits = 0
    var beforeReads = 0

    func key() -> TranscriptCoordinator.HistoryQueryKey {
      .init(
        revision: Int(content), pulse: 0,
        context: .init(tab: .dictations, query: "", filter: .none), echoShown: [], locale: "", localizations: [], calendar: .current)
    }

    func loop() -> HistoryRefreshLoop {
      HistoryRefreshLoop(
        beforeRead: { self.beforeReads += 1 },
        counters: { .init(content: self.content, notices: self.notices, source: self.source) },
        currentKey: { self.key() },
        storedKey: { self.stored },
        read: { key in
          self.reads.append(key)
          let succeeded = await withCheckedContinuation { (read: CheckedContinuation<Bool, Never>) in
            if Task.isCancelled { read.resume(returning: false) } else { self.pendingRead = read }
          }
          if succeeded { self.stored = key }
        },
        wait: { content, notices in
          // Like the session's `waitForChange`: a counter that already moved returns at once.
          guard self.content == content, self.notices == notices else { return }
          self.waits += 1
          await withCheckedContinuation { (wait: CheckedContinuation<Void, Never>) in
            if Task.isCancelled { wait.resume() } else { self.pendingWait = wait }
          }
        })
    }

    func finishRead(succeeded: Bool) {
      pendingRead?.resume(returning: succeeded)
      pendingRead = nil
    }

    func wake() {
      pendingWait?.resume()
      pendingWait = nil
    }
  }

  /// Yields only until the loop reaches the next point the test drives (the subject's signal).
  private func untilReading(_ world: World) async throws {
    while world.pendingRead == nil {
      try Task.checkCancellation()
      await Task.yield()
    }
  }

  private func untilParked(_ world: World) async throws {
    while world.pendingWait == nil {
      try Task.checkCancellation()
      await Task.yield()
    }
  }

  /// Ends the loop on every exit, releasing any read or wait it is parked in.
  private func stop(_ task: Task<Void, Never>, _ world: World) async {
    task.cancel()
    world.finishRead(succeeded: false)
    world.wake()
    await task.value
  }

  @Test("A read overtaken by a content publish is kept, then the newer content is read")
  func overtakenReadIsKept() async throws {
    let world = World()
    let task = Task { await world.loop().run() }
    // Synchronous on every exit: releases whatever the loop is parked in and cancels it.
    defer {
      task.cancel()
      world.finishRead(succeeded: false)
      world.wake()
    }
    try await untilReading(world)
    world.content = 1
    world.finishRead(succeeded: true)
    try await untilReading(world)
    // The overtaken read was stored, and the newer content was read next without a wait.
    #expect(world.stored?.revision == 0)
    #expect(world.reads.map(\.revision) == [0, 1])
    #expect(world.waits == 0)
    world.finishRead(succeeded: true)
    try await untilParked(world)
    #expect(world.stored?.revision == 1)
    await stop(task, world)
  }

  @Test("An empty read is retried on the next notice and parks when nothing changed")
  func emptyReadRetriesOnNotice() async throws {
    let world = World()
    let task = Task { await world.loop().run() }
    // Synchronous on every exit: releases whatever the loop is parked in and cancels it.
    defer {
      task.cancel()
      world.finishRead(succeeded: false)
      world.wake()
    }
    try await untilReading(world)
    world.finishRead(succeeded: false)
    try await untilParked(world)
    #expect(world.reads.count == 1)
    // A wake with nothing changed does not read again.
    world.wake()
    try await untilParked(world)
    #expect(world.reads.count == 1)
    // A change notice with the same content retries the same key once.
    world.notices += 1
    world.wake()
    try await untilReading(world)
    #expect(world.reads.count == 2)
    #expect(world.reads[1] == world.reads[0])
    world.finishRead(succeeded: true)
    try await untilParked(world)
    await stop(task, world)
  }

  @Test("A new search opens at the top; returning to the tab restores its place")
  func searchStartsAtTop() {
    let all = HistoryPaging.Context(tab: .dictations, query: "", filter: .none)
    let searched = HistoryPaging.Context(tab: .dictations, query: "AI", filter: .none)
    let deep = HistoryItemID.transcript(UUID())
    var place = HistoryListPlace()
    // No page yet: nothing to restore.
    #expect(place.restore(shownContext: nil, requested: all, saved: deep) == nil)
    // The tab's first page restores the saved place.
    let first = place.restore(shownContext: all, requested: all, saved: deep)
    #expect(first?.target == deep)
    // The reader typed a search: the old page still shows, so nothing new is asked.
    #expect(place.restore(shownContext: all, requested: searched, saved: deep) == first)
    // The search's page arrives: the top, even though the deep row may be in it.
    let top = place.restore(shownContext: searched, requested: searched, saved: deep)
    #expect(top?.target == nil)
    #expect(top?.token != first?.token)
    // Back to the original search inside the same list: still a change, so the top.
    #expect(place.restore(shownContext: all, requested: all, saved: deep)?.target == nil)
    // A fresh list for the tab (a tab switch or Back) restores the saved place again.
    var returned = HistoryListPlace()
    #expect(returned.restore(shownContext: all, requested: all, saved: deep)?.target == deep)
  }

  @Test("A kept page's file check is dropped when anything moved, and done once per change")
  func retainedVerificationDropsStaleAnswers() async {
    let key = World().key()
    let page = try? HistoryQueryResult(key: key, items: [])
    let checked = try? HistoryQueryResult(key: key, items: [])
    guard let page, let checked else {
      Issue.record("could not build a page")
      return
    }
    final class Box {
      var stored: HistoryQueryResult
      var notices: UInt64 = 0
      var verifications = 0
      var duringVerify: () -> Void = {}
      init(_ stored: HistoryQueryResult) { self.stored = stored }
    }
    let box = Box(page)
    let verification = HistoryRetainedVerification(
      stamp: { .init(key: key, notices: box.notices, source: 2, grouping: 0, stored: box.stored.identity) },
      stored: { box.stored },
      verify: { _ in
        box.verifications += 1
        box.duringVerify()
        return checked
      },
      store: { box.stored = $0 })

    // A change notice while the check runs: the answer is dropped and the stamp stays undone.
    box.duringVerify = { box.notices += 1 }
    let dropped = await verification.run(done: nil)
    #expect(dropped == nil)
    #expect(box.stored.identity == page.identity)

    // Nothing moves: the checked page is stored and that stamp is done.
    box.duringVerify = {}
    let done = await verification.run(done: dropped)
    #expect(box.stored.identity == checked.identity)
    #expect(done != nil)

    // The same stamp again: no second check.
    let count = box.verifications
    #expect(await verification.run(done: done) == done)
    #expect(box.verifications == count)
  }

  @Test("The same page read again is recognized; a newer content revision is recorded without a rebuild")
  func samePageIsRecognized() throws {
    let older = World()
    let newer = World()
    newer.content = 1
    let summary = HistoryCatalog.Summary(
      key: .init(tab: .dictations, id: UUID()), date: Date(timeIntervalSinceReferenceDate: 780_000_000),
      preview: "", sources: [])
    let first = try HistoryQueryResult(
      key: older.key(), items: [.catalog(summary)], catalogSourceRevision: 3, catalogDayCounts: [:])
    let again = try HistoryQueryResult(
      key: newer.key(), items: [.catalog(summary)], catalogSourceRevision: 3, catalogDayCounts: [:])
    #expect(first.samePage(as: again))
    let restamped = first.restamped(key: again.key)
    #expect(restamped.key == again.key)
    #expect(restamped.identity != first.identity)
    #expect(restamped.items.map(\.id) == first.items.map(\.id))
    let other = try HistoryQueryResult(
      key: newer.key(), items: [], catalogSourceRevision: 3, catalogDayCounts: [:])
    #expect(first.samePage(as: other) == false)
    let otherSource = try HistoryQueryResult(
      key: newer.key(), items: [.catalog(summary)], catalogSourceRevision: 4, catalogDayCounts: [:])
    #expect(first.samePage(as: otherSource) == false)
  }
}

