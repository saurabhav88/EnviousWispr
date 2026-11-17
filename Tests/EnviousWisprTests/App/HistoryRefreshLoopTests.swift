import EnviousWisprCore
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

    func key() -> TranscriptCoordinator.HistoryQueryKey {
      .init(
        revision: Int(content), pulse: 0,
        context: .init(tab: .dictations, query: "", filter: .none), echoShown: [], locale: "", localizations: [], calendar: .current)
    }

    func loop() -> HistoryRefreshLoop {
      HistoryRefreshLoop(
        counters: { .init(content: self.content, notices: self.notices, source: self.source) },
        currentKey: { self.key() },
        storedKey: { self.stored },
        read: { key in
          self.reads.append(key)
          let succeeded = await withCheckedContinuation { self.pendingRead = $0 }
          if succeeded { self.stored = key }
        },
        wait: { content, notices in
          // Like the session's `waitForChange`: a counter that already moved returns at once.
          guard self.content == content, self.notices == notices else { return }
          self.waits += 1
          await withCheckedContinuation { self.pendingWait = $0 }
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
  private func untilReading(_ world: World) async {
    while world.pendingRead == nil { await Task.yield() }
  }

  private func untilParked(_ world: World) async {
    while world.pendingWait == nil { await Task.yield() }
  }

  @Test("A read overtaken by a content publish is kept, then the newer content is read")
  func overtakenReadIsKept() async {
    let world = World()
    let task = Task { await world.loop().run() }
    await untilReading(world)
    world.content = 1
    world.finishRead(succeeded: true)
    await untilReading(world)
    // The overtaken read was stored, and the newer content was read next without a wait.
    #expect(world.stored?.revision == 0)
    #expect(world.reads.map(\.revision) == [0, 1])
    #expect(world.waits == 0)
    world.finishRead(succeeded: true)
    await untilParked(world)
    #expect(world.stored?.revision == 1)
    task.cancel()
    world.wake()
    await task.value
  }

  @Test("An empty read is retried on the next notice and parks when nothing changed")
  func emptyReadRetriesOnNotice() async {
    let world = World()
    let task = Task { await world.loop().run() }
    await untilReading(world)
    world.finishRead(succeeded: false)
    await untilParked(world)
    #expect(world.reads.count == 1)
    // A wake with nothing changed does not read again.
    world.wake()
    await untilParked(world)
    #expect(world.reads.count == 1)
    // A change notice with the same content retries the same key once.
    world.notices += 1
    world.wake()
    await untilReading(world)
    #expect(world.reads.count == 2)
    #expect(world.reads[1] == world.reads[0])
    world.finishRead(succeeded: true)
    await untilParked(world)
    task.cancel()
    world.wake()
    await task.value
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
}
