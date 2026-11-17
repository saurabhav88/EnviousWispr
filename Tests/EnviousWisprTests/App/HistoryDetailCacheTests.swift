import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Observation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// #4586 H2/N5: History keeps hydrated rows in one cache whose entries are observed one by one,
/// so a card redraws only when its own row arrives or leaves, and a row an open screen holds is
/// never dropped under it.
@MainActor
@Suite(
  "History detail cache tells only the card whose row changed", .tags(.productOutcome),
  .timeLimit(.minutes(1)))
struct HistoryDetailCacheTests {
  private final class Flag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var fired: Bool { state.withLock { $0 } }
    func fire() { state.withLock { $0 = true } }
  }

  private func watch(_ entry: HistoryDetailCache.Entry) -> Flag {
    let flag = Flag()
    withObservationTracking {
      _ = entry.row
    } onChange: {
      flag.fire()
    }
    return flag
  }

  private func row(_ text: String) -> Transcript { Transcript(text: text) }

  @Test("Hydrating one row does not redraw a card showing another")
  func perEntryObservation() {
    let cache = HistoryDetailCache(keeps: { _ in false })
    let a = UUID()
    let b = UUID()
    let flag = watch(cache.entry(a))
    cache.store(b, row: row("b"), proof: [], version: 1)
    #expect(flag.fired == false)
    cache.store(a, row: row("a"), proof: [], version: 1)
    #expect(flag.fired)
  }

  @Test("Eviction empties the oldest unheld row, keeps its entry and tells its readers")
  func evictionKeepsIdentity() {
    let cache = HistoryDetailCache(limit: 2, keeps: { _ in false })
    let ids = [UUID(), UUID(), UUID()]
    let first = cache.entry(ids[0])
    cache.store(ids[0], row: row("0"), proof: [], version: 1)
    let flag = watch(first)
    cache.store(ids[1], row: row("1"), proof: [], version: 1)
    cache.store(ids[2], row: row("2"), proof: [], version: 1)
    #expect(flag.fired)
    #expect(cache.entry(ids[0]) === first)
    #expect(first.row == nil)
    #expect(cache.payloadCountForTesting() == 2)
  }

  @Test("Held and kept rows survive eviction; clearing keeps the hold")
  func heldAndKeptRowsStay() {
    let kept = UUID()
    let held = UUID()
    let other = UUID()
    let cache = HistoryDetailCache(limit: 1, keeps: { $0 == kept })
    cache.acquire(held)
    cache.store(kept, row: row("kept"), proof: [], version: 1)
    cache.store(held, row: row("held"), proof: [], version: 1)
    cache.store(other, row: row("other"), proof: [], version: 1)
    #expect(cache.entry(kept).row?.text == "kept")
    #expect(cache.entry(held).row?.text == "held")
    #expect(cache.entry(other).row == nil)
    cache.clear(held)
    #expect(cache.entry(held).row == nil)
    #expect(cache.entry(held).holds == 1)
    cache.release(held)
    #expect(cache.entry(held).holds == 0)
  }

  @Test("A hold ends exactly once when its view goes away, before or after it started waiting")
  func holdReleasedOnCancellation() async throws {
    let root = TestTemporaryDirectory.url.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: root))
    let id = UUID()

    let waiting = Task { await coordinator.holdCatalogDetail(id) }
    // The subject's own signal: the hold is counted once the task has started holding.
    while coordinator.catalogDetailHoldCountForTesting(id) == 0 { await Task.yield() }
    let second = Task { await coordinator.holdCatalogDetail(id) }
    while coordinator.catalogDetailHoldCountForTesting(id) < 2 { await Task.yield() }
    waiting.cancel()
    await waiting.value
    #expect(coordinator.catalogDetailHoldCountForTesting(id) == 1)
    second.cancel()
    await second.value
    #expect(coordinator.catalogDetailHoldCountForTesting(id) == 0)

    let early = Task { await coordinator.holdCatalogDetail(id) }
    early.cancel()
    await early.value
    #expect(coordinator.catalogDetailHoldCountForTesting(id) == 0)
  }
}
