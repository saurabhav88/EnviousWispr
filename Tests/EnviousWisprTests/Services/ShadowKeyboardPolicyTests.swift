import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing
import os

/// #3544 P2: the keyboard listener's shadow decisions.
///
/// Product Outcome: these are the decisions the listener will act on from P3. When this fails, the
/// shadow comparison would approve a listener that locks, stops or credits a press differently
/// from today's record key.
@Suite(.tags(.productOutcome), .timeLimit(.minutes(1)))
struct ShadowKeyboardPolicyTests {

  private static let optionDown: UInt64 = 0x80000 | 0x40  // Right Option, side bit
  private static let rightCommandDown: UInt64 = 0x100000 | 0x10

  private final class Rig: Sendable {
    let clock = HotkeyTestClock(500)
    let timers: HotkeyTestScheduler
    let policy: ShadowKeyboardPolicy
    private let collected = OSAllocatedUnfairLock<[ShadowRecord]>(initialState: [])

    init(
      snapshot: ShadowKeyboardPolicy.Snapshot = Rig.pushToTalk,
      scheduler: RecordGestureEngine.Scheduler? = nil
    ) {
      timers = HotkeyTestScheduler(clock: clock)
      let collected = self.collected
      policy = ShadowKeyboardPolicy(
        snapshot: snapshot, clock: clock.uptime, scheduler: scheduler ?? timers.scheduler,
        emit: { record in collected.withLock { $0.append(record) } })
    }

    static let pushToTalk = ShadowKeyboardPolicy.Snapshot(
      generation: 1, bindings: .shipped, mode: .pushToTalk, enabled: true, suspended: false,
      armed: [.record, .quickAdd, .pasteLast, .copyLast],
      available: [.quickAdd, .pasteLast, .copyLast])

    var records: [ShadowRecord] { collected.withLock { $0 } }
    /// Decision and timer outcomes, in emission order.
    var decisions: [String] {
      records.filter { $0.category != .ingress }.map { r in
        switch r.outcome {
        case .gesture(let g): return "\(g)"
        default: return "\(r.role.map { "\($0)" } ?? "none") \(r.outcome)"
        }
      }
    }

    func key(_ code: UInt16, _ flags: UInt64, at t: TimeInterval) {
      clock.now = 500 + t
      policy.ingest(
        KeyEventValue(kind: .flagsChanged, keyCode: code, rawFlags: flags, timestamp: 500 + t),
        handled: 500 + t)
    }
    func press(at t: TimeInterval) { key(61, ShadowKeyboardPolicyTests.optionDown, at: t) }
    func release(at t: TimeInterval) { key(61, 0, at: t) }
  }

  /// Run `work` on a worker thread and wait for that worker (bounded), never for main.
  private static func offMain(_ work: @escaping @Sendable () -> Void) {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInteractive).async {
      work()
      done.signal()
    }
    // deadline-fallback: bound the worker's own completion signal so a regression fails, not hangs.
    #expect(done.wait(timeout: .now() + 5) == .success)
  }

  @Test("a fast double tap locks through the same gesture policy and retires the lone-tap wait")
  func doubleTapLocks() {
    let rig = Rig()
    rig.press(at: 0)
    rig.release(at: 0.125)
    rig.press(at: 0.25)
    #expect(rig.decisions == ["start", "quickRelease", "lockIntent", "loneTapCancelled"])
    #expect(rig.timers.pendingCount == 0)
  }

  @Test("a lone tap stops when its wait fires on a worker, with no main thread involved")
  func loneTapStopsOffMain() {
    let rig = Rig()
    rig.press(at: 0)
    rig.release(at: 0.125)
    #expect(rig.timers.requestedDeadlines == [500.625])
    let timers = rig.timers
    let clock = rig.clock
    Self.offMain {
      clock.now = 500.625
      timers.fireDue()
    }
    #expect(rig.decisions == ["start", "quickRelease", "loneTapStop"])
    let timer = rig.records.last
    #expect(timer?.category == .timer)
    #expect(timer?.acceptedOccurred == 500.125)
    #expect(timer?.attemptStartOccurred == 500.0)
  }

  @Test("a replaced wait that fires anyway decides nothing")
  func replacedWaitIsIgnored() {
    let fires = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])
    let rig = Rig(scheduler: { _, fire in
      fires.withLock { $0.append(fire) }
      return RecordGestureEngine.TimerHandle(cancel: {})
    })
    rig.press(at: 0)
    rig.release(at: 0.125)
    rig.press(at: 0.25)
    let before = rig.records.count
    rig.clock.now = 501
    fires.withLock { $0 }.first?()
    #expect(rig.records.count == before)
  }

  @Test("a release follows the role its press was admitted for, even after a rebind")
  func releaseFollowsAdmittedOwner() {
    let rig = Rig()
    rig.press(at: 0)
    var rebound = Rig.pushToTalk
    rebound.generation = 2
    rebound.bindings.record = .keyboard(keyCode: ModifierKeyCodes.leftOption, modifiers: [])
    rig.policy.configure(rebound)
    rig.release(at: 0.75)
    #expect(rig.decisions == ["start", "holdStop"])
    #expect(rig.records.last?.role == .record)
    #expect(rig.records.last?.generation == 2)
  }

  @Test("cancel's press consumes its key, and its release is a consumed tail")
  func cancelReleaseIsConsumedTail() {
    var snapshot = Rig.pushToTalk
    snapshot.bindings.cancel = .keyboard(keyCode: ModifierKeyCodes.rightCommand, modifiers: [])
    snapshot.armed.insert(.cancel)
    let rig = Rig(snapshot: snapshot)
    rig.key(54, Self.rightCommandDown, at: 0)
    rig.key(54, 0, at: 0.1)
    #expect(rig.decisions == ["cancel rolePress", "cancel consumedTail"])
  }

  @Test("Paste Last predicts its press and its release; nothing executes")
  func pasteLastPredictsBothEdges() {
    var snapshot = Rig.pushToTalk
    snapshot.bindings.pasteLast = .keyboard(keyCode: ModifierKeyCodes.rightCommand, modifiers: [])
    let rig = Rig(snapshot: snapshot)
    rig.key(54, Self.rightCommandDown, at: 0)
    rig.key(54, 0, at: 0.1)
    #expect(rig.decisions == ["pasteLast rolePress", "pasteLast roleRelease"])
  }

  @Test("a disabled or suspended snapshot decides nothing and starts no wait")
  func disabledAndSuspendedDecideNothing() {
    for (enabled, suspended) in [(false, false), (true, true)] {
      var snapshot = Rig.pushToTalk
      snapshot.enabled = enabled
      snapshot.suspended = suspended
      let rig = Rig(snapshot: snapshot)
      rig.press(at: 0)
      rig.release(at: 0.125)
      #expect(rig.decisions == ["record noDecision", "record noDecision"])
      #expect(rig.timers.pendingCount == 0)
    }
  }

  @Test("toggle mode predicts a press and runs no push-to-talk gesture")
  func toggleModeIsAPressOnly() {
    var snapshot = Rig.pushToTalk
    snapshot.mode = .toggle
    let rig = Rig(snapshot: snapshot)
    rig.press(at: 0)
    rig.release(at: 0.125)
    #expect(rig.decisions == ["record rolePress", "record noDecision"])
    #expect(rig.timers.pendingCount == 0)
  }

  @Test("refusing an attempt retires only that attempt's wait")
  func refusalRetiresOnlyItsAttempt() {
    let rig = Rig()
    rig.press(at: 0)
    rig.release(at: 0.125)
    rig.policy.refuse(attempt: 99)
    #expect(rig.timers.pendingCount == 1)
    rig.policy.refuse(attempt: 1)
    #expect(rig.timers.pendingCount == 0)
    #expect(rig.decisions.last == "loneTapRetired")
    // The physical hold was already released; a new press starts a fresh attempt.
    rig.press(at: 1)
    #expect(rig.decisions.last == "start")
  }

  @Test("an unproven synthetic release is recorded as ambiguous, never as a decision")
  func ambiguousReleaseIsRecorded() {
    let rig = Rig()
    rig.key(58, 0x80000, at: 0)  // Left Option, no side bits
    rig.key(61, 0x80000, at: 0.1)  // Right Option, no side bits
    rig.key(61, 0x80000, at: 0.2)  // could be Right Option's release
    let last = rig.records.suffix(2)
    #expect(last.count == 2)
    #expect(last.allSatisfy { $0.ambiguous && $0.outcome == .noDecision && $0.keyCode == 61 })
  }

  @Test("cancel during a pending wait ends the attempt and retires its wait")
  func cancelRetiresPendingWait() {
    var snapshot = Rig.pushToTalk
    snapshot.bindings.cancel = .keyboard(keyCode: ModifierKeyCodes.rightCommand, modifiers: [])
    snapshot.armed.insert(.cancel)
    let rig = Rig(snapshot: snapshot)
    rig.press(at: 0)
    rig.release(at: 0.125)
    rig.key(54, Self.rightCommandDown, at: 0.2)
    #expect(rig.decisions == ["start", "quickRelease", "loneTapRetired", "cancel rolePress"])
    #expect(rig.timers.pendingCount == 0)
    // The next record press starts fresh: the cancelled attempt is gone.
    rig.press(at: 0.3)
    #expect(rig.decisions.last == "start")
  }

  @Test("a consumed cancel key stays a consumed tail until its family flag drops")
  func consumedTailLastsUntilTheFlagDrops() {
    var snapshot = Rig.pushToTalk
    snapshot.bindings.cancel = .keyboard(keyCode: ModifierKeyCodes.rightCommand, modifiers: [])
    snapshot.armed.insert(.cancel)
    let rig = Rig(snapshot: snapshot)
    rig.key(55, 0x100000 | 0x8, at: 0)  // Left Command held (no role)
    rig.key(54, 0x100000 | 0x8 | 0x10, at: 0.1)  // Right Command: cancel, consumed
    rig.key(54, 0x100000 | 0x8, at: 0.2)  // released, Left still holds the flag
    rig.key(54, 0x100000 | 0x8 | 0x10, at: 0.3)  // pressed again before the flag drops
    rig.key(54, 0x100000 | 0x8, at: 0.4)
    #expect(
      rig.decisions == [
        "none noDecision", "cancel rolePress", "cancel consumedTail", "cancel consumedTail",
        "cancel consumedTail",
      ])
    rig.key(55, 0, at: 0.5)  // the flag drops
    rig.policy.configure(snapshot)  // the owner re-arms cancel
    rig.key(54, 0x100000 | 0x10, at: 0.6)
    #expect(rig.decisions.last == "cancel rolePress")
  }

  @Test("a reconciliation answer read before a release and re-press never ends the new hold")
  func staleReconciliationIsDropped() {
    let rig = Rig()
    rig.press(at: 0)
    let policy = rig.policy
    policy.reconcile(handled: 500.5) { keys in
      // While the reader runs, the key is released and pressed again.
      rig.release(at: 0.2)
      rig.press(at: 0.3)
      return Dictionary(uniqueKeysWithValues: keys.map { ($0, KeyStateTracker.Reading.up) })
    }
    #expect(rig.records.allSatisfy { $0.evidence != .reconciled })
    // A fresh read applies.
    policy.reconcile(handled: 501) { keys in
      Dictionary(uniqueKeysWithValues: keys.map { ($0, KeyStateTracker.Reading.up) })
    }
    #expect(rig.records.contains { $0.evidence == .reconciled && $0.phase == .release })
  }
}
