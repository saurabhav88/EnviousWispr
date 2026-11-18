import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

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
    /// The source the stored page was read from: the source when its read started, or
    /// `storedSourceOverride` when a test needs a page that never matches.
    var storedSource: UInt64?
    var storedSourceOverride: UInt64?
    /// Injected time: `pace` advances it by the duration asked for.
    let origin = ContinuousClock.now
    var elapsed = Duration.zero
    var paces: [Duration] = []
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
        storedSource: { self.storedSource },
        read: { key in
          self.reads.append(key)
          let startSource = self.source
          let succeeded = await withCheckedContinuation { (read: CheckedContinuation<Bool, Never>) in
            if Task.isCancelled { read.resume(returning: false) } else { self.pendingRead = read }
          }
          if succeeded {
            self.stored = key
            self.storedSource = self.storedSourceOverride ?? startSource
          }
        },
        wait: { content, notices in
          // Like the session's `waitForChange`: a counter that already moved returns at once.
          guard self.content == content, self.notices == notices else { return }
          self.waits += 1
          await withCheckedContinuation { (wait: CheckedContinuation<Void, Never>) in
            if Task.isCancelled { wait.resume() } else { self.pendingWait = wait }
          }
        },
        pace: { duration in
          self.paces.append(duration)
          self.elapsed += duration
        },
        now: { self.origin + self.elapsed })
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

  @Test("A source-only burst during one read gives one trailing read after one pace")
  func sourceBurstGivesOneTrailingRead() async throws {
    let world = World()
    let task = Task { await world.loop().run() }
    defer {
      task.cancel()
      world.finishRead(succeeded: false)
      world.wake()
    }
    try await untilReading(world)
    // The source moves three times while the first read runs; its finish notice wakes the loop.
    world.source = 4
    world.notices += 1
    world.finishRead(succeeded: true)
    try await untilReading(world)
    #expect(world.paces == [HistoryRefreshLoop.sourcePace])
    #expect(world.reads.count == 2)
    world.finishRead(succeeded: true)
    try await untilParked(world)
    #expect(world.storedSource == 4)
    #expect(world.reads.count == 2)
    #expect(world.paces.count == 1)
    await stop(task, world)
  }

  @Test("A finish notice that lands during a read wakes the next iteration without parking")
  func noticeDuringReadDoesNotPark() async throws {
    let world = World()
    let task = Task { await world.loop().run() }
    defer {
      task.cancel()
      world.finishRead(succeeded: false)
      world.wake()
    }
    try await untilReading(world)
    world.source = 2
    world.notices += 1
    world.finishRead(succeeded: true)
    try await untilReading(world)
    #expect(world.waits == 0)
    #expect(world.reads.count == 2)
    world.finishRead(succeeded: true)
    try await untilParked(world)
    await stop(task, world)
  }

  @Test("A stamp already attempted with the stored source still differing parks without reading")
  func attemptedStampParks() async throws {
    let world = World()
    world.storedSourceOverride = 0
    let task = Task { await world.loop().run() }
    defer {
      task.cancel()
      world.finishRead(succeeded: false)
      world.wake()
    }
    try await untilReading(world)
    world.finishRead(succeeded: true)
    try await untilParked(world)
    #expect(world.reads.count == 1)
    world.wake()
    try await untilParked(world)
    #expect(world.reads.count == 1)
    #expect(world.paces.isEmpty)
    #expect(world.waits == 2)
    await stop(task, world)
  }

  @Test("Continuous source churn over N pace periods gives at most N+1 source-driven reads")
  func continuousChurnIsPaced() async throws {
    let world = World()
    let task = Task { await world.loop().run() }
    defer {
      task.cancel()
      world.finishRead(succeeded: false)
      world.wake()
    }
    let periods = 6
    try await untilReading(world)
    for _ in 0..<periods {
      // Every read overlaps another source move and its finish notice.
      world.source = (world.source ?? 0) + 1
      world.notices += 1
      world.finishRead(succeeded: true)
      try await untilReading(world)
    }
    #expect(world.reads.count <= world.paces.count + 1)
    #expect(world.paces.count == periods)
    #expect(world.paces.allSatisfy { $0 == HistoryRefreshLoop.sourcePace })
    await stop(task, world)
  }

  @Test("A key change reads at once and never waits for the pace")
  func keyChangeBypassesPace() async throws {
    let world = World()
    let task = Task { await world.loop().run() }
    defer {
      task.cancel()
      world.finishRead(succeeded: false)
      world.wake()
    }
    try await untilReading(world)
    world.finishRead(succeeded: true)
    try await untilParked(world)
    world.content = 1
    world.wake()
    try await untilReading(world)
    #expect(world.paces.isEmpty)
    #expect(world.reads.map(\.revision) == [0, 1])
    world.finishRead(succeeded: true)
    try await untilParked(world)
    await stop(task, world)
  }

  @Test("Two pages with the same rows and different sources are different pages; the place does not move")
  func sameRowsNewSourceIsADifferentPage() throws {
    let world = World()
    let summary = HistoryCatalog.Summary(
      key: .init(tab: .dictations, id: UUID()), date: Date(timeIntervalSinceReferenceDate: 780_000_000),
      preview: "", sources: [])
    let first = try HistoryQueryResult(
      key: world.key(), items: [.catalog(summary)], catalogSourceRevision: 3, catalogDayCounts: [:])
    let second = try HistoryQueryResult(
      key: world.key(), items: [.catalog(summary)], catalogSourceRevision: 4, catalogDayCounts: [:])
    #expect(first.samePage(as: second) == false)
    let context = world.key().context
    let saved = HistoryItemID.transcript(UUID())
    var place = HistoryListPlace()
    let before = place.restore(shownContext: first.key.context, requested: context, saved: saved)
    let after = place.restore(shownContext: second.key.context, requested: context, saved: saved)
    #expect(before != nil)
    #expect(after?.token == before?.token)
  }

  @Test(
    "Finality: a page can page only for its key and the current source, and is final only with day counts",
    arguments: [
      (true, 5 as UInt64?, 5 as UInt64?, true, true, true),
      (true, 5, 5, false, true, false),
      (true, 5, 6, true, false, false),
      (true, 5, nil, true, false, false),
      (false, 5, 5, true, false, false),
    ])
  func finalityCombinations(
    sameKey: Bool, stamp: UInt64?, source: UInt64?, counts: Bool, canPage: Bool, isFinal: Bool
  ) throws {
    let world = World()
    let stored = try HistoryQueryResult(
      key: world.key(), items: [], catalogSourceRevision: stamp, catalogDayCounts: counts ? [:] : nil)
    world.content = sameKey ? 0 : 1
    let result = HistoryPaging.finality(result: stored, key: world.key(), source: source)
    #expect(result.canPage == canPage)
    #expect(result.isFinal == isFinal)
    #expect(HistoryPaging.finality(result: nil, key: world.key(), source: source).canPage == false)
  }

  @Test("An extension slot is released only by the request that owns it")
  func extensionSlotOwnership() {
    var slot = HistoryExtensionSlot()
    let cursor = HistoryCatalog.Cursor(date: Date(timeIntervalSinceReferenceDate: 1), id: UUID())
    let first = slot.claim(cursor)
    #expect(first != nil)
    // A second request cannot claim while the first holds it.
    let blocked = slot.claim(cursor)
    #expect(blocked == nil)
    // A tab switch drops the claim; a new request claims it; the stale owner cannot release it.
    slot.clear()
    let second = slot.claim(cursor)
    #expect(second != nil)
    let staleRelease = slot.release(first!)
    #expect(staleRelease == false)
    #expect(slot.isClaimed)
    let ownerRelease = slot.release(second!)
    #expect(ownerRelease)
    #expect(slot.isClaimed == false)
    let again = slot.release(second!)
    #expect(again == false)
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

