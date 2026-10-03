import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3385: each chime card's Preview plays THAT card's start cue, waits, and plays the same
/// card's stop cue. **When this fails, a preview plays the wrong chime, plays half a chime
/// into a real recording, or leaves a stale stop cue armed after the user moved on.**
///
/// Drives the production `RecordingChimePreview.start` with a cue spy and a gated gap: no
/// sound plays and nothing waits 550ms. The gap gate records the request and parks the
/// continuation in one MainActor step, so "arrived" always means "releasable".
@MainActor
@Suite("Recording chime preview (#3385)", .tags(.productOutcome))
struct RecordingChimePreviewTests {

  /// Records every cue the preview asks for; `startSucceeds` models a missing asset.
  @MainActor final class CueSpy {
    var played: [String] = []
    var startSucceeds = true
    func play(_ pairing: RecordingSoundPairing, _ moment: RecordingSoundMoment) -> Bool {
      played.append("\(pairing.rawValue).\(moment.rawValue)")
      return moment == .start ? startSucceeds : true
    }
  }

  /// The gap. Each `wait` records its duration and parks in the same synchronous step.
  @MainActor final class GapGate {
    private(set) var requested: [Duration] = []
    private var parked: [CheckedContinuation<Void, Error>] = []
    private var arrivalWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var isClosed = false
    var parkedCount: Int { parked.count }
    var waiterCount: Int { arrivalWaiters.count }

    func wait(_ duration: Duration) async throws {
      guard isClosed == false else { throw CancellationError() }
      try await withCheckedThrowingContinuation { continuation in
        requested.append(duration)
        parked.append(continuation)
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(returning: true) }
      }
    }

    /// True once `count` waits are parked; false if the deadline passes first. The deadline
    /// task is handed to `owned` so cleanup cancels it.
    func arrived(_ count: Int = 1, within deadline: Duration = .seconds(2), owned: Owned) async -> Bool {
      while parked.count < count {
        guard isClosed == false else { return false }
        let id = UUID()
        let arrived = await withCheckedContinuation { continuation in
          arrivalWaiters[id] = continuation
          owned.add(
            Task { @MainActor in
              try? await Task.sleep(for: deadline)  // deadline-fallback: bounds a wait for the gate's arrival signal
              self.arrivalWaiters.removeValue(forKey: id)?.resume(returning: false)
            })
        }
        if !arrived { return false }
      }
      return true
    }

    /// Ends the gate: every parked wait throws, every arrival waiter gives up, and any later
    /// wait throws at once.
    func close() {
      isClosed = true
      fail()
      let waiters = arrivalWaiters
      arrivalWaiters.removeAll()
      for waiter in waiters.values { waiter.resume(returning: false) }
    }

    /// Lets every parked wait return normally.
    func release() {
      let waiting = parked
      parked.removeAll()
      for continuation in waiting { continuation.resume() }
    }

    /// Makes every parked wait throw, as a cancelled sleep does.
    func fail() {
      let waiting = parked
      parked.removeAll()
      for continuation in waiting { continuation.resume(throwing: CancellationError()) }
    }
  }

  @MainActor final class Activity {
    var isActive = false
  }

  /// Every task the fixture starts (previews, completion observers, deadline timers), so
  /// cleanup can cancel all of them whatever a test's outcome.
  @MainActor final class Owned {
    private(set) var tasks: [Task<Void, Never>] = []
    func add(_ task: Task<Void, Never>) { tasks.append(task) }
  }

  let spy = CueSpy()
  let gate = GapGate()
  let activity = Activity()
  let owned = Owned()

  /// Run by every test through `defer`: closes the gate (parked waits throw, waiters give
  /// up, later waits refuse) and cancels every owned task, so a failing test leaves nothing
  /// suspended behind it.
  func cleanUp() {
    gate.close()
    for task in owned.tasks { task.cancel() }
  }

  func start(_ pairing: RecordingSoundPairing, replacing previous: Task<Void, Never>? = nil)
    -> Task<Void, Never>
  {
    let spy = spy
    let gate = gate
    let activity = activity
    let task = RecordingChimePreview.start(
      pairing: pairing, replacing: previous,
      isDictationActive: { activity.isActive },
      play: { spy.play($0, $1) },
      wait: { try await gate.wait($0) })
    owned.add(task)
    return task
  }

  /// True when `task` finished before the deadline. The gate is released or failed first
  /// by every caller, so a false here is the subject hanging, not the fixture.
  func finished(_ task: Task<Void, Never>, within deadline: Duration = .seconds(2)) async -> Bool {
    await withCheckedContinuation { continuation in
      let box = OnceBox(continuation)
      owned.add(
        Task { @MainActor in
          await task.value
          box.resume(true)
        })
      owned.add(
        Task { @MainActor in
          try? await Task.sleep(for: deadline)  // deadline-fallback: bounds the wait for the preview task to finish
          box.resume(false)
        })
    }
  }

  @MainActor final class OnceBox {
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func resume(_ value: Bool) {
      continuation?.resume(returning: value)
      continuation = nil
    }
  }

  @Test("a card's Preview plays that card's start and stop, 550ms apart")
  func playsTheRequestedPairing() async {
    defer { cleanUp() }
    // Not the default selection: the helper never reads the selection at all.
    let task = start(.airGlint)
    #expect(await gate.arrived(owned: owned))
    #expect(spy.played == ["airGlint.start"])
    #expect(gate.requested == [.milliseconds(550)])
    gate.release()
    #expect(await finished(task))
    #expect(spy.played == ["airGlint.start", "airGlint.stop"])
  }

  @Test("a preview cancelled before its task runs plays nothing")
  func cancelledBeforeStart() async {
    defer { cleanUp() }
    let task = start(.dustMote)
    task.cancel()
    #expect(await finished(task))
    #expect(spy.played.isEmpty)
    #expect(gate.requested.isEmpty)
  }

  @Test("a preview cancelled during the gap plays no stop")
  func cancelledDuringTheGap() async {
    defer { cleanUp() }
    let task = start(.paperTap)
    #expect(await gate.arrived(owned: owned))
    task.cancel()
    // The gap returns normally (a wait that ignores cancellation); the post-gap guard stops it.
    gate.release()
    #expect(await finished(task))
    #expect(spy.played == ["paperTap.start"])
  }

  @Test("a new preview cancels the old one, so the old stop never plays")
  func supersedingPreviewSuppressesTheOldStop() async {
    defer { cleanUp() }
    let first = start(.lowNod)
    #expect(await gate.arrived(owned: owned))
    let second = start(.cloudPop, replacing: first)
    #expect(await gate.arrived(2, owned: owned))
    gate.release()
    #expect(await finished(first))
    #expect(await finished(second))
    #expect(spy.played == ["lowNod.start", "cloudPop.start", "cloudPop.stop"])
  }

  @Test("an active recording blocks the start cue")
  func dictationBlocksStart() async {
    defer { cleanUp() }
    activity.isActive = true
    let task = start(.softHush)
    #expect(await finished(task))
    #expect(spy.played.isEmpty)
    #expect(gate.requested.isEmpty)
  }

  @Test("a recording that begins during the gap blocks the stop cue")
  func dictationDuringTheGapBlocksStop() async {
    defer { cleanUp() }
    let task = start(.satinShift)
    #expect(await gate.arrived(owned: owned))
    activity.isActive = true
    gate.release()
    #expect(await finished(task))
    #expect(spy.played == ["satinShift.start"])
  }

  @Test("a start cue that could not play skips the wait and the stop")
  func failedStartStops() async {
    defer { cleanUp() }
    spy.startSucceeds = false
    let task = start(.velvetTap)
    #expect(await finished(task))
    #expect(spy.played == ["velvetTap.start"])
    #expect(gate.requested.isEmpty)
  }

  @Test("a gap that throws plays no stop")
  func thrownWaitStops() async {
    defer { cleanUp() }
    let task = start(.roundPebble)
    #expect(await gate.arrived(owned: owned))
    gate.fail()
    #expect(await finished(task))
    #expect(spy.played == ["roundPebble.start"])
  }

  @Test("a preview that never finishes times out, and cleanup leaves nothing parked")
  func completionDeadlineAndCleanupControl() async {
    defer { cleanUp() }
    let task = start(.mutedConfirm)
    #expect(await gate.arrived(owned: owned))
    // Nobody releases the gap: the completion wait must give up, not hang.
    #expect(await finished(task, within: .milliseconds(50)) == false)
    cleanUp()
    #expect(gate.parkedCount == 0 && gate.waiterCount == 0, "cleanup left a parked wait")
    let allCancelled = owned.tasks.allSatisfy { $0.isCancelled }
    #expect(allCancelled, "cleanup left an owned task running")
    // The closed gate threw, so the preview ends without its stop half.
    #expect(await finished(task))
    #expect(spy.played == ["mutedConfirm.start"])
    do {
      try await gate.wait(.zero)
      Issue.record("a closed gate accepted a wait")
    } catch {
      #expect(error is CancellationError)
    }
  }

  @Test("the arrival wait gives up when nothing arrives")
  func arrivalDeadlineControl() async {
    defer { cleanUp() }
    #expect(await gate.arrived(within: .milliseconds(50), owned: owned) == false)
  }
}
