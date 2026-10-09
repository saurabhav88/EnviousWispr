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
/// engine's (bumped ONLY by the unconditional `reset()`) or it is attempt-scoped and its attempt is
/// in the refused set (written ONLY by `reset(attempt:)`). Nothing else invalidates a queued batch.
///
/// Listener admission (#3544 P3): input from the keyboard listener thread names the key, the
/// listener configuration generation it was classified under and its installation, and is checked
/// against them in the same critical section that admits it, so an edge classified before a rebind,
/// a stop or a reinstall can never act under what came after. A refused input changes nothing.
/// This admission generation is separate from the batch epoch: it gates input, never an
/// already-admitted batch.
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
    /// The listener's bare cancel key, decided in input order (#3544 P3). The engine already ended
    /// the attempt it captured and retired its wait, so a record press after it starts fresh; main
    /// runs the cancel and clears only that attempt's execution state.
    case cancel(Cancel)
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

  package struct Cancel: Sendable {
    package let keyCode: UInt16
    /// The attempt that was live when the cancel arrived, or nil when none was.
    package let attemptID: UInt64?
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
    /// False for a batch that is not one attempt's decision (a listener cancel): refusing the
    /// attempt it names must not drop it, since the cancel is what ends that attempt.
    package var attemptScoped = true
  }

  // MARK: - Listener admission

  /// What the listener's input is classified against, beyond the record binding and mode.
  /// Changing any of these (actually changing; equal assignments are free) starts a new
  /// listener configuration generation.
  package struct ListenerCancel: Equatable, Sendable {
    package var binding: ShortcutBinding
    package init(binding: ShortcutBinding) { self.binding = binding }
  }

  /// Why the engine refused a listener input. A refused input changes no state.
  package enum ListenerRefusal: Hashable, Sendable, CaseIterable {
    /// No listener installation is admitting input, or the input came from an earlier one.
    case staleInstallation
    /// Classified under a configuration that has since changed.
    case staleGeneration
    /// The record binding is not a bare modifier in push-to-talk, so it is not the listener's
    /// to decide here (toggle and chords stay on the main path).
    case notListenerBinding
    /// The key is not the configured record key (or, for a cancel, the bare cancel key).
    case wrongKey
    /// A release whose press this engine never admitted from that key.
    case unownedRelease
    /// A cancel while cancel is not armed.
    case cancelNotArmed
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
    /// The attempt's first press, for the DEBUG decision observer (#3544 P2). Not read otherwise.
    let attemptStartOccurred: TimeInterval?
    var handle: TimerHandle?
    #if DEBUG
      /// The record key this wait was scheduled under, so its observation names that key even
      /// after a rebind.
      var observedKeyCode: UInt16 = 0
      /// Whether that binding was a bare modifier the listener can see.
      var observedBareModifier = true
    #endif
  }

  /// The press whose release the listener may deliver: its key and the attempt it belonged to.
  private struct OwnedPress: Sendable {
    let keyCode: UInt16
    let attemptID: UInt64
  }

  private struct State: Sendable {
    var gesture = RecordGesture()
    var binding: ShortcutBinding
    var mode: RecordingMode
    var cancel = ListenerCancel(binding: ShortcutRole.cancel.defaultBinding)
    var cancelArmed = false
    /// Bumped on every ACTUAL change of record binding, mode or cancel binding, and by the
    /// unconditional `reset()`. Distinct from `HotkeyService`'s installation counter.
    var listenerConfigurationGeneration: UInt64 = 0
    /// The listener installation admitting input, or nil while none is (stopped, suspended,
    /// not installed).
    var listenerInstallation: UInt64?
    var owned: OwnedPress?
    var refusals: [ListenerRefusal: Int] = [:]
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
    #if DEBUG
      var observer: (@Sendable (GestureObservation) -> Void)?
      var observationGeneration: UInt64 = 0
      var observationSequence: UInt64 = 0
      /// First press of the attempt the last attributable lone-tap stop ended: the origin of the
      /// marker the next admitted press may consume.
      var lastStopOrigin: TimeInterval?
    #endif
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
    state.withLock { Self.apply(&$0, binding: binding, mode: mode) }
  }

  /// The one writer of the record binding and mode: an actual change starts a new listener
  /// generation, an equal assignment does not (settings assign unchanged values freely, and a
  /// harmless repeat must never strand a held key's release).
  private static func apply(_ s: inout State, binding: ShortcutBinding, mode: RecordingMode) {
    if s.binding != binding || s.mode != mode { s.listenerConfigurationGeneration &+= 1 }
    s.binding = binding
    s.mode = mode
  }

  /// The cancel binding the listener's cancel is classified against. An actual change starts a
  /// new listener generation.
  package func configureCancel(_ cancel: ListenerCancel) {
    state.withLock { s in
      if s.cancel != cancel { s.listenerConfigurationGeneration &+= 1 }
      s.cancel = cancel
    }
  }

  /// Whether cancel is armed now. Checked when a listener cancel is admitted, not part of the
  /// generation: arming happens as a recording starts, and a record press classified a moment
  /// before must not be refused for it.
  package func setCancelArmed(_ armed: Bool) {
    state.withLock { $0.cancelArmed = armed }
  }

  /// Start admitting listener input from `installation`. Every earlier installation's input is
  /// refused from now on.
  package func openListenerAdmission(installation: UInt64) {
    state.withLock { $0.listenerInstallation = installation }
  }

  /// Stop admitting listener input (the listener was removed: stop, suspend, reinstall).
  package func closeListenerAdmission() {
    state.withLock { $0.listenerInstallation = nil }
  }

  /// The installation whose input is admitted now, or nil.
  package var listenerInstallation: UInt64? {
    state.withLock { $0.listenerInstallation }
  }

  /// The generation the listener classifies its next input under.
  package var listenerConfigurationGeneration: UInt64 {
    state.withLock { $0.listenerConfigurationGeneration }
  }

  /// How many listener inputs were refused, by reason. Diagnostics only.
  package var listenerRefusals: [ListenerRefusal: Int] {
    state.withLock { $0.refusals }
  }

  package func invalidateDiagnostics() {
    state.withLock { $0.gesture.invalidateDiagnostics() }
  }

  #if DEBUG
    /// #3544 P2 shadow comparison: report each decision this engine already made, captured under
    /// the lock with the decision and delivered outside it, after the lock is released. Nil is
    /// inert. The observer changes no admission, outbox, validity, scheduling or drain.
    package func setObserver(_ observer: (@Sendable (GestureObservation) -> Void)?) {
      state.withLock { $0.observer = observer }
    }

    /// The configuration generation stamped on every later observation, at decision time.
    package func setObservationGeneration(_ generation: UInt64) {
      state.withLock { $0.observationGeneration = generation }
    }

    /// Record binding, mode and observation generation in one critical section, so no decision
    /// can be stamped with one generation under the other configuration.
    package func configure(
      binding: ShortcutBinding, mode: RecordingMode, observationGeneration: UInt64
    ) {
      state.withLock {
        Self.apply(&$0, binding: binding, mode: mode)
        $0.observationGeneration = observationGeneration
      }
    }

    /// The next stamp in this engine's observation order, for live records the service makes
    /// itself (ingress, non-record roles), so the whole live lane shares one sequence domain.
    package func nextObservationStamp() -> (generation: UInt64, sequence: UInt64) {
      state.withLock { s in
        s.observationSequence &+= 1
        return (s.observationGeneration, s.observationSequence)
      }
    }

    /// Stamp an observation with the generation and order current when it was decided.
    private static func stamped(
      _ s: inout State, _ o: GestureObservation, bareModifier: Bool? = nil
    ) -> GestureObservation {
      var o = o
      s.observationSequence &+= 1
      o.generation = s.observationGeneration
      o.sequence = s.observationSequence
      o.listenerScope = bareModifier ?? s.binding.isBareModifier
      return o
    }

    /// The first press of `attemptID` while it is the gesture's live attempt, read before a
    /// refusal resets it, so the shadow can end the same physical attempt.
    /// The first press of the gesture's live attempt, whatever its number.
    package func currentAttemptOrigin() -> TimeInterval? {
      state.withLock { $0.gesture.start?.occurred }
    }

    package func liveAttemptOrigin(_ attemptID: UInt64) -> TimeInterval? {
      state.withLock { s in
        s.gesture.isLiveAttempt(attemptID) ? s.gesture.start?.occurred : nil
      }
    }

    private func report(_ observations: [GestureObservation]) {
      guard !observations.isEmpty, let observer = state.withLock({ $0.observer }) else { return }
      for observation in observations { observer(observation) }
    }
  #endif

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
    #if DEBUG
      report(work.observations)
    #endif
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
    #if DEBUG
      report(work.observations)
    #endif
    drainOnMain()
  }

  /// A record-key press or release from the keyboard listener thread (#3544 P3), classified under
  /// `generation` and delivered by `installation`. Validated and admitted in one critical section;
  /// returns why it was refused, or nil when admitted. Its effects reach main through the pending
  /// async drain, like `ingest`.
  ///
  /// A press needs the current generation, a bare-modifier record binding in push-to-talk and that
  /// key. A release needs only the press this engine admitted from the same key: it follows its
  /// press, so a release after a rebind still ends the hold it belongs to and is never rematched.
  @discardableResult
  package func ingestFromListener(
    keyCode: UInt16, isPress: Bool, input: RecordGesture.InputTime, generation: UInt64,
    installation: UInt64
  ) -> ListenerRefusal? {
    let (refusal, work, submit) = state.withLock { s -> (ListenerRefusal?, TimerWork, Bool) in
      if let refusal = Self.refusal(&s, keyCode: keyCode, isPress: isPress,
        generation: generation, installation: installation)
      {
        s.refusals[refusal, default: 0] += 1
        return (refusal, TimerWork(), false)
      }
      let work = Self.admit(&s, isPress: isPress, input: input)
      return (nil, work, Self.claimAsyncDrain(&s))
    }
    perform(work)
    #if DEBUG
      report(work.observations)
    #endif
    if submit { submitAsyncDrain() }
    return refusal
  }

  /// The listener's bare cancel key (#3544 P3), in the same order as record input: the attempt
  /// live NOW is captured and ended here, so a record press after it starts fresh even if main
  /// has not run the cancel yet, and main's cleanup touches only that attempt. Returns why it was
  /// refused, or nil when admitted.
  @discardableResult
  package func cancelFromListener(
    keyCode: UInt16, generation: UInt64, installation: UInt64
  ) -> ListenerRefusal? {
    let (refusal, work, submit) = state.withLock { s -> (ListenerRefusal?, TimerWork, Bool) in
      let refusal: ListenerRefusal? =
        if s.listenerInstallation != installation {
          .staleInstallation
        } else if s.listenerConfigurationGeneration != generation {
          .staleGeneration
        } else if !s.cancel.binding.isBareModifier || Self.key(s.cancel.binding) != keyCode
          || (s.binding.isBareModifier && Self.key(s.binding) == keyCode)
        {
          // Record wins a tie (#3106): a key that is also the bare record key is never cancel.
          .wrongKey
        } else if !s.cancelArmed {
          .cancelNotArmed
        } else {
          nil
        }
      if let refusal {
        s.refusals[refusal, default: 0] += 1
        return (refusal, TimerWork(), false)
      }
      // Disarmed here, as main's cancel does, so a second cancel event cannot act twice.
      s.cancelArmed = false
      let attempt: UInt64? = s.gesture.start != nil ? s.gesture.attemptID : nil
      var work = TimerWork()
      var effects: [Effect] = []
      s.gesture.cleanup()
      Self.cancelTimer(&s, into: &work, effects: &effects, retired: true)
      effects.append(.cancel(Cancel(keyCode: keyCode, attemptID: attempt)))
      var batch = Batch(epoch: s.epoch, attemptID: attempt ?? s.gesture.attemptID, effects: effects)
      batch.attemptScoped = false
      s.outbox.append(batch)
      return (nil, work, Self.claimAsyncDrain(&s))
    }
    perform(work)
    #if DEBUG
      report(work.observations)
    #endif
    if submit { submitAsyncDrain() }
    return refusal
  }

  /// Why a listener record input is refused, or nil to admit it.
  private static func refusal(
    _ s: inout State, keyCode: UInt16, isPress: Bool, generation: UInt64, installation: UInt64
  ) -> ListenerRefusal? {
    guard s.listenerInstallation == installation else { return .staleInstallation }
    if !isPress {
      guard let owned = s.owned, owned.keyCode == keyCode else { return .unownedRelease }
      return nil
    }
    guard s.listenerConfigurationGeneration == generation else { return .staleGeneration }
    guard s.binding.isBareModifier, s.mode == .pushToTalk else { return .notListenerBinding }
    guard Self.key(s.binding) == keyCode else { return .wrongKey }
    return nil
  }

  private static func key(_ binding: ShortcutBinding) -> UInt16 {
    switch binding {
    case .keyboard(let code, _): code
    }
  }

  // MARK: - Reset

  /// Unconditional reset: explicit cancel, service `stop()` and `resume()`. Bumps the epoch, so
  /// every batch decided before it is dropped, and ends the gesture's attempt.
  @MainActor
  package func reset() {
    let work = state.withLock { s -> TimerWork in
      s.epoch &+= 1
      // A listener input classified before this reset (a press already read on the listener
      // thread) must not start a dictation after it: the epoch gates batches, this gates input.
      // A held key's release still follows its press (ownership), so no hold is stranded.
      s.listenerConfigurationGeneration &+= 1
      s.gesture.cleanup()
      var work = TimerWork()
      Self.cancelTimer(&s, into: &work)
      return work
    }
    perform(work)
    #if DEBUG
      report(work.observations)
    #endif
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
    #if DEBUG
      report(work.observations)
    #endif
    drainOnMain()
  }

  /// D2: clear the held key after telemetry that had to see it held (cooldown, processing
  /// refusal), unless a later input has already been ingested.
  package func forgetHeld(ifNoInputAfter sequence: UInt64) {
    state.withLock {
      if $0.inputSequence == sequence {
        $0.gesture.forgetHeld()
        $0.owned = nil
      }
    }
  }

  /// Forget the held key without a release: `stop()` and `resume()`.
  package func forgetHeld() {
    state.withLock {
      $0.gesture.forgetHeld()
      $0.owned = nil
    }
  }

  // MARK: - Admission (under the lock)

  /// Timer requests and cancellations to perform OUTSIDE the lock.
  private struct TimerWork {
    var cancel: [TimerHandle] = []
    var schedule: (token: UInt64, delay: TimeInterval)?
    #if DEBUG
      var observations: [GestureObservation] = []
    #endif
  }

  private static func admit(
    _ s: inout State, isPress: Bool, input: RecordGesture.InputTime
  ) -> TimerWork {
    s.inputSequence &+= 1
    let sequence = s.inputSequence
    var work = TimerWork()
    var effects: [Effect] = []
    let keyCode: UInt16
    switch s.binding {
    case .keyboard(let code, _): keyCode = code
    }
    #if DEBUG
      let attemptStart = s.gesture.start?.occurred
    #endif
    if isPress {
      guard case .admitted(let afterStopTimerMs) = s.gesture.admitPress(
        input, binding: s.binding, mode: s.mode)
      else {
        // A duplicate leaves the earlier press's ownership in place.
        #if DEBUG
          work.observations.append(
            stamped(
              &s,
              GestureObservation(
                kind: .press, keyCode: keyCode, outcome: .duplicate, handled: input.handled,
                occurred: input.occurred, attemptStartOccurred: attemptStart)))
        #endif
        return work
      }
      let decision = s.gesture.classifyPress(input, binding: s.binding, mode: s.mode)
      // The held key's release follows this press, whatever the configuration is by then.
      s.owned = OwnedPress(keyCode: keyCode, attemptID: s.gesture.attemptID)
      #if DEBUG
        // The admitted press consumed whatever marker there was; its origin goes with it.
        let markerOrigin = afterStopTimerMs == nil ? nil : s.lastStopOrigin
        s.lastStopOrigin = nil
        work.observations.append(
          stamped(
            &s,
            GestureObservation(
              kind: .press, keyCode: keyCode, outcome: GestureOutcome(decision),
              handled: input.handled, occurred: input.occurred,
              attemptStartOccurred: attemptStart, afterStopTimerMs: afterStopTimerMs,
              markerOrigin: markerOrigin)))
      #endif
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
      effects.append(
        .press(
          Press(
            inputSequence: sequence, mode: s.mode, keyCode: keyCode, input: input,
            afterStopTimerMs: afterStopTimerMs, decision: decision)))
    } else {
      s.owned = nil
      let decision = s.gesture.release(input)
      #if DEBUG
        var deadline: TimeInterval?
        if case .quick(let quick) = decision { deadline = quick.deadline }
        work.observations.append(
          stamped(
            &s,
            GestureObservation(
              kind: .release, keyCode: keyCode, outcome: GestureOutcome(decision),
              handled: input.handled, occurred: input.occurred,
              attemptStartOccurred: attemptStart, deadline: deadline)))
      #endif
      switch decision {
      case .ignored, .suppressedLocked:
        return work
      case .quick(let quick):
        cancelTimer(&s, into: &work, effects: &effects)
        let trace = QuickReleaseTrace(
          attemptID: s.gesture.attemptID, release: input, deadline: quick.deadline,
          usesOccurrence: quick.usesOccurrence, eventDeadline: quick.eventDeadline)
        s.nextTimerToken &+= 1
        let token = s.nextTimerToken
        #if DEBUG
          s.timer = PendingTimer(
            token: token, attemptID: s.gesture.attemptID,
            capturedGeneration: quick.capturedGeneration, trace: trace,
            attemptStartOccurred: s.gesture.start?.occurred, handle: nil, observedKeyCode: keyCode,
            observedBareModifier: s.binding.isBareModifier)
        #else
          s.timer = PendingTimer(
            token: token, attemptID: s.gesture.attemptID,
            capturedGeneration: quick.capturedGeneration, trace: trace,
            attemptStartOccurred: s.gesture.start?.occurred, handle: nil)
        #endif
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
    _ s: inout State, into work: inout TimerWork, effects: inout [Effect],
    retired: Bool = false
  ) {
    guard let timer = s.timer else { return }
    s.timer = nil
    if let handle = timer.handle { work.cancel.append(handle) }
    effects.append(.loneTapResolved)
    #if DEBUG
      work.observations.append(
        stamped(
          &s,
          GestureObservation(
            kind: .timer, keyCode: timer.observedKeyCode,
            outcome: retired ? .loneTapRetired : .loneTapCancelled,
            handled: timer.trace.release.handled, occurred: timer.trace.release.occurred,
            attemptStartOccurred: timer.attemptStartOccurred, deadline: timer.trace.deadline),
          bareModifier: timer.observedBareModifier))
    #endif
  }

  /// Retire the pending timer from a reset: its resolution travels in its own batch, stamped
  /// with the CURRENT epoch so it is delivered.
  private static func cancelTimer(_ s: inout State, into work: inout TimerWork) {
    var effects: [Effect] = []
    cancelTimer(&s, into: &work, effects: &effects, retired: true)
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
    let (submit, observation) = state.withLock { s -> (Bool, GestureObservation?) in
      guard let timer = s.timer, timer.token == token else { return (false, nil) }
      s.timer = nil
      var effects: [Effect] = []
      let check = s.gesture.checkLoneTap(
        capturedGeneration: timer.capturedGeneration, binding: s.binding, mode: s.mode)
      var requestedAt: TimeInterval?
      if case .stop(let stop) = check {
        // #3534 §3.3, in this order: (1) snapshot (in checkLoneTap), (2) cleanup, (3) marker
        // with the post-cleanup epoch and the time read after cleanup.
        s.gesture.cleanup()
        let stoppedAt = clock()
        requestedAt = stoppedAt
        s.gesture.recordQuickTapStop(stop, stoppedAt: stoppedAt)
        effects.append(
          .loneTapStop(
            LoneTapStopTrace(
              quick: timer.trace, requestedAt: stoppedAt, attributable: stop.attributable)))
        #if DEBUG
          s.lastStopOrigin = stop.attributable ? timer.attemptStartOccurred : nil
        #endif
      }
      #if DEBUG
        let observation: GestureObservation? = Self.stamped(
          &s,
          GestureObservation(
            kind: .timer, keyCode: timer.observedKeyCode, outcome: GestureOutcome(check),
            handled: timer.trace.release.handled, occurred: timer.trace.release.occurred,
            attemptStartOccurred: timer.attemptStartOccurred, deadline: timer.trace.deadline,
            stopRequestedAt: requestedAt),
          bareModifier: timer.observedBareModifier)
      #else
        let observation: GestureObservation? = nil
        _ = requestedAt
      #endif
      effects.append(.loneTapResolved)
      s.outbox.append(Batch(epoch: s.epoch, attemptID: timer.attemptID, effects: effects))
      return (Self.claimAsyncDrain(&s), observation)
    }
    #if DEBUG
      if let observation { report([observation]) }
    #else
      _ = observation
    #endif
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
        let valid = Self.isValid(batch, in: s)
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
    state.withLock { Self.isValid(batch, in: $0) }
  }

  private static func isValid(_ batch: Batch, in s: State) -> Bool {
    batch.epoch == s.epoch && (!batch.attemptScoped || !s.refused.contains(batch.attemptID))
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
