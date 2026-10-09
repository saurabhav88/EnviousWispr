import EnviousWisprCore
import Foundation
import os

/// The push-to-talk record gesture, decided under a lock and delivered to the main thread in
/// decision order (#3544 P1).
///
/// `RecordGesture` decides; this engine owns it, its lone-tap timer and the hand-off of every
/// decision to `HotkeyService`, which executes it on the main thread. Each input is applied under
/// one lock, so a press, a release and the timer are ordered by when the ENGINE receives them;
/// the timer runs on its own queue and never waits for the main thread. In P1 every key event
/// still arrives through the main thread (Carbon and `NSEvent` monitors); P2/P3 add a listener
/// thread that calls `ingest` directly.
///
/// Delivery (plan amendment A1): one FIFO outbox and one application path for every producer. A
/// background producer (the timer queue) appends and claims at most one pending
/// `DispatchQueue.main.async` drain. A main-actor producer appends and then drains the outbox to
/// empty on the spot, oldest batch first, so a main-origin press is executed on its own turn and
/// can never overtake an older queued decision. One drain runs at a time; an append made while it
/// runs is picked up by it.
///
/// Invalidation (plan §3.4, the one rule): a batch is dropped iff its `epoch` is older than the
/// engine's (bumped ONLY by the unconditional `reset()`) or its attempt is in the refused set
/// (written ONLY by `reset(attempt:)`). Nothing else invalidates a queued batch.
///
/// `Sendable` by construction: every stored property is a `let` of a `Sendable` type, and all
/// mutable state lives inside one `OSAllocatedUnfairLock`. No callback, log, telemetry or wait on
/// the main thread happens while that lock is held.
package final class RecordGestureEngine: Sendable {

  // MARK: - Seams

  /// Uptime in seconds, the same clock `ProcessInfo.systemUptime` gives. Nonisolated: the timer
  /// queue reads it too.
  package typealias Clock = @Sendable () -> TimeInterval

  /// Run `fire` once, `delay` seconds from now, on a queue that is not the main thread, and
  /// return a way to cancel it. Cancelling is advisory: the engine validates every fire by
  /// token under its lock, so a fire already running when it is cancelled does nothing.
  package typealias Scheduler =
    @Sendable (_ delay: TimeInterval, _ fire: @escaping @Sendable () -> Void) -> TimerHandle

  package struct TimerHandle: Sendable {
    package let cancel: @Sendable () -> Void
    package init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
  }

  /// The live scheduler: a one-shot `DispatchSourceTimer` on a private serial `userInteractive`
  /// queue. Activated once, never suspended (a suspended source must never be released); it
  /// cancels itself when it fires, and the handle cancels it otherwise. The engine still
  /// validates every fire by token under its lock, so a handler already running when it is
  /// cancelled does nothing.
  package static let liveScheduler: Scheduler = { delay, fire in
    let timer = DispatchSource.makeTimerSource(queue: timerQueue)
    timer.setEventHandler { [weak timer] in
      timer?.cancel()
      fire()
    }
    timer.schedule(deadline: .now() + max(0, delay), repeating: .never)
    timer.activate()
    return TimerHandle(cancel: { timer.cancel() })
  }
  private static let timerQueue = DispatchQueue(
    label: "com.enviouswispr.record-gesture.timer", qos: .userInteractive)

  // MARK: - Effects

  /// One decision for the main thread to execute, with every value it needs captured at decision
  /// time.
  package enum Effect: Sendable {
    /// An admitted press and what it means. `inputSequence` lets a deferred held clear (cooldown,
    /// processing refusal) skip itself when a later input already moved the key (D2).
    case press(Press)
    /// Normal PTT release (held > 500ms) → stop immediately. The engine already cleaned up.
    case holdStop
    /// Quick release (within 500ms): the lone-tap stop is scheduled. Trace only.
    case quickRelease(QuickReleaseTrace)
    /// Timer fired — user didn't double-press. Stop as normal PTT. The engine already cleaned up
    /// and recorded the stop marker (#3534 §3.3 steps 1-3); main queues the stop (step 4).
    case loneTapStop(LoneTapStopTrace)
    /// One scheduled lone-tap wait finished, on any path (stopped, stale, locked, cancelled).
    /// A completion signal for tests; always applied, even in an invalidated batch.
    case loneTapResolved
  }

  package struct Press: Sendable {
    package let inputSequence: UInt64
    /// The mode and record key this press was decided under, so its telemetry reports them even
    /// if the configuration changes before the main thread executes it (r1 A).
    package let mode: RecordingMode
    package let keyCode: UInt16
    package let input: RecordGesture.InputTime
    package let afterStopTimerMs: Int?
    package let decision: RecordGesture.PressDecision
  }

  package struct QuickReleaseTrace: Sendable {
    package let attemptID: UInt64
    package let release: RecordGesture.InputTime
    package let deadline: TimeInterval
    package let usesOccurrence: Bool
    package let eventDeadline: TimeInterval
  }

  package struct LoneTapStopTrace: Sendable {
    package let quick: QuickReleaseTrace
    package let requestedAt: TimeInterval
    package let attributable: Bool
  }

  /// What the main thread receives: the batch's identity and its effects, in decision order.
  package struct Batch: Sendable {
    package let epoch: UInt64
    package let attemptID: UInt64
    package let effects: [Effect]
  }

  /// Snapshot readers outside the engine see.
  package struct Snapshot: Sendable {
    package let isHeld: Bool
    package let isLocked: Bool
  }

  // MARK: - State

  private struct PendingTimer: Sendable {
    let token: UInt64
    let attemptID: UInt64
    let capturedGeneration: UInt64
    let trace: QuickReleaseTrace
    var handle: TimerHandle?
  }

  private struct State: Sendable {
    var gesture = RecordGesture()
    var binding: ShortcutBinding
    var mode: RecordingMode
    var epoch: UInt64 = 0
    var refused: Set<UInt64> = []
    var inputSequence: UInt64 = 0
    var nextTimerToken: UInt64 = 0
    var timer: PendingTimer?
    var outbox: [Batch] = []
    var asyncDrainPending = false
    var draining = false
    var sink: (@MainActor @Sendable (Batch, _ valid: Bool) -> Void)?
    var onAsyncDrainResolvedForTesting: (@MainActor @Sendable () -> Void)?
  }

  private let state: OSAllocatedUnfairLock<State>
  private let clock: Clock
  private let scheduler: Scheduler

  package init(
    binding: ShortcutBinding, mode: RecordingMode, clock: @escaping Clock,
    scheduler: @escaping Scheduler = RecordGestureEngine.liveScheduler
  ) {
    state = OSAllocatedUnfairLock(initialState: State(binding: binding, mode: mode))
    self.clock = clock
    self.scheduler = scheduler
  }

  /// The main-thread executor. Set once by `HotkeyService` after it is initialized.
  package func setSink(_ sink: @escaping @MainActor @Sendable (Batch, _ valid: Bool) -> Void) {
    state.withLock { $0.sink = sink }
  }

  // MARK: - Configuration and reads

  /// The record binding and mode the gesture reads (attempt origin, stop-marker attribution, the
  /// lone-tap check). Pushed on every change; diagnostics are invalidated separately, by
  /// `invalidateDiagnostics()`, only on an ACTUAL change (unchanged assignments are free).
  package func configure(binding: ShortcutBinding, mode: RecordingMode) {
    state.withLock {
      $0.binding = binding
      $0.mode = mode
    }
  }

  package func invalidateDiagnostics() {
    state.withLock { $0.gesture.invalidateDiagnostics() }
  }

  package var snapshot: Snapshot {
    state.withLock { Snapshot(isHeld: $0.gesture.isHeld, isLocked: $0.gesture.isLocked) }
  }

  // MARK: - Ingest

  /// A record-key press or release from any thread. Its effects reach the main thread through
  /// the pending async drain.
  package func ingest(isPress: Bool, input: RecordGesture.InputTime) {
    let (work, submit) = state.withLock { s -> (TimerWork, Bool) in
      let work = Self.admit(&s, isPress: isPress, input: input)
      return (work, Self.claimAsyncDrain(&s))
    }
    perform(work)
    if submit { submitAsyncDrain() }
  }

  /// A record-key press or release on the main actor (P1: Carbon and `NSEvent` monitors). Appends
  /// through the same admission path, then drains the whole outbox on this turn (A1).
  @MainActor
  package func ingestOnMain(isPress: Bool, input: RecordGesture.InputTime) {
    let work = state.withLock { s in
      Self.admit(&s, isPress: isPress, input: input)
    }
    perform(work)
    drainOnMain()
  }

  // MARK: - Reset

  /// Unconditional reset: explicit cancel, service `stop()` and `resume()`. Bumps the epoch, so
  /// every batch decided before it is dropped, and ends the gesture's attempt.
  @MainActor
  package func reset() {
    let work = state.withLock { s -> TimerWork in
      s.epoch &+= 1
      s.gesture.cleanup()
      var work = TimerWork()
      Self.cancelTimer(&s, into: &work)
      return work
    }
    perform(work)
    drainOnMain()
  }

  /// Refuse one attempt (#1631 `.noRecording`, publication rejected, processing refusal). Its
  /// queued batches are dropped; a newer attempt, its timer and its batches are untouched.
  @MainActor
  package func reset(attempt: UInt64) {
    let work = state.withLock { s -> TimerWork in
      s.refused.insert(attempt)
      var work = TimerWork()
      if s.gesture.isLiveAttempt(attempt) {
        s.gesture.cleanup()
      }
      if s.timer?.attemptID == attempt { Self.cancelTimer(&s, into: &work) }
      return work
    }
    perform(work)
    drainOnMain()
  }

  /// D2: clear the held key after telemetry that had to see it held (cooldown, processing
  /// refusal), unless a later input has already been ingested.
  package func forgetHeld(ifNoInputAfter sequence: UInt64) {
    state.withLock {
      if $0.inputSequence == sequence { $0.gesture.forgetHeld() }
    }
  }

  /// Forget the held key without a release: `stop()` and `resume()`.
  package func forgetHeld() {
    state.withLock { $0.gesture.forgetHeld() }
  }

  // MARK: - Admission (under the lock)

  /// Timer requests and cancellations to perform OUTSIDE the lock.
  private struct TimerWork {
    var cancel: [TimerHandle] = []
    var schedule: (token: UInt64, delay: TimeInterval)?
  }

  private static func admit(
    _ s: inout State, isPress: Bool, input: RecordGesture.InputTime
  ) -> TimerWork {
    s.inputSequence &+= 1
    let sequence = s.inputSequence
    var work = TimerWork()
    var effects: [Effect] = []
    if isPress {
      guard case .admitted(let afterStopTimerMs) = s.gesture.admitPress(
        input, binding: s.binding, mode: s.mode)
      else { return work }
      let decision = s.gesture.classifyPress(input, binding: s.binding, mode: s.mode)
      switch decision {
      case .start, .lockIntent:
        // A fresh attempt or a lock: the pending lone-tap stop no longer applies.
        cancelTimer(&s, into: &work, effects: &effects)
      case .tripleCancel, .stopLocked:
        // The engine applies its own cleanup; main clears only its execution state.
        s.gesture.cleanup()
        cancelTimer(&s, into: &work, effects: &effects)
      case .ignoredCooldown, .lateAfterWindow:
        break
      }
      let keyCode: UInt16
      switch s.binding {
      case .keyboard(let code, _): keyCode = code
      }
      effects.append(
        .press(
          Press(
            inputSequence: sequence, mode: s.mode, keyCode: keyCode, input: input,
            afterStopTimerMs: afterStopTimerMs, decision: decision)))
    } else {
      switch s.gesture.release(input) {
      case .ignored, .suppressedLocked:
        return work
      case .quick(let quick):
        cancelTimer(&s, into: &work, effects: &effects)
        let trace = QuickReleaseTrace(
          attemptID: s.gesture.attemptID, release: input, deadline: quick.deadline,
          usesOccurrence: quick.usesOccurrence, eventDeadline: quick.eventDeadline)
        s.nextTimerToken &+= 1
        let token = s.nextTimerToken
        s.timer = PendingTimer(
          token: token, attemptID: s.gesture.attemptID,
          capturedGeneration: quick.capturedGeneration, trace: trace, handle: nil)
        work.schedule = (token, quick.deadline)
        effects.append(.quickRelease(trace))
      case .hold:
        s.gesture.cleanup()
        cancelTimer(&s, into: &work, effects: &effects)
        effects.append(.holdStop)
      }
    }
    s.outbox.append(Batch(epoch: s.epoch, attemptID: s.gesture.attemptID, effects: effects))
    return work
  }

  /// Retire the pending timer: its handle is cancelled outside the lock, and its resolution is
  /// reported with the batch being built.
  private static func cancelTimer(
    _ s: inout State, into work: inout TimerWork, effects: inout [Effect]
  ) {
    guard let timer = s.timer else { return }
    s.timer = nil
    if let handle = timer.handle { work.cancel.append(handle) }
    effects.append(.loneTapResolved)
  }

  /// Retire the pending timer from a reset: its resolution travels in its own batch, stamped
  /// with the CURRENT epoch so it is delivered.
  private static func cancelTimer(_ s: inout State, into work: inout TimerWork) {
    var effects: [Effect] = []
    cancelTimer(&s, into: &work, effects: &effects)
    if !effects.isEmpty {
      s.outbox.append(Batch(epoch: s.epoch, attemptID: s.gesture.attemptID, effects: effects))
    }
  }

  private static func claimAsyncDrain(_ s: inout State) -> Bool {
    guard !s.asyncDrainPending, !s.outbox.isEmpty else { return false }
    s.asyncDrainPending = true
    return true
  }

  // MARK: - Timer

  private func perform(_ work: TimerWork) {
    for handle in work.cancel { handle.cancel() }
    guard let (token, deadline) = work.schedule else { return }
    // #3534: compute the remaining wait now; request no further wait if the deadline has passed.
    let handle = scheduler(max(0, deadline - clock())) { [weak self] in self?.timerFired(token) }
    let stale = state.withLock { s -> Bool in
      guard s.timer?.token == token else { return true }
      s.timer?.handle = handle
      return false
    }
    if stale { handle.cancel() }
  }

  private func timerFired(_ token: UInt64) {
    let submit = state.withLock { s -> Bool in
      guard let timer = s.timer, timer.token == token else { return false }
      s.timer = nil
      var effects: [Effect] = []
      if case .stop(let stop) = s.gesture.checkLoneTap(
        capturedGeneration: timer.capturedGeneration, binding: s.binding, mode: s.mode)
      {
        // #3534 §3.3, in this order: (1) snapshot (in checkLoneTap), (2) cleanup, (3) marker
        // with the post-cleanup epoch and the time read after cleanup.
        s.gesture.cleanup()
        let requestedAt = clock()
        s.gesture.recordQuickTapStop(stop, stoppedAt: requestedAt)
        effects.append(
          .loneTapStop(
            LoneTapStopTrace(
              quick: timer.trace, requestedAt: requestedAt, attributable: stop.attributable)))
      }
      effects.append(.loneTapResolved)
      s.outbox.append(Batch(epoch: s.epoch, attemptID: timer.attemptID, effects: effects))
      return Self.claimAsyncDrain(&s)
    }
    if submit { submitAsyncDrain() }
  }

  // MARK: - Drain

  private func submitAsyncDrain() {
    DispatchQueue.main.async { [self] in
      MainActor.assumeIsolated {
        // Test seam: signalled on every exit of this pending drain, empty or re-entrant included.
        defer {
          let resolved = state.withLock { $0.onAsyncDrainResolvedForTesting }
          resolved?()
        }
        state.withLock { $0.asyncDrainPending = false }
        drainOnMain()
      }
    }
  }

  /// Apply every queued batch, oldest first, on the main actor. Never re-entered: an append made
  /// while a drain runs is applied by that drain.
  @MainActor
  private func drainOnMain() {
    let start = state.withLock { s -> Bool in
      guard !s.draining else { return false }
      s.draining = true
      return true
    }
    guard start else { return }
    while true {
      let next = state.withLock { s -> (Batch, Bool, (@MainActor @Sendable (Batch, Bool) -> Void)?)? in
        guard !s.outbox.isEmpty else {
          s.draining = false
          return nil
        }
        let batch = s.outbox.removeFirst()
        let valid = batch.epoch == s.epoch && !s.refused.contains(batch.attemptID)
        return (batch, valid, s.sink)
      }
      guard let (batch, valid, sink) = next else { return }
      sink?(batch, valid)
    }
  }

  /// Whether a batch is still valid NOW: an effect applied earlier in the same batch may have
  /// reset the engine or refused the attempt (the one invalidation rule, plan §3.4).
  @MainActor
  package func isValid(_ batch: Batch) -> Bool {
    state.withLock { batch.epoch == $0.epoch && !$0.refused.contains(batch.attemptID) }
  }

  /// Test seam: invoked once each time a pending main-queue drain finishes, on every exit path.
  /// Test-only; production never sets it.
  @MainActor
  package var onAsyncDrainResolvedForTesting: (@MainActor @Sendable () -> Void)? {
    get { state.withLock { $0.onAsyncDrainResolvedForTesting } }
    set { state.withLock { $0.onAsyncDrainResolvedForTesting = newValue } }
  }

  /// Test seam: apply whatever is queued now, through the same path production uses.
  @MainActor
  package func drainForTesting() {
    drainOnMain()
  }
}
