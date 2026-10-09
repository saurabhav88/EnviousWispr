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
    /// Another key went down within `otherKeyDismissalWindow` of an unlocked push-to-talk press
    /// (#3544 P4, D2). The engine already ended the attempt; main dismisses that attempt's
    /// recording only, destructively.
    case dismiss(Dismiss)
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
    /// A `.start` made while a session was running (#3544 P4): main calls `onJoinRecording` for it.
    package var joinsRecording = false
    /// For a joining `.start`: whether it may make a fresh take if that session has already ended
    /// by the time main runs it. True only when no ordinary key was held at the press, so typing
    /// protection (which a joining press skips) would not have refused it either.
    package var mayStartIfJoinFails = false
  }

  package struct Cancel: Sendable {
    package let keyCode: UInt16
    /// The attempt that was live when the cancel arrived, or nil when none was.
    package let attemptID: UInt64?
  }

  package struct Dismiss: Sendable, Equatable {
    /// The attempt the dismissed press started.
    package let attemptID: UInt64
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

  /// What the listener's next input is classified under, read in one critical section with the
  /// generation that identifies it (#3544 P3): every role's binding, the armed roles, and the mode.
  package struct ListenerClassification: Sendable, Equatable {
    package let configuration: KeyStateTracker.Configuration
    package let mode: RecordingMode
    package let generation: UInt64
  }

  /// Why the engine refused a listener input. A refused input changes no state.
  /// Whether a key-state reading may end a listener press (#3544 P4 C2). The production reader
  /// is the system's modifier flags, which can vouch only for a key whose press carried its own
  /// side bit (or Globe's function flag); a press seen only as aggregate family evidence
  /// (synthetic or no-side-bit input) reads unknown while held and can read up while still held,
  /// so no reading ends it.
  package enum ListenerPressRecovery: Sendable, Equatable {
    case readable
    case notReadable
  }

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
    /// A press that would start a new dictation while an ordinary key is held (#3544 P4,
    /// exact-set start). Never refuses a press of a live take (second tap, locked stop).
    case ordinaryKeyHeld
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
    /// Whether the wait's fire is delivered through the main queue: true when the release that
    /// armed it came through main (Carbon chords until P5), so the decision queues behind key events
    /// main already holds (#3544 P1). Captured when armed, so a later rebind cannot change it.
    let viaMain: Bool
    var handle: TimerHandle?
  }

  /// The press whose release the listener may deliver: its key and the attempt it belonged to.
  private struct OwnedPress: Sendable {
    let keyCode: UInt16
    let attemptID: UInt64
    /// Admitted through main (Carbon chords until P5): never the listener's to release, so the
    /// held-record watchdog leaves it alone.
    let fromMain: Bool
    /// Whether a key-state reading may end this hold (#3544 P4 C2). Kept with the attempt, so it
    /// survives listener replacement and absence.
    let recovery: ListenerPressRecovery
  }

  /// The listener-owned record press a held-record check may ask about: its key, its attempt, and
  /// whether a key-state reading may end it.
  package struct OwnedListenerPress: Sendable, Equatable {
    package let keyCode: UInt16
    package let attemptID: UInt64
    package let recovery: ListenerPressRecovery
  }

  private struct State: Sendable {
    var gesture = RecordGesture()
    var binding: ShortcutBinding
    var mode: RecordingMode
    /// Every role's binding, as the listener classifies keys; `binding` is always
    /// `bindings.record`, written together by `configure(bindings:mode:)`.
    var bindings: ShortcutBindings
    var cancelArmed = false
    /// Whether the active pipeline is running a session now (`PipelineState.isActive`, the same
    /// test `RecordingStarter.start()` uses to join one), as the dictation lifecycle reports it.
    /// Not cleared by suspend, resume, restart or reset: it is the pipeline's, not the shortcuts'.
    var recordingActive = false
    /// The attempt whose `.start` found a session running (one started from the menu, the main
    /// window or an earlier take), so it only joins it (#3544 P4): other-key interference never
    /// ends it, and its press keeps its stop and lock. Kept by attempt, not by press: a quick
    /// release clears `owned`, and the attempt's second tap must still be joining. Also set by
    /// `markJoined` when main finds a start joined a session that began after the press.
    var joinedAttempt: UInt64?
    /// This engine has already decided the running session's ending (a hold stop, a lone-tap stop,
    /// a locked stop, a triple-press cancel, a listener cancel or an other-key dismissal), so that
    /// session is on its way out: the next `.start` is a fresh take,
    /// not a join, even if the pipeline has not reported the session over yet. Cleared when it
    /// does, or consumed by that next `.start`.
    var endingRequested = false
    /// Bumped on every ACTUAL change of record binding, mode or any role's binding, and by the
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
  }

  private let state: OSAllocatedUnfairLock<State>
  private let clock: Clock
  private let scheduler: Scheduler
  private let hopsMainInput: Bool

  /// `hopsMainInput`: deliver lone-tap waits armed by main-thread input through the main queue
  /// (the service's setting; see `perform`). Off by default for engine-only tests.
  package init(
    binding: ShortcutBinding, mode: RecordingMode, clock: @escaping Clock,
    scheduler: @escaping Scheduler = RecordGestureEngine.liveScheduler,
    hopsMainInput: Bool = false
  ) {
    var bindings = ShortcutBindings.shipped
    bindings.record = binding
    state = OSAllocatedUnfairLock(
      initialState: State(binding: binding, mode: mode, bindings: bindings))
    self.clock = clock
    self.scheduler = scheduler
    self.hopsMainInput = hopsMainInput
  }

  /// The main-thread executor. Set once by `HotkeyService` after it is initialized.
  package func setSink(_ sink: @escaping @MainActor @Sendable (Batch, _ valid: Bool) -> Void) {
    state.withLock { $0.sink = sink }
  }

  // MARK: - Configuration and reads

  /// The record binding and mode the gesture reads (attempt origin, stop-marker attribution, the
  /// lone-tap check). Pushed on every change; diagnostics are invalidated separately, by
  /// `invalidateDiagnostics()`, only on an ACTUAL change (unchanged assignments are free).
  /// The one writer of every role's binding and the mode, in one critical section, so the
  /// listener can never classify under one role's new binding and another's old one (#3544 P3).
  /// The gesture reads `bindings.record`. An actual change starts a new listener generation; an
  /// equal assignment does not (settings assign unchanged values freely, and a harmless repeat
  /// must never strand a held key's release).
  package func configure(bindings: ShortcutBindings, mode: RecordingMode) {
    state.withLock { s in
      if s.bindings != bindings || s.mode != mode { s.listenerConfigurationGeneration &+= 1 }
      s.bindings = bindings
      s.binding = bindings.record
      s.mode = mode
    }
  }

  /// The configuration the listener classifies its next input under, and the generation that
  /// identifies it, read together.
  package func listenerClassification() -> ListenerClassification {
    state.withLock { s in
      ListenerClassification(
        configuration: KeyStateTracker.Configuration(
          bindings: s.bindings, armed: ShortcutRole.armedRoles(cancelArmed: s.cancelArmed)),
        mode: s.mode, generation: s.listenerConfigurationGeneration)
    }
  }

  /// The key of the press whose release the listener may still deliver, or nil: whether a
  /// held-record check has anything to watch.
  package var ownedListenerKey: UInt16? {
    ownedListenerPress?.keyCode
  }

  /// The press whose release the listener may still deliver, or nil. Read by the held-record
  /// watchdog and the orphaned-hold check, which must cover a hold the listener's own state has
  /// lost; they may release it from a reading only when `recovery` is `.readable`.
  package var ownedListenerPress: OwnedListenerPress? {
    state.withLock { s in
      guard let owned = s.owned, !owned.fromMain else { return nil }
      return OwnedListenerPress(
        keyCode: owned.keyCode, attemptID: owned.attemptID, recovery: owned.recovery)
    }
  }

  /// Whether cancel is armed now. Checked when a listener cancel is admitted, not part of the
  /// generation: arming happens as a recording starts, and a record press classified a moment
  /// before must not be refused for it.
  package func setCancelArmed(_ armed: Bool) {
    state.withLock { $0.cancelArmed = armed }
  }

  /// Main found that `attempt`'s start joined a session that began after its press (#3544 P4): it
  /// is a joining attempt from now on. A dismissal already decided for it stands; the controller
  /// still refuses to cancel the joined session.
  package func markJoined(attempt: UInt64) {
    state.withLock { s in
      guard s.gesture.attemptID == attempt else { return }
      s.joinedAttempt = attempt
    }
  }

  /// Main found the session `attempt` was to join already over and is starting a fresh take for
  /// it instead (#3544 P4): it is that take's own attempt now, so interference applies again.
  package func unmarkJoined(attempt: UInt64) {
    state.withLock { s in
      if s.joinedAttempt == attempt { s.joinedAttempt = nil }
    }
  }

  /// Whether a session is running now (#3544 P4): a fresh record press made while one is joins it.
  package func setRecordingActive(_ active: Bool) {
    state.withLock { s in
      s.recordingActive = active
      if !active { s.endingRequested = false }
    }
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

  package var snapshot: Snapshot {
    state.withLock { Snapshot(isHeld: $0.gesture.isHeld, isLocked: $0.gesture.isLocked) }
  }

  // MARK: - Ingest

  /// A record-key press or release from any thread. Its effects reach the main thread through
  /// the pending async drain.
  package func ingest(isPress: Bool, input: RecordGesture.InputTime) {
    let (work, submit) = state.withLock { s -> (TimerWork, Bool) in
      let work = Self.admit(
        &s, isPress: isPress, input: input, fromMain: false, recovery: .notReadable)
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
      Self.admit(&s, isPress: isPress, input: input, fromMain: true, recovery: .notReadable)
    }
    perform(work)
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
  ///
  /// `recovery`: for a press, whether a key-state reading may later end it; omitted, it may not.
  /// `onlyAttempt`: for a release decided from a reading, the attempt that reading was about; a
  /// newer attempt of the same key refuses it.
  package func ingestFromListener(
    keyCode: UInt16, isPress: Bool, input: RecordGesture.InputTime, generation: UInt64,
    installation: UInt64, recovery: ListenerPressRecovery = .notReadable,
    onlyAttempt: UInt64? = nil, ordinaryKeyHeld: Bool = false
  ) -> ListenerRefusal? {
    let (refusal, work, submit) = state.withLock { s -> (ListenerRefusal?, TimerWork, Bool) in
      if let refusal = Self.refusal(
        &s, keyCode: keyCode, isPress: isPress,
        generation: generation, installation: installation)
        ?? Self.staleAttempt(s, onlyAttempt)
        ?? Self.startWhileTyping(s, isPress: isPress, ordinaryKeyHeld: ordinaryKeyHeld)
      {
        s.refusals[refusal, default: 0] += 1
        return (refusal, TimerWork(), false)
      }
      let work = Self.admit(
        &s, isPress: isPress, input: input, fromMain: false, recovery: recovery,
        ordinaryKeyHeld: ordinaryKeyHeld)
      return (nil, work, Self.claimAsyncDrain(&s))
    }
    perform(work)
    if submit { submitAsyncDrain() }
    return refusal
  }

  /// The release of the listener-owned record press `keyCode`, read from key state while no
  /// listener is installed (storm cooldown, failed installs). It ends only the hold a removed
  /// listener left behind, so it needs no installation; it can never start anything. Returns
  /// whether that press was owned and is now released.
  @discardableResult
  package func releaseOrphanedListenerPress(
    _ press: OwnedListenerPress, input: RecordGesture.InputTime
  ) -> Bool {
    let (released, work, submit) = state.withLock { s -> (Bool, TimerWork, Bool) in
      guard s.listenerInstallation == nil, let owned = s.owned, !owned.fromMain,
        owned.keyCode == press.keyCode, owned.attemptID == press.attemptID,
        owned.recovery == .readable
      else { return (false, TimerWork(), false) }
      let work = Self.admit(&s, isPress: false, input: input, fromMain: false, recovery: .notReadable)
      return (true, work, Self.claimAsyncDrain(&s))
    }
    perform(work)
    if submit { submitAsyncDrain() }
    return released
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
        } else if !s.bindings.cancel.isBareModifier || Self.key(s.bindings.cancel) != keyCode
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
      s.endingRequested = true
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
    if submit { submitAsyncDrain() }
    return refusal
  }

  /// How long after an unlocked push-to-talk press another key still dismisses it (#3544 P4, D2;
  /// Wispr Flow's 1000 ms). Measured between the two events' own times, from the record press.
  package static let otherKeyDismissalWindow: TimeInterval = 1.0

  /// Another (non-shortcut) key went down, as the listener observed it (#3544 P4, D2). When the
  /// bare push-to-talk record press this installation's listener admitted is still held, not
  /// locked, and less than `otherKeyDismissalWindow` old at `input` (strictly below: a key at
  /// exactly 1000 ms is late), its attempt is ended here, in input order, and a `.dismiss` effect
  /// queued. Its later release is then unowned and inert. Returns whether it dismissed.
  @discardableResult
  package func otherKeyFromListener(
    input: RecordGesture.InputTime, installation: UInt64
  ) -> Bool {
    let (dismissed, work, submit) = state.withLock { s -> (Bool, TimerWork, Bool) in
      guard s.listenerInstallation == installation, s.mode == .pushToTalk,
        let owned = s.owned, !owned.fromMain, s.joinedAttempt != owned.attemptID,
        owned.attemptID == s.gesture.attemptID,
        s.gesture.isHeld, !s.gesture.isLocked, let start = s.gesture.start,
        Self.elapsed(from: start, to: input) < Self.otherKeyDismissalWindow
      else { return (false, TimerWork(), false) }
      let attempt = s.gesture.attemptID
      var work = TimerWork()
      var effects: [Effect] = []
      s.endingRequested = true
      s.gesture.cleanup()
      // The record key is still physically down, but its release is now unowned and refused, so
      // the gesture must stop counting it as held: otherwise the next press reads as a duplicate.
      s.gesture.forgetHeld()
      s.owned = nil
      Self.cancelTimer(&s, into: &work, effects: &effects, retired: true)
      effects.append(.dismiss(Dismiss(attemptID: attempt)))
      s.outbox.append(Batch(epoch: s.epoch, attemptID: attempt, effects: effects))
      return (true, work, Self.claimAsyncDrain(&s))
    }
    perform(work)
    if submit { submitAsyncDrain() }
    return dismissed
  }

  /// Whether the other-key rule would still dismiss the current take at handling time `now`
  /// (#3544 P4): a listener-owned push-to-talk press of the live attempt, held, not locked, and
  /// less than `otherKeyDismissalWindow` old by handling time. Read by the Secure Input notice,
  /// which may only say keyboard features are paused while one is.
  package func otherKeyRuleApplies(at now: TimeInterval) -> Bool {
    state.withLock { s in
      guard s.mode == .pushToTalk, let owned = s.owned, !owned.fromMain,
        s.joinedAttempt != owned.attemptID,
        owned.attemptID == s.gesture.attemptID, s.gesture.isHeld, !s.gesture.isLocked,
        let start = s.gesture.start
      else { return false }
      return now - start.handled < Self.otherKeyDismissalWindow
    }
  }

  /// Seconds from `start` to `input` under the gesture's own clock policy (#3534): event times
  /// when both carry one and they run forward, otherwise handling times.
  private static func elapsed(
    from start: RecordGesture.InputTime, to input: RecordGesture.InputTime
  ) -> TimeInterval {
    RecordGesture.elapsed(from: start, to: input)
  }

  /// Why a listener record input is refused, or nil to admit it.
  /// A press that would START a dictation (no live attempt, nothing locked, no recording already
  /// running) while an ordinary key is held is refused before it touches the gesture (#3544 P4). A
  /// press of a live take (the second tap of a double tap, the stop of a locked take, a press that
  /// joins a running recording) is never refused, so a held key can never trap a recording.
  private static func startWhileTyping(
    _ s: State, isPress: Bool, ordinaryKeyHeld: Bool
  ) -> ListenerRefusal? {
    guard isPress, ordinaryKeyHeld, s.gesture.start == nil, !s.gesture.isLocked,
      !startWouldJoin(s)
    else { return nil }
    return .ordinaryKeyHeld
  }

  /// Whether a fresh start now would join a running session rather than make one (#3544 P4): a
  /// session is running and it is not one this engine already ended. The one test for both the
  /// join classification and the typing-protection exemption, so they cannot disagree.
  private static func startWouldJoin(_ s: State) -> Bool {
    s.recordingActive && !s.endingRequested
  }

  /// A release decided from a reading about `onlyAttempt`, arriving after a newer attempt took the
  /// key: refused, so a stale reading can never end the newer press.
  private static func staleAttempt(_ s: State, _ onlyAttempt: UInt64?) -> ListenerRefusal? {
    guard let onlyAttempt else { return nil }
    return s.owned?.attemptID == onlyAttempt ? nil : .unownedRelease
  }

  private static func refusal(
    _ s: inout State, keyCode: UInt16, isPress: Bool, generation: UInt64, installation: UInt64
  ) -> ListenerRefusal? {
    guard s.listenerInstallation == installation else { return .staleInstallation }
    if !isPress {
      guard let owned = s.owned, !owned.fromMain, owned.keyCode == keyCode else {
        return .unownedRelease
      }
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
    var schedule: (token: UInt64, delay: TimeInterval, viaMain: Bool)?
  }

  private static func admit(
    _ s: inout State, isPress: Bool, input: RecordGesture.InputTime, fromMain: Bool,
    recovery: ListenerPressRecovery, ordinaryKeyHeld: Bool = false
  ) -> TimerWork {
    s.inputSequence &+= 1
    let sequence = s.inputSequence
    var work = TimerWork()
    var effects: [Effect] = []
    let keyCode: UInt16
    switch s.binding {
    case .keyboard(let code, _): keyCode = code
    }
    if isPress {
      guard
        case .admitted(let afterStopTimerMs) = s.gesture.admitPress(
          input, binding: s.binding, mode: s.mode)
      else {
        // A duplicate leaves the earlier press's ownership in place.
        return work
      }
      let decision = s.gesture.classifyPress(input, binding: s.binding, mode: s.mode)
      if case .start = decision {
        s.joinedAttempt = Self.startWouldJoin(s) ? s.gesture.attemptID : nil
        s.endingRequested = false
      }
      let joinsRecording = s.joinedAttempt == s.gesture.attemptID
      // The held key's release follows this press, whatever the configuration is by then.
      s.owned = OwnedPress(
        keyCode: keyCode, attemptID: s.gesture.attemptID, fromMain: fromMain, recovery: recovery)
      switch decision {
      case .start, .lockIntent:
        // A fresh attempt or a lock: the pending lone-tap stop no longer applies.
        cancelTimer(&s, into: &work, effects: &effects)
      case .tripleCancel, .stopLocked:
        // The engine applies its own cleanup; main clears only its execution state.
        s.endingRequested = true
        s.gesture.cleanup()
        cancelTimer(&s, into: &work, effects: &effects)
      case .ignoredCooldown, .lateAfterWindow:
        break
      }
      effects.append(
        .press(
          Press(
            inputSequence: sequence, mode: s.mode, keyCode: keyCode, input: input,
            afterStopTimerMs: afterStopTimerMs, decision: decision,
            joinsRecording: joinsRecording, mayStartIfJoinFails: !ordinaryKeyHeld)))
    } else {
      s.owned = nil
      let decision = s.gesture.release(input)
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
        s.timer = PendingTimer(
          token: token, attemptID: s.gesture.attemptID,
          capturedGeneration: quick.capturedGeneration, trace: trace,
          viaMain: fromMain, handle: nil)
        work.schedule = (token, quick.deadline, fromMain)
        effects.append(.quickRelease(trace))
      case .hold:
        s.endingRequested = true
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
    guard let (token, deadline, viaMain) = work.schedule else { return }
    // #3534: compute the remaining wait now; request no further wait if the deadline has passed.
    let fire: @Sendable () -> Void = { [weak self] in self?.timerFired(token) }
    // #3544 P1: a wait armed by input that came through main (Carbon chords until P5) delivers its
    // decision through the main queue, so it queues BEHIND any key event main already holds, as
    // the old main-actor timer task did; deciding on the timer queue would stop a valid double
    // tap whose second press is still waiting on a busy main thread. Listener-fed input (P3)
    // never waits on main, so its wait decides on the timer queue.
    let hop = viaMain && hopsMainInput
    let handle = scheduler(max(0, deadline - clock())) {
      if hop { DispatchQueue.main.async(execute: fire) } else { fire() }
    }
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
      let check = s.gesture.checkLoneTap(
        capturedGeneration: timer.capturedGeneration, binding: s.binding, mode: s.mode)
      if case .stop(let stop) = check {
        // #3534 §3.3, in this order: (1) snapshot (in checkLoneTap), (2) cleanup, (3) marker
        // with the post-cleanup epoch and the time read after cleanup.
        s.endingRequested = true
        s.gesture.cleanup()
        let stoppedAt = clock()
        s.gesture.recordQuickTapStop(stop, stoppedAt: stoppedAt)
        effects.append(
          .loneTapStop(
            LoneTapStopTrace(
              quick: timer.trace, requestedAt: stoppedAt, attributable: stop.attributable)))
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
      let next = state.withLock {
        s -> (Batch, Bool, (@MainActor @Sendable (Batch, Bool) -> Void)?)? in
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
