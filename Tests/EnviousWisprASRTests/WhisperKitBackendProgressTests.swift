import Foundation
import Testing

@testable import EnviousWisprASR

/// #2918 / #2952 — the transcribing bar's number is the kit's own Foundation `Progress`
/// (one child per decode window, total = window count), folded through ONE monotone
/// high-water mark whose reports are made under its lock. It advances when a window
/// completes whether or not it held speech, and it never moves backwards, even when two
/// windows complete on two threads at once.
///
/// **When this fails, the Working card's transcribing bar jumps backwards, stalls on a
/// silent stretch, or starts part-way along after an earlier failed call.** Product coverage.
@Suite(.tags(.productOutcome))
struct WhisperKitBackendProgressTests {

  @Test("four one-unit children (the kit's chunked shape) report 0.25, 0.5, 0.75, 1 as each completes")
  func childrenCompletingRaiseTheParent() {
    let parent = Progress(totalUnitCount: 4)
    let box = ReportedFractions()
    let token = WhisperKitBackend.observeEngineProgress(
      parent, highWater: WhisperKitBackend.ProgressHighWater()) { box.append($0) }
    defer { token.invalidate() }
    for _ in 0..<4 {
      let child = Progress(totalUnitCount: 1)
      parent.addChild(child, withPendingUnitCount: 1)
      child.completedUnitCount = 1
    }
    #expect(box.values == [0.25, 0.5, 0.75, 1.0])
  }

  @Test("one child advancing through quarters (the single-window shape) moves the fraction before the window completes")
  func withinWindowMovement() {
    let parent = Progress(totalUnitCount: 1)
    let child = Progress(totalUnitCount: 4)
    parent.addChild(child, withPendingUnitCount: 1)
    let box = ReportedFractions()
    let token = WhisperKitBackend.observeEngineProgress(
      parent, highWater: WhisperKitBackend.ProgressHighWater()) { box.append($0) }
    defer { token.invalidate() }
    child.completedUnitCount = 1
    child.completedUnitCount = 2
    #expect(box.values == [0.25, 0.5])
  }

  @Test("a silent window completing still advances the bar: completion is the signal, not speech")
  func silentWindowAdvances() {
    // Two windows; the second holds no speech. Nothing but `completedUnitCount` moves.
    let parent = Progress(totalUnitCount: 2)
    let box = ReportedFractions()
    let token = WhisperKitBackend.observeEngineProgress(
      parent, highWater: WhisperKitBackend.ProgressHighWater()) { box.append($0) }
    defer { token.invalidate() }
    for _ in 0..<2 {
      let window = Progress(totalUnitCount: 1)
      parent.addChild(window, withPendingUnitCount: 1)
      window.completedUnitCount = 1
    }
    #expect(box.values == [0.5, 1.0])
  }

  @Test("windows completing on many threads at once never deliver a report out of order")
  func concurrentCompletionsReportInOrder() {
    // 16 windows (the kit's parallel worker count) complete from 16 threads. The parent's
    // fraction only ever rises, and because the report is made under the high-water lock,
    // the DELIVERED sequence must be strictly ascending too: the race this guards is a
    // raise on one thread reported after a higher raise on another.
    let parent = Progress(totalUnitCount: 16)
    let children = (0..<16).map { _ -> Progress in
      let child = Progress(totalUnitCount: 1)
      parent.addChild(child, withPendingUnitCount: 1)
      return child
    }
    let box = ReportedFractions()
    let token = WhisperKitBackend.observeEngineProgress(
      parent, highWater: WhisperKitBackend.ProgressHighWater()) { box.append($0) }
    defer { token.invalidate() }
    DispatchQueue.concurrentPerform(iterations: 16) { i in children[i].completedUnitCount = 1 }
    let values = box.values
    #expect(values.last == 1.0)
    #expect(values == values.sorted(), "\(values)")
    #expect(Set(values).count == values.count, "\(values)")
  }

  @Test("a used Progress (a call that threw) is not fresh; an untouched one is")
  func staleProgressIsRefused() {
    let fresh = Progress()
    #expect(WhisperKitBackend.isFreshProgress(fresh))
    let usedTotal = Progress(totalUnitCount: 3)
    #expect(!WhisperKitBackend.isFreshProgress(usedTotal))
    let usedCompleted = Progress(totalUnitCount: 3)
    let child = Progress(totalUnitCount: 1)
    usedCompleted.addChild(child, withPendingUnitCount: 1)
    child.completedUnitCount = 1
    #expect(!WhisperKitBackend.isFreshProgress(usedCompleted))
  }

  @Test("a Progress that goes backwards (a child's completed count lowered) is never reported backwards")
  func neverReportedBackwards() {
    // Foundation lets `completedUnitCount` decrease and the parent's fraction follows; the
    // high-water mark must swallow it. Deterministic twin of the concurrent case above.
    let parent = Progress(totalUnitCount: 1)
    let child = Progress(totalUnitCount: 4)
    parent.addChild(child, withPendingUnitCount: 1)
    let box = ReportedFractions()
    let token = WhisperKitBackend.observeEngineProgress(
      parent, highWater: WhisperKitBackend.ProgressHighWater()) { box.append($0) }
    defer { token.invalidate() }
    child.completedUnitCount = 2
    child.completedUnitCount = 1
    child.completedUnitCount = 3
    #expect(box.values == [0.5, 0.75])
  }

  @Test("after invalidate, a further completion reports nothing, synchronously")
  func invalidationStopsReports() {
    let parent = Progress(totalUnitCount: 2)
    let box = ReportedFractions()
    let token = WhisperKitBackend.observeEngineProgress(
      parent, highWater: WhisperKitBackend.ProgressHighWater()) { box.append($0) }
    let first = Progress(totalUnitCount: 1)
    parent.addChild(first, withPendingUnitCount: 1)
    first.completedUnitCount = 1
    #expect(box.values == [0.5])
    token.invalidate()
    let second = Progress(totalUnitCount: 1)
    parent.addChild(second, withPendingUnitCount: 1)
    second.completedUnitCount = 1
    #expect(box.values == [0.5])
  }

  /// KVO delivers on the mutating thread; a locked box keeps the collector `Sendable`
  /// without any wait.
  private final class ReportedFractions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) {
      lock.lock()
      defer { lock.unlock() }
      stored.append(value)
    }
    var values: [Double] {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
  }
}
