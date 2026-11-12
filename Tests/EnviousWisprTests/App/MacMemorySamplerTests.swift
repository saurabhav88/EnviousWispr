import EnviousWisprCore
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit

/// #4525 §3.2: the live "memory in use" figure on the EG-1 size cards. When this fails, the bar's
/// gray part shows a stale or wrong figure, keeps redrawing on a quiet Mac, or keeps reading
/// memory while the window is hidden.
@MainActor
@Suite("MacMemorySampler: reads every 2 s while visible, publishes only shown changes (#4525)",
  .tags(.productOutcome))
struct MacMemorySamplerTests {
  @MainActor final class Rig {
    var value: UInt64? = 10 << 30
    var visible = true
    var reads = 0
    lazy var sampler = MacMemorySampler(
      read: { [unowned self] in
        self.reads += 1
        return self.value
      },
      isVisible: { [unowned self] in self.visible })
  }

  private static let gib = Double(1 << 30)
  private static func bytes(gib value: Double) -> UInt64 { UInt64(value * gib) }

  @Test("the first visible tick reads and publishes")
  func firstTickPublishes() {
    let rig = Rig()
    rig.sampler.tick()
    #expect(rig.reads == 1)
    #expect(rig.sampler.usedBytes == 10 << 30)
  }

  @Test("a move inside the shown 0.1 GB keeps the published value; a move past it publishes")
  func publishesOnlyShownChanges() {
    let rig = Rig()
    rig.sampler.tick()
    rig.value = Self.bytes(gib: 10.04)
    rig.sampler.tick()
    #expect(rig.sampler.usedBytes == 10 << 30)
    rig.value = Self.bytes(gib: 10.06)
    rig.sampler.tick()
    #expect(rig.sampler.usedBytes == Self.bytes(gib: 10.06))
  }

  /// Counts the sampler's observable publications of `usedBytes` during one tick, with the
  /// Observation framework's own change signal.
  private static func publications(of sampler: MacMemorySampler, during tick: () -> Void) -> Int {
    final class Count: @unchecked Sendable {
      // Written only by onChange, which fires synchronously inside `tick` on this actor.
      var value = 0
    }
    let count = Count()
    withObservationTracking {
      _ = sampler.usedBytes
    } onChange: {
      count.value += 1
    }
    tick()
    return count.value
  }

  @Test("repeated failed reads publish once; the next good read publishes once")
  func failureAndRecovery() {
    let rig = Rig()
    let values: [UInt64?] = [10 << 30, nil, nil, nil, 12 << 30]
    var published: [Int] = []
    for value in values {
      rig.value = value
      published.append(Self.publications(of: rig.sampler) { rig.sampler.tick() })
    }
    #expect(published == [1, 1, 0, 0, 1])
    #expect(rig.sampler.usedBytes == 12 << 30)
  }

  @Test("a hidden window skips the read; the first visible tick reads again")
  func hiddenSkipsRead() {
    let rig = Rig()
    rig.visible = false
    rig.sampler.tick()
    #expect(rig.reads == 0)
    #expect(rig.sampler.usedBytes == nil)
    rig.visible = true
    rig.sampler.tick()
    #expect(rig.reads == 1)
    #expect(rig.sampler.usedBytes == 10 << 30)
  }

  @Test("run reads at once and once per 2 s wait; cancelling the task ends it with no more reads")
  func runLoopCadenceAndCancellation() async throws {
    final class Waits: @unchecked Sendable {
      // Appended only from the sampler's main-actor loop, one call at a time.
      var durations: [Duration] = []
    }
    let waits = Waits()
    // Each wait reports its start; the second never ends on its own, only by cancellation.
    let (entered, enteredContinuation) = AsyncStream<Int>.makeStream()
    let (forever, foreverContinuation) = AsyncStream<Void>.makeStream()
    var reads = 0
    let sampler = MacMemorySampler(
      read: {
        reads += 1
        return 1 << 30
      },
      isVisible: { true },
      sleep: { duration in
        waits.durations.append(duration)
        enteredContinuation.yield(waits.durations.count)
        guard waits.durations.count >= 2 else { return }
        for await _ in forever {}
        _ = foreverContinuation  // keeps the stream open until the task is cancelled
        try Task.checkCancellation()
      })
    // Reports after `run()` has returned, from the task itself.
    let (finished, finishedContinuation) = AsyncStream<Void>.makeStream()
    let task = Task {
      await sampler.run()
      finishedContinuation.yield()
    }
    defer { task.cancel() }
    // deadline-fallback: the waits finish on the subject's own signals; 5 s only turns a missing
    // signal into a focused failure instead of a hung test.
    let order = try await withThrowingTimeout(seconds: 5) {
      var signals = entered.makeAsyncIterator()
      return [await signals.next(), await signals.next()]
    }
    #expect(order == [1, 2])
    #expect(reads == 2)
    task.cancel()
    // deadline-fallback: as above; a stream wait ends when the timeout cancels it, so a loop that
    // never returns fails here instead of hanging.
    let ended = try await withThrowingTimeout(seconds: 5) {
      for await _ in finished { return true }
      return false
    }
    #expect(ended)
    #expect(reads == 2)
    #expect(waits.durations == [.seconds(2), .seconds(2)])
  }
}
