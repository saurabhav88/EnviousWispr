import EnviousWisprCore
import Foundation
import os

/// The keyboard listener's decisions in shadow mode (#3544 P2, plan §3.4): what the listener WOULD
/// decide, computed beside today's path and never acted on.
///
/// **One policy owner.** Record-key decisions are `RecordGesture`'s, called exactly as
/// `RecordGestureEngine` calls them; this type owns only its own lock, its own lone-tap timer,
/// press ownership and the records it emits. It has no outbox, no recording callbacks, no action
/// and no main-thread hop: every output is a `ShadowRecord` value handed to `emit`, outside the
/// lock.
///
/// **Ownership.** `KeyStateTracker` says which keys are held; this type remembers which role each
/// PRESS was admitted for, and a release follows that owner even after a rebind or disarm
/// (plan §3c). Cancel's press consumes its key, so its release is a consumed tail and never
/// another role's press. Paste Last acts on release, the other non-record roles on press;
/// all are predictions only.
///
/// **Timers.** The lone-tap wait runs on the scheduler's queue and never waits for main. Each fire
/// is validated by token under the lock, so a cancelled or replaced timer decides nothing. A
/// configuration change keeps a pending wait, as the live engine does; `reset` and `refuse` retire
/// it the way the live executor's resets do.
package final class ShadowKeyboardPolicy: Sendable {

  /// Everything a decision depends on, published by the owner as one value.
  package struct Snapshot: Equatable, Sendable {
    package var generation: UInt64
    package var bindings: ShortcutBindings
    package var mode: RecordingMode
    package var enabled: Bool
    package var suspended: Bool
    package var armed: Set<ShortcutRole>
    /// Roles whose action is available now (a last dictation exists, Quick Add can open).
    package var available: Set<ShortcutRole>

    package init(
      generation: UInt64, bindings: ShortcutBindings, mode: RecordingMode, enabled: Bool,
      suspended: Bool, armed: Set<ShortcutRole>, available: Set<ShortcutRole>
    ) {
      self.generation = generation
      self.bindings = bindings
      self.mode = mode
      self.enabled = enabled
      self.suspended = suspended
      self.armed = armed
      self.available = available
    }
  }

  private struct PendingTimer: Sendable {
    let token: UInt64
    let attemptID: UInt64
    let capturedGeneration: UInt64
    let keyCode: UInt16
    let release: RecordGesture.InputTime
    let deadline: TimeInterval
    let attemptStartOccurred: TimeInterval?
    var handle: RecordGestureEngine.TimerHandle?
  }

  private struct State: Sendable {
    var snapshot: Snapshot
    var tracker = KeyStateTracker()
    var gesture = RecordGesture()
    var owners: [UInt16: ShortcutRole] = [:]
    /// Keys whose cancel press was consumed; their presses and releases stay a consumed tail until
    /// the key's family flag drops, as the live service does.
    var consumed: Set<UInt16> = []
    var sequence: UInt64 = 0
    /// Bumped by every input, so a reconciliation read before one cannot be applied after it.
    var inputSequence: UInt64 = 0
    var nextTimerToken: UInt64 = 0
    var timer: PendingTimer?
  }

  private struct Work {
    var records: [ShadowRecord] = []
    var cancel: [RecordGestureEngine.TimerHandle] = []
    var schedule: (token: UInt64, deadline: TimeInterval)?
  }

  private let state: OSAllocatedUnfairLock<State>
  private let clock: RecordGestureEngine.Clock
  private let scheduler: RecordGestureEngine.Scheduler
  private let emit: @Sendable (ShadowRecord) -> Void

  package init(
    snapshot: Snapshot, clock: @escaping RecordGestureEngine.Clock,
    scheduler: @escaping RecordGestureEngine.Scheduler = RecordGestureEngine.liveScheduler,
    emit: @escaping @Sendable (ShadowRecord) -> Void
  ) {
    state = OSAllocatedUnfairLock(initialState: State(snapshot: snapshot))
    self.clock = clock
    self.scheduler = scheduler
    self.emit = emit
  }

  // MARK: - Configuration

  /// Publish a new snapshot. A record binding or mode change voids the stop-timer measurement,
  /// as the live service does on an actual change; the pending lone-tap wait is kept.
  package func configure(_ snapshot: Snapshot) {
    state.withLock { s in
      if s.snapshot.bindings.record != snapshot.bindings.record || s.snapshot.mode != snapshot.mode
      {
        s.gesture.invalidateDiagnostics()
      }
      s.snapshot = snapshot
    }
  }

  // MARK: - Input

  /// One listener event, on the listener's thread or any other.
  package func ingest(_ event: KeyEventValue, handled: TimeInterval) {
    let work = state.withLock { s -> Work in
      var work = Work()
      s.inputSequence &+= 1
      if event.kind == .flagsChanged, !event.isOurs,
        ModifierKeyCodes.flag(for: event.keyCode) != nil
      {
        let cleared = s.consumed.filter { key in
          guard let flag = ModifierKeyCodes.flag(for: key) else { return false }
          return event.rawFlags & UInt64(flag.rawValue) == 0
        }
        for key in cleared { s.consumed.remove(key) }
      }
      let config = KeyStateTracker.Configuration(
        bindings: s.snapshot.bindings, armed: s.snapshot.armed)
      let update = s.tracker.ingest(event, handled: handled, configuration: config)
      if update.edges.isEmpty, let key = update.ambiguousKey {
        // An unproven release: recorded as ambiguous so its live counterpart is not unmatched.
        for category in [ShadowRecord.Category.ingress, .decision] {
          work.records.append(
            Self.record(
              &s, category: category, keyCode: key, role: nil, phase: nil, outcome: .noDecision,
              raw: event.timestamp,
              accepted: RecordGesture.InputTime.accepting(stamp: event.timestamp, handled: handled)
                .occurred, handled: handled, ambiguous: true))
        }
      }
      for edge in update.edges {
        work.records.append(
          Self.record(
            &s, category: .ingress, keyCode: edge.keyCode, role: edge.role, phase: edge.phase,
            outcome: .edge, raw: edge.occurred, accepted: nil, handled: edge.handled,
            evidence: edge.evidence, ambiguous: s.tracker.ambiguous.contains(edge.keyCode)))
        Self.decide(&s, edge: edge, into: &work)
      }
      return work
    }
    perform(work)
  }

  /// Reconcile held keys against an injected reader (no OS call here).
  package func reconcile(
    handled: TimeInterval, reader: (Set<UInt16>) -> [UInt16: KeyStateTracker.Reading]
  ) {
    // The reader runs outside the lock. Its answers apply only if nothing moved meanwhile; an
    // input or a new snapshot in between makes them stale, and a later read retries.
    let captured = state.withLock {
      (sequence: $0.inputSequence, snapshot: $0.snapshot, keys: Set($0.tracker.held.keys))
    }
    let answers = reader(captured.keys)
    let work = state.withLock { s -> Work in
      guard s.inputSequence == captured.sequence, s.snapshot == captured.snapshot else {
        return Work()
      }
      var work = Work()
      let config = KeyStateTracker.Configuration(
        bindings: s.snapshot.bindings, armed: s.snapshot.armed)
      let edges = s.tracker.reconcile(handled: handled, configuration: config) { _ in answers }
      for edge in edges {
        work.records.append(
          Self.record(
            &s, category: .ingress, keyCode: edge.keyCode, role: edge.role, phase: edge.phase,
            outcome: .edge, raw: nil, accepted: nil, handled: edge.handled,
            evidence: edge.evidence))
        Self.decide(&s, edge: edge, into: &work)
      }
      return work
    }
    perform(work)
  }

  /// The live executor's unconditional reset (explicit cancel, stop, resume): end the attempt and
  /// retire its wait. Physical holds stay.
  package func reset() {
    let work = state.withLock { s -> Work in
      var work = Work()
      s.gesture.cleanup()
      Self.cancelTimer(&s, into: &work, retired: true)
      return work
    }
    perform(work)
  }

  /// The live executor refused one attempt: end it if it is still the live one and retire only
  /// its wait. A newer attempt and its wait are untouched; physical holds stay.
  package func refuse(attempt: UInt64) {
    let work = state.withLock { s -> Work in
      var work = Work()
      if s.gesture.isLiveAttempt(attempt) { s.gesture.cleanup() }
      if s.timer?.attemptID == attempt { Self.cancelTimer(&s, into: &work, retired: true) }
      return work
    }
    perform(work)
  }

  // MARK: - Decisions (under the lock)

  private static func decide(_ s: inout State, edge: KeyStateTracker.Edge, into work: inout Work) {
    let snapshot = s.snapshot
    func decision(_ role: ShortcutRole?, _ outcome: ShadowRecord.Outcome) {
      work.records.append(
        record(
          &s, category: .decision, keyCode: edge.keyCode, role: role, phase: edge.phase,
          outcome: outcome, raw: edge.occurred,
          accepted: RecordGesture.InputTime.accepting(stamp: edge.occurred, handled: edge.handled)
            .occurred, handled: edge.handled, evidence: edge.evidence))
    }
    switch edge.phase {
    case .press:
      if s.consumed.contains(edge.keyCode) {
        decision(.cancel, .consumedTail)
        return
      }
      guard snapshot.enabled, !snapshot.suspended, let role = edge.role else {
        decision(edge.role, .noDecision)
        return
      }
      s.owners[edge.keyCode] = role
      switch role {
      case .record where snapshot.mode == .pushToTalk:
        gesture(&s, edge: edge, isPress: true, into: &work)
      case .cancel:
        // Live cancel cleans up the attempt and disarms itself; its key is consumed until its
        // family flag drops.
        s.consumed.insert(edge.keyCode)
        s.snapshot.armed.remove(.cancel)
        s.gesture.cleanup()
        cancelTimer(&s, into: &work, retired: true)
        decision(role, .rolePress)
      case .record, .quickAdd, .copyLast:
        decision(
          role, snapshot.available.contains(role) || role == .record ? .rolePress : .noDecision)
      case .pasteLast:
        // Paste Last captures its target on press and acts on release.
        decision(role, snapshot.available.contains(role) ? .rolePress : .noDecision)
      }
    case .release:
      guard let owner = s.owners.removeValue(forKey: edge.keyCode) else {
        decision(
          s.consumed.contains(edge.keyCode) ? .cancel : edge.role,
          s.consumed.contains(edge.keyCode) ? .consumedTail : .noDecision)
        return
      }
      switch owner {
      case .record where snapshot.mode == .pushToTalk:
        gesture(&s, edge: edge, isPress: false, into: &work)
      case .cancel:
        decision(owner, .consumedTail)
      case .pasteLast:
        decision(owner, snapshot.available.contains(owner) ? .roleRelease : .noDecision)
      case .record, .quickAdd, .copyLast:
        decision(owner, .noDecision)
      }
    }
  }

  /// The record gesture, called exactly as the live engine calls it.
  private static func gesture(
    _ s: inout State, edge: KeyStateTracker.Edge, isPress: Bool, into work: inout Work
  ) {
    let input = RecordGesture.InputTime.accepting(stamp: edge.occurred, handled: edge.handled)
    let binding = s.snapshot.bindings.record
    let mode = s.snapshot.mode
    let attemptStart = s.gesture.start?.occurred
    func observe(_ outcome: GestureOutcome, afterStop: Int? = nil, deadline: TimeInterval? = nil) {
      let o = stamped(
        &s,
        GestureObservation(
          kind: isPress ? .press : .release, keyCode: edge.keyCode, outcome: outcome,
          handled: input.handled, occurred: input.occurred, attemptStartOccurred: attemptStart,
          afterStopTimerMs: afterStop, deadline: deadline))
      work.records.append(
        ShadowRecord(lane: .shadow, role: .record, observation: o, evidence: edge.evidence))
    }
    if isPress {
      guard
        case .admitted(let afterStop) = s.gesture.admitPress(input, binding: binding, mode: mode)
      else {
        observe(.duplicate)
        return
      }
      let decision = s.gesture.classifyPress(input, binding: binding, mode: mode)
      observe(GestureOutcome(decision), afterStop: afterStop)
      switch decision {
      case .start, .lockIntent:
        cancelTimer(&s, into: &work, retired: false)
      case .tripleCancel, .stopLocked:
        s.gesture.cleanup()
        cancelTimer(&s, into: &work, retired: false)
      case .ignoredCooldown:
        // Live forgets the hold after its telemetry; nothing later in this lane reads it before
        // the next input, so it is cleared here directly.
        s.gesture.forgetHeld()
      case .lateAfterWindow:
        break
      }
    } else {
      let decision = s.gesture.release(input)
      var deadline: TimeInterval?
      if case .quick(let quick) = decision { deadline = quick.deadline }
      observe(GestureOutcome(decision), deadline: deadline)
      switch decision {
      case .ignored, .suppressedLocked:
        break
      case .quick(let quick):
        cancelTimer(&s, into: &work, retired: false)
        s.nextTimerToken &+= 1
        s.timer = PendingTimer(
          token: s.nextTimerToken, attemptID: s.gesture.attemptID,
          capturedGeneration: quick.capturedGeneration, keyCode: edge.keyCode, release: input,
          deadline: quick.deadline, attemptStartOccurred: s.gesture.start?.occurred, handle: nil)
        work.schedule = (s.nextTimerToken, quick.deadline)
      case .hold:
        s.gesture.cleanup()
        cancelTimer(&s, into: &work, retired: false)
      }
    }
  }

  private static func cancelTimer(_ s: inout State, into work: inout Work, retired: Bool) {
    guard let timer = s.timer else { return }
    s.timer = nil
    if let handle = timer.handle { work.cancel.append(handle) }
    work.records.append(timerRecord(&s, timer, retired ? .loneTapRetired : .loneTapCancelled))
  }

  private static func timerRecord(
    _ s: inout State, _ timer: PendingTimer, _ outcome: GestureOutcome,
    stopRequestedAt: TimeInterval? = nil
  ) -> ShadowRecord {
    let o = stamped(
      &s,
      GestureObservation(
        kind: .timer, keyCode: timer.keyCode, outcome: outcome, handled: timer.release.handled,
        occurred: timer.release.occurred, attemptStartOccurred: timer.attemptStartOccurred,
        deadline: timer.deadline, stopRequestedAt: stopRequestedAt))
    return ShadowRecord(lane: .shadow, role: .record, observation: o)
  }

  /// Stamp an observation with this lane's generation and order at decision time.
  private static func stamped(_ s: inout State, _ o: GestureObservation) -> GestureObservation {
    var o = o
    s.sequence &+= 1
    o.generation = s.snapshot.generation
    o.sequence = s.sequence
    return o
  }

  private static func record(
    _ s: inout State, category: ShadowRecord.Category, keyCode: UInt16, role: ShortcutRole?,
    phase: KeyStateTracker.Phase?, outcome: ShadowRecord.Outcome, raw: TimeInterval?,
    accepted: TimeInterval?, handled: TimeInterval, evidence: KeyStateTracker.Evidence? = nil,
    ambiguous: Bool = false
  ) -> ShadowRecord {
    s.sequence &+= 1
    return ShadowRecord(
      lane: .shadow, generation: s.snapshot.generation, sequence: s.sequence, category: category,
      keyCode: keyCode, role: role, phase: phase, outcome: outcome, rawOccurred: raw,
      acceptedOccurred: accepted, handled: handled, evidence: evidence, ambiguous: ambiguous)
  }

  // MARK: - Timer and emission (outside the lock)

  private func perform(_ work: Work) {
    for handle in work.cancel { handle.cancel() }
    if let (token, deadline) = work.schedule {
      let handle = scheduler(max(0, deadline - clock())) { [weak self] in self?.timerFired(token) }
      let stale = state.withLock { s -> Bool in
        guard s.timer?.token == token else { return true }
        s.timer?.handle = handle
        return false
      }
      if stale { handle.cancel() }
    }
    for record in work.records { emit(record) }
  }

  private func timerFired(_ token: UInt64) {
    let record = state.withLock { s -> ShadowRecord? in
      guard let timer = s.timer, timer.token == token else { return nil }
      s.timer = nil
      let check = s.gesture.checkLoneTap(
        capturedGeneration: timer.capturedGeneration, binding: s.snapshot.bindings.record,
        mode: s.snapshot.mode)
      var requestedAt: TimeInterval?
      if case .stop(let stop) = check {
        s.gesture.cleanup()
        let stoppedAt = clock()
        requestedAt = stoppedAt
        s.gesture.recordQuickTapStop(stop, stoppedAt: stoppedAt)
      }
      return Self.timerRecord(&s, timer, GestureOutcome(check), stopRequestedAt: requestedAt)
    }
    if let record { emit(record) }
  }
}
