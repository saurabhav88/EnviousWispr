import AppKit
import Foundation
import os

/// The keyboard listener's production ingress for one installation (#3544 P3): the only reader of
/// standalone modifier keys (`flagsChanged`) for every bare-modifier shortcut.
///
/// **Ownership.** One `KeyStateTracker` under one lock owns which keys are physically held for this
/// installation. Each press is classified under one coherent configuration read from the record
/// gesture engine together with the generation that identifies it, and its ROUTE is remembered by
/// key, so its release goes where the press went whatever the configuration is by then:
/// - the bare push-to-talk record key to `RecordGestureEngine.ingestFromListener`, on this thread,
///   so a busy main thread can never delay or reorder the gesture (#3534);
/// - the bare cancel key to `RecordGestureEngine.cancelFromListener`, in the same order as record
///   input (its release is the consumed tail of the cancel, and goes nowhere);
/// - Quick Add, Paste Last, Copy Last and toggle-mode record to main, through `toMain`, carrying the
///   installation and generation they were classified under.
///
/// **Why releases follow routes, not the matcher.** The deleted `NSEvent` path read aggregate,
/// device-independent flags, so with the other side's modifier held a key's release looked like a
/// press, and once cancel had disarmed itself the matcher handed that "press" to the next role that
/// claimed the key: one cancel gesture discarded the recording AND opened the Quick Add panel
/// (#2381). The tracker reads side bits, so a release is a release; and remembering the route at
/// the press means a release can never be reinterpreted as another role.
///
/// **Reconciliation** (plan §3.5, B3/B4, A2; #3544 P3 hotfix). A dictation is part of the heart
/// path and may run 60 minutes, so a READ of key state never ends one on a single answer. Held
/// state is checked against the injected key-state reader every 5 s while any key is held or the
/// engine still owns a record press, and a key is released only when two consecutive sweeps read it
/// up with no input between them. Evidence that events may have been missed (a confirmed tap
/// re-enable, Secure Input clearing, an event the tracker could not place) does not release
/// anything: it restarts that count, so the next two sweeps decide. The reader runs outside every
/// lock; its answers apply only if the installation, the configuration generation and the input
/// sequence are unchanged since it was asked. Down keeps, unknown changes nothing; age alone never
/// releases a key. Nothing here can start a recording, make a second press or lock a take.
///
/// **Held-record watchdog.** The sweep also asks about the key of the press the engine owns, even
/// when this installation never saw it (a listener replaced mid-hold), and releases it on the same
/// two consecutive up readings, so a lost key-up cannot leave push-to-talk recording forever.
///
/// **Which holds a reading may end** (#3544 P4 C2). Only a hold whose press carried its own side
/// bit (or Globe's function flag): the modifier-flags reader cannot see input without side bits,
/// and can read such a key up while it is still held. That evidence travels with the engine's
/// owned press (`ListenerPressRecovery`), so it survives listener replacement and absence, and a
/// release decided from a reading names its attempt, so it can never end a newer press. An
/// aggregate-only hold ends only on observed input, an explicit stop or cancel, or the recording
/// cap.
///
/// Our own synthetic events (`isOurs`) and key code 179 (a second Globe code some keyboards send,
/// Wispr Flow ignores it too) change nothing. Every event passes through to the system, with one
/// exception (#3517): a Space press that locks a held push-to-talk take is consumed, together with
/// the repeats and key-up of that same physical press (see `receive`).
package final class KeyboardListenerIngress: Sendable {

  /// A shortcut edge that executes on main.
  package struct MainEdge: Sendable, Equatable {
    package let role: ShortcutRole
    package let keyCode: UInt16
    package let isPress: Bool
    package let installation: UInt64
    /// The listener configuration generation the press was classified under.
    package let generation: UInt64
  }

  /// A decision already committed on the listener's side that field health reports (#3544 P6).
  /// Telemetry only: an observation never executes a shortcut, and it describes the moment it was
  /// made, so it is reported even after a rebind or a newer installation.
  package enum Observation: Sendable, Equatable {
    /// A push-to-talk press of the bare-modifier record key `keyCode` was refused because an
    /// ordinary key was held (`RecordGestureEngine.ListenerRefusal.ordinaryKeyHeld`).
    case startRefusedKeyHeld(keyCode: UInt16)
    /// A key-state reading removed a key the events still held, the first time this installation
    /// for that kind.
    case staleKeyCleared(StaleKind)
    /// macOS disabled this installation's tap and it was re-enabled, the first time this
    /// installation. Sent when it happens: the teardown row that totals disable episodes is often
    /// produced only at quit, when its capture is not guaranteed to leave.
    case tapReenabled
  }

  /// Which kind of held key a reading removed. Raw values are the telemetry strings.
  package enum StaleKind: String, Sendable, Equatable {
    case modifier, ordinary
  }

  /// How often held state is verified while anything is held.
  package static let sweepInterval: TimeInterval = 5
  /// Key code 179: a second code some keyboards send for Globe; never a shortcut.
  package static let ignoredGlobeKeyCode: UInt16 = 179

  private enum Route: Sendable, Equatable {
    case engine
    case cancel
    case main(ShortcutRole)
  }

  private enum Action: Sendable {
    /// `recovery`: for a press, whether a key-state reading may end it. `onlyAttempt`: for the
    /// watchdog's release, the attempt its reading was about.
    case engine(
      keyCode: UInt16, isPress: Bool, input: RecordGesture.InputTime, generation: UInt64,
      recovery: RecordGestureEngine.ListenerPressRecovery = .notReadable,
      onlyAttempt: UInt64? = nil, ordinaryKeyHeld: Bool = false)
    case cancel(keyCode: UInt16, generation: UInt64)
    case main(MainEdge)
    /// A fresh ordinary key press, for the engine's other-key dismissal (#3544 P4, D2). Carries
    /// no key identity: the engine needs only when it happened.
    case otherKey(input: RecordGesture.InputTime)
    /// A Space press that may lock a held push-to-talk take (#3517): the engine decides, and if it
    /// refuses, the key is any other ordinary key (`otherKey`). `token` names this decision so the
    /// invocation that queued it can learn its own answer (`drain(receiptFor:)`).
    case heldLock(input: RecordGesture.InputTime, generation: UInt64, token: UInt64)
  }

  /// What running one queued action produced: for a `heldLock`, whether the engine accepted it.
  private struct Receipt {
    let token: UInt64
    let accepted: Bool
  }

  /// Space (`kVK_Space`).
  private static let spaceKeyCode: UInt16 = 49

  private struct State: Sendable {
    var tracker = KeyStateTracker()
    var routes: [UInt16: Route] = [:]
    var inputSequence: UInt64 = 0
    var closed = false
    /// The pending sweep's token (set when armed, cleared when it fires) and its handle.
    var sweepPending: UInt64?
    var sweepHandle: RecordGestureEngine.TimerHandle?
    var nextSweepToken: UInt64 = 0
    /// Actions committed in the critical section that produced them, run oldest first by one
    /// drainer at a time outside the lock. Raw input and reconciliation run on different threads
    /// (the tap's and the sweep's); without one queue, a reconciled release committed before a
    /// newer press could still reach the engine after it, and the press would read as a duplicate.
    var pending: [Action] = []
    var draining = false
    /// Keys the previous sweep read up, and the input sequence it read them at. A sweep releases a
    /// key only when two consecutive sweeps read it up with no input between them, so a single wrong
    /// reading can never end a dictation (#3544 P3 hotfix). Cleared by any sign of missed events.
    var sweepReadUp: (sequence: UInt64, keys: Set<UInt16>) = (0, [])
    /// Ordinary-key state must be read before the next event acts (#3544 P4): set for a new
    /// installation (keys held across a replacement have no keyDown to come), and requested at a
    /// tap re-enable and Secure Input changing (keyDown and keyUp may have been lost), where the
    /// read runs at once. `resyncEpoch` advances with each request, so a resync that raced a newer
    /// one leaves it pending.
    var ordinaryResyncNeeded = true
    var resyncEpoch: UInt64 = 0
    /// Advanced by every ordinary key event. A reading of ordinary keys applies only if no ordinary
    /// event was handled while it was out: otherwise it could undo a newer keyDown.
    var ordinarySequence: UInt64 = 0
    /// Stale-key kinds this installation already reported (#3544 P6): one observation per kind.
    var staleReported: Set<StaleKind> = []
    /// Whether this installation already reported a tap re-enable (#3544 P6): one per installation.
    var reenableReported = false
    /// #3517: the physical Space press now down, named by a fresh token at every non-autorepeat
    /// keyDown (even when the previous press's keyUp was missed). Nil while Space is up.
    var spacePress: UInt64?
    var nextSpaceToken: UInt64 = 0
    /// The physical Space press whose events are being consumed because it locked a held take.
    /// Always equal to `spacePress` or nil: a newer press, its keyUp, any recovery boundary and a
    /// reading that proves Space up all end it.
    var suppressedSpace: UInt64?
    var nextActionToken: UInt64 = 0
  }

  package let installation: UInt64
  /// Test seam: runs after a reconciliation commits its actions and before it drains them, so a
  /// test can deliver newer input in exactly that window. Production never sets it.
  package let afterReconcileCommitForTesting: (@Sendable () -> Void)?
  /// Test seam: runs after the engine accepted a held-Space lock and before this invocation
  /// finalizes its suppression, outside every lock, so a test can deliver a reading, a boundary or
  /// a newer press in exactly that window. Production never sets it.
  package let afterHeldLockAcceptedForTesting: (@Sendable () -> Void)?
  package var pendingRecordEdgesForTesting: [Bool] {
    state.withLock { s in
      s.pending.compactMap { action in
        if case .engine(_, let press, _, _, _, _, _) = action { return press }
        return nil
      }
    }
  }
  private let engine: RecordGestureEngine
  private let reader: @Sendable (Set<UInt16>) -> [UInt16: KeyStateTracker.Reading]
  private let clock: RecordGestureEngine.Clock
  private let scheduler: RecordGestureEngine.Scheduler
  private let toMain: @Sendable (MainEdge) -> Void
  private let observe: @Sendable (Observation) -> Void
  private let state = OSAllocatedUnfairLock(initialState: State())

  package init(
    installation: UInt64, engine: RecordGestureEngine,
    reader: @escaping @Sendable (Set<UInt16>) -> [UInt16: KeyStateTracker.Reading],
    clock: @escaping RecordGestureEngine.Clock, scheduler: @escaping RecordGestureEngine.Scheduler,
    toMain: @escaping @Sendable (MainEdge) -> Void,
    observe: @escaping @Sendable (Observation) -> Void = { _ in },
    afterReconcileCommitForTesting: (@Sendable () -> Void)? = nil,
    afterHeldLockAcceptedForTesting: (@Sendable () -> Void)? = nil
  ) {
    self.installation = installation
    self.afterReconcileCommitForTesting = afterReconcileCommitForTesting
    self.afterHeldLockAcceptedForTesting = afterHeldLockAcceptedForTesting
    self.engine = engine
    self.reader = reader
    self.clock = clock
    self.scheduler = scheduler
    self.toMain = toMain
    self.observe = observe
  }

  // MARK: - Lifecycle

  /// The installation is live: start the watchdog if the engine already owns a record press (a
  /// hold that began under an earlier installation).
  package func start() {
    armSweepIfNeeded()
  }

  /// Every virtual key code that is not a standalone modifier, for an ordinary-key resync.
  private static let ordinaryKeyCodes: Set<UInt16> = Set(
    (0..<128).map(UInt16.init).filter { ModifierKeyCodes.flag(for: $0) == nil })

  /// The installation ended: no further input or sweep acts, and a pending sweep is cancelled.
  package func close() {
    let sweep = state.withLock { s -> RecordGestureEngine.TimerHandle? in
      s.closed = true
      s.pending.removeAll()
      Self.forgetSpace(&s)
      s.sweepPending = nil
      defer { s.sweepHandle = nil }
      return s.sweepHandle
    }
    sweep?.cancel()
  }

  // MARK: - Input (listener thread)

  /// One listener event, synchronously on the listener's thread. The answer says whether the event
  /// continues to the system: always `pass`, except for a Space press that locked a held
  /// push-to-talk take and the repeats and key-up of that same physical press (#3517).
  package func receive(_ event: KeyEventValue) -> KeyboardEventDisposition {
    switch event.kind {
    case .flagsChanged:
      ingest(event)
    case .tapReenabled:
      // Keys may have moved while the tap was off: the next two sweeps decide. A consumed Space's
      // key-up may have been lost with them, so its suppression ends here (fail open).
      forgetSpaceLocked()
      restartConfirmation()
      requestOrdinaryResync()
      resyncOrdinaryIfNeeded(except: nil)
      let first = state.withLock { s -> Bool in
        guard !s.closed, !s.reenableReported else { return false }
        s.reenableReported = true
        return true
      }
      if first { observe(.tapReenabled) }
    case .secureInputChanged:
      // Leaving Secure Input: key-ups may have been hidden (plan A2). Entering changes nothing
      // for modifiers; for ordinary keys both edges are boundaries, read now.
      guard let enabled = event.secureInput?.enabled else { return .pass }
      forgetSpaceLocked()
      if !enabled { restartConfirmation() }
      requestOrdinaryResync()
      resyncOrdinaryIfNeeded(except: nil)
    case .keyDown, .keyUp:
      return ingestOrdinary(event)
    case .stormStopped:
      forgetSpaceLocked()
    }
    return .pass
  }

  /// End any Space suppression and forget the physical Space press (recovery boundaries).
  private func forgetSpaceLocked() {
    state.withLock { Self.forgetSpace(&$0) }
  }

  private static func forgetSpace(_ s: inout State) {
    s.spacePress = nil
    s.suppressedSpace = nil
  }

  /// A reading that proves Space up ends its suppression in the same critical section that updates
  /// the tracker, so a decision still in flight cannot recreate it afterwards (#3517).
  private static func forgetSpaceIfUp(_ s: inout State) {
    guard !s.tracker.ordinaryDown.contains(spaceKeyCode) else { return }
    forgetSpace(&s)
  }

  /// One modifier event. Every admitted event advances the input sequence, which also restarts the
  /// sweep's two-reading count: an event the tracker could not place (a duplicate press, a release of
  /// a key never seen down, aggregate-only evidence for a held key) is left to the next two sweeps.
  private func ingest(_ event: KeyEventValue) {
    guard !event.isOurs, event.keyCode != Self.ignoredGlobeKeyCode else { return }
    let handled = clock()
    let classification = engine.listenerClassification()
    resyncOrdinaryIfNeeded(except: nil)
    state.withLock { s in
      guard !s.closed else { return }
      s.inputSequence &+= 1
      let update = s.tracker.ingest(
        event, handled: handled, configuration: classification.configuration)
      var actions: [Action] = []
      for edge in update.edges {
        route(&s, edge, classification, into: &actions)
      }
      s.pending.append(contentsOf: actions)
    }
    drain()
    armSweepIfNeeded()
  }

  /// Evidence that events may have been missed: forget any up reading, so a key is released only by
  /// two sweeps that both read it up after this point.
  private func restartConfirmation() {
    state.withLock { s in
      // Advancing the sequence also voids a sweep whose reader is out right now: its answer was
      // taken before this point and must not count.
      s.inputSequence &+= 1
      s.sweepReadUp.keys.removeAll()
    }
    armSweepIfNeeded()
  }

  /// Mark a recovery boundary for ordinary keys; the next event reads them before it acts.
  private func requestOrdinaryResync() {
    state.withLock { s in
      s.ordinaryResyncNeeded = true
      s.resyncEpoch &+= 1
    }
  }

  /// At a recovery boundary, read every ordinary key outside every lock and apply it before the
  /// event being handled acts (#3544 P4). The reading is the present: a key it removes still counts
  /// as held for any event that occurred before it (`KeyStateTracker.isOrdinaryKeyHeld`). `except`
  /// is the key of an ordinary event being handled, which applies itself.
  private func resyncOrdinaryIfNeeded(except: UInt16?) {
    let captured = state.withLock { s -> (epoch: UInt64, sequence: UInt64)? in
      guard !s.closed, s.ordinaryResyncNeeded else { return nil }
      return (s.resyncEpoch, s.ordinarySequence)
    }
    guard let captured else { return }
    let answers = reader(Self.ordinaryKeyCodes)
    let readAt = clock()
    let stale = state.withLock { s -> Observation? in
      // A stale reading leaves the resync pending: the next event asks again.
      guard !s.closed, s.ordinarySequence == captured.sequence else { return nil }
      let removed = s.tracker.resyncOrdinary(answers, at: readAt, except: except)
      Self.forgetSpaceIfUp(&s)
      if s.resyncEpoch == captured.epoch { s.ordinaryResyncNeeded = false }
      return Self.firstStale(&s, .ordinary, removed: removed)
    }
    if let stale { observe(stale) }
    armSweepIfNeeded()
  }

  /// What a Space event did in the critical section that classified it.
  private enum SpaceStep {
    case none
    /// An autorepeat or key-up of a press already being consumed.
    case tail
    /// A fresh press that may lock a held take; `token` names the queued decision, `press` the
    /// physical press it belongs to.
    case lock(token: UInt64, press: UInt64)
  }

  /// The bare record key's code, or nil when the record binding is not a bare modifier.
  private static func bareRecordKey(_ binding: ShortcutBinding) -> UInt16? {
    guard binding.isBareModifier, case .keyboard(let code, _) = binding else { return nil }
    return code
  }

  /// Whether `event` is a fresh Space press made with exactly the record key's own modifier down
  /// (#3517): the held key's device-independent flags equal that key's mapped flag, so Caps Lock,
  /// Function, Numeric Pad, Help or any other modifier family makes it the user's own chord. The
  /// other side of the same family is not distinguished (Right plus Left Option reads as Option).
  private static func isHeldLockCandidate(_ event: KeyEventValue, recordKey: UInt16?) -> Bool {
    guard event.kind == .keyDown, !event.isAutorepeat, event.keyCode == spaceKeyCode,
      let recordKey, let own = ModifierKeyCodes.flag(for: recordKey)
    else { return false }
    let held = NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: event.rawFlags))
      .intersection(.deviceIndependentFlagsMask)
    return held == own
  }

  /// One ordinary key event (#3544 P4). Updates the local ordinary-key state, and queues a fresh
  /// press for the engine's decision in input order with modifier events, unless the key and its
  /// modifiers match a configured, eligible chord shortcut (the user reaching for it, not
  /// interference). A fresh Space made with the record key's own modifier is first offered to the
  /// engine as a hands-free lock (#3517); only when the engine refuses is it an ordinary key, with
  /// the dismissal that implies. Nothing about the key leaves this function except the answer.
  ///
  /// The answer is `consume` only when THIS invocation's own drain ran the lock decision and the
  /// engine accepted it, and the physical Space press is still the one that was decided; a
  /// decision some other thread's drain ran (a sweep holding the queue) passes the Space through
  /// and installs nothing. Repeats and the key-up of a consumed press are consumed too, until that
  /// key-up or a recovery boundary ends it.
  private func ingestOrdinary(_ event: KeyEventValue) -> KeyboardEventDisposition {
    guard !event.isOurs else { return .pass }
    let handled = clock()
    let classification = engine.listenerClassification()
    let configuration = classification.configuration
    let isChord = configuration.bindings.matchesChord(
      keyCode: event.keyCode, rawFlags: event.rawFlags, armed: configuration.armed)
    let candidate = Self.isHeldLockCandidate(
      event, recordKey: Self.bareRecordKey(configuration.bindings.record))
    resyncOrdinaryIfNeeded(except: event.keyCode)
    let step = state.withLock { s -> SpaceStep in
      guard !s.closed else { return .none }
      s.ordinarySequence &+= 1
      var tail = false
      var press: UInt64?
      if event.keyCode == Self.spaceKeyCode {
        switch (event.kind, event.isAutorepeat) {
        case (.keyDown, true):
          tail = s.suppressedSpace != nil && s.suppressedSpace == s.spacePress
        case (.keyDown, false):
          // A new physical press, even if the previous key-up was missed.
          s.nextSpaceToken &+= 1
          s.spacePress = s.nextSpaceToken
          s.suppressedSpace = nil
          press = s.nextSpaceToken
        case (.keyUp, _):
          tail = s.suppressedSpace != nil && s.suppressedSpace == s.spacePress
          s.spacePress = nil
          s.suppressedSpace = nil
        default:
          break
        }
      }
      let fresh = s.tracker.ingestOrdinary(event)
      guard fresh, !isChord else { return tail ? .tail : .none }
      let input = RecordGesture.InputTime.accepting(stamp: event.timestamp, handled: handled)
      if candidate, let press {
        s.nextActionToken &+= 1
        let token = s.nextActionToken
        s.pending.append(.heldLock(input: input, generation: classification.generation, token: token))
        return .lock(token: token, press: press)
      }
      s.pending.append(.otherKey(input: input))
      return .none
    }
    switch step {
    case .none:
      drain()
      armSweepIfNeeded()
      return .pass
    case .tail:
      drain()
      armSweepIfNeeded()
      return .consume
    case .lock(let token, let press):
      let accepted = drain(receiptFor: token)
      armSweepIfNeeded()
      guard accepted else { return .pass }
      afterHeldLockAcceptedForTesting?()
      // Finalize in one critical section: still open, still the same physical press, and the
      // tracker still holds Space (a reading may have proved it up since). Never takes the engine
      // lock.
      return state.withLock { s -> KeyboardEventDisposition in
        guard !s.closed, s.spacePress == press,
          s.tracker.ordinaryDown.contains(Self.spaceKeyCode)
        else { return .pass }
        s.suppressedSpace = press
        return .consume
      }
    }
  }

  /// Turn one tracker edge into an action, remembering a press's route for its release.
  private func route(
    _ s: inout State, _ edge: KeyStateTracker.Edge,
    _ classification: RecordGestureEngine.ListenerClassification, into actions: inout [Action]
  ) {
    let input = RecordGesture.InputTime.accepting(stamp: edge.occurred, handled: edge.handled)
    let generation = classification.generation
    switch edge.phase {
    case .press:
      let route: Route?
      switch edge.role {
      case .record?:
        route = classification.mode == .pushToTalk ? .engine : .main(.record)
      case .cancel?:
        route = .cancel
      case .quickAdd?:
        route = .main(.quickAdd)
      case .pasteLast?:
        route = .main(.pasteLast)
      case .copyLast?:
        route = .main(.copyLast)
      case nil:
        route = nil
      }
      s.routes[edge.keyCode] = route
      switch route {
      case .engine?:
        // Only a press with its own side bit (or Globe's function flag) can be vouched for by the
        // modifier-flags reader later (#3544 P4 C2).
        let recovery: RecordGestureEngine.ListenerPressRecovery =
          edge.evidence == .aggregateOnly ? .notReadable : .readable
        // Exact-set start (#3544 P4): the engine refuses a press that would START a dictation while
        // an ordinary key is held; a stop, lock or second tap of a live take is never refused.
        actions.append(
          .engine(
            keyCode: edge.keyCode, isPress: true, input: input, generation: generation,
            recovery: recovery,
            ordinaryKeyHeld: s.tracker.isOrdinaryKeyHeld(
              occurred: edge.occurred, handled: edge.handled)))
      case .cancel?:
        actions.append(.cancel(keyCode: edge.keyCode, generation: generation))
      case .main(let role)?:
        actions.append(.main(mainEdge(role, edge.keyCode, isPress: true, generation)))
      case nil:
        break
      }
    case .release:
      switch s.routes.removeValue(forKey: edge.keyCode) {
      case .engine?:
        actions.append(
          .engine(keyCode: edge.keyCode, isPress: false, input: input, generation: generation))
      case .main(let role)?:
        actions.append(.main(mainEdge(role, edge.keyCode, isPress: false, generation)))
      case .cancel?, nil:
        // A cancel's release is the tail of the gesture it already ended; an unrouted key's
        // release has nothing to end.
        break
      }
    }
  }

  private func mainEdge(
    _ role: ShortcutRole, _ keyCode: UInt16, isPress: Bool, _ generation: UInt64
  ) -> MainEdge {
    MainEdge(
      role: role, keyCode: keyCode, isPress: isPress, installation: installation,
      generation: generation)
  }

  /// Run committed actions oldest first, outside every lock, one drainer at a time; an action
  /// committed while another thread drains is run by that drainer, in order.
  ///
  /// `receiptFor`: the token of a `heldLock` this invocation queued. Returns whether THIS
  /// invocation ran that action and the engine accepted it; false when another drainer owns the
  /// queue (it runs the action in order, but this caller cannot know the answer in time) or the
  /// engine refused. The answer is collected locally, never from a shared box.
  @discardableResult
  private func drain(receiptFor token: UInt64? = nil) -> Bool {
    let start = state.withLock { s -> Bool in
      guard !s.draining else { return false }
      s.draining = true
      return true
    }
    guard start else { return false }
    var accepted = false
    while true {
      let next = state.withLock { s -> Action? in
        guard !s.closed, !s.pending.isEmpty else {
          s.pending.removeAll()
          s.draining = false
          return nil
        }
        return s.pending.removeFirst()
      }
      guard let next else { return accepted }
      if let receipt = perform(next), receipt.token == token { accepted = receipt.accepted }
    }
  }

  @discardableResult
  private func perform(_ action: Action) -> Receipt? {
    switch action {
    case .engine(
      let keyCode, let isPress, let input, let generation, let recovery, let onlyAttempt,
      let ordinaryKeyHeld):
      let refusal = engine.ingestFromListener(
        keyCode: keyCode, isPress: isPress, input: input, generation: generation,
        installation: installation, recovery: recovery, onlyAttempt: onlyAttempt,
        ordinaryKeyHeld: ordinaryKeyHeld)
      if isPress, refusal == .ordinaryKeyHeld { observe(.startRefusedKeyHeld(keyCode: keyCode)) }
    case .cancel(let keyCode, let generation):
      engine.cancelFromListener(
        keyCode: keyCode, generation: generation, installation: installation)
    case .main(let edge):
      toMain(edge)
    case .otherKey(let input):
      engine.otherKeyFromListener(input: input, installation: installation)
    case .heldLock(let input, let generation, let token):
      if engine.lockHeldFromListener(
        input: input, installation: installation, generation: generation)
      {
        return Receipt(token: token, accepted: true)
      }
      // Not a lock: this Space is any other ordinary key, with today's dismissal.
      engine.otherKeyFromListener(input: input, installation: installation)
      return Receipt(token: token, accepted: false)
    }
    return nil
  }

  // MARK: - Reconciliation

  /// One sweep: verify held state against the reader. An up answer releases a key only when the
  /// previous sweep read it up too, with no input and no sign of missed events between them.
  private func reconcile() {
    reconcileOrdinary()
    let classification = engine.listenerClassification()
    // The watchdog asks only about an owned press a reading may end (#3544 P4 C2).
    let owned = engine.ownedListenerPress.flatMap { $0.recovery == .readable ? $0 : nil }
    guard
      let captured = state.withLock({ s -> (sequence: UInt64, held: Set<UInt16>)? in
        s.closed ? nil : (s.inputSequence, Set(s.tracker.held.keys))
      })
    else { return }
    var keys = captured.held
    if let owned { keys.insert(owned.keyCode) }
    guard !keys.isEmpty else { return }
    // Outside every lock: the reader is an OS call in production.
    let answers = reader(keys)
    let handled = clock()
    let stale = state.withLock { s -> Observation? in
      // Stale answers are dropped, never applied: the next sweep asks again.
      guard !s.closed, s.inputSequence == captured.sequence,
        engine.listenerConfigurationGeneration == classification.generation
      else {
        // A rejected sweep breaks the run of consecutive readings too.
        s.sweepReadUp.keys.removeAll()
        return nil
      }
      var answers = answers
      let previous =
        s.sweepReadUp.sequence == captured.sequence ? s.sweepReadUp.keys : Set<UInt16>()
      var readUp = Set<UInt16>()
      for (key, answer) in answers where answer == .up {
        readUp.insert(key)
        if !previous.contains(key) { answers[key] = .unknown }
      }
      // A key released now starts no count of its own.
      s.sweepReadUp = (captured.sequence, readUp.subtracting(previous))
      var actions: [Action] = []
      let edges = s.tracker.reconcile(
        handled: handled, configuration: classification.configuration
      ) { _ in answers }
      for edge in edges { route(&s, edge, classification, into: &actions) }
      // The watchdog: a record press the engine owns that this installation never saw down.
      if let owned, !captured.held.contains(owned.keyCode), answers[owned.keyCode] == .up {
        actions.append(
          .engine(
            keyCode: owned.keyCode, isPress: false,
            input: RecordGesture.InputTime(handled: handled, occurred: nil),
            generation: classification.generation, onlyAttempt: owned.attemptID))
      }
      s.pending.append(contentsOf: actions)
      // Every tracker edge here is a held modifier a reading removed (`.reconciled`); the
      // watchdog's release above is an engine hold the tracker never had, so it does not count.
      return Self.firstStale(&s, .modifier, removed: edges.count)
    }
    if let stale { observe(stale) }
    afterReconcileCommitForTesting?()
    drain()
  }

  /// The sweep's ordinary-key part (#3544 P4): a key the events still say is down but that reads
  /// up lost its keyUp (Secure Input that came and went between samples, a tap that was off); it
  /// is removed, remembered with the reading time so no event that occurred earlier is affected.
  /// One reading suffices: ordinary keys read reliably, and a wrong answer can only allow a start.
  private func reconcileOrdinary() {
    let captured = state.withLock { s -> (keys: Set<UInt16>, sequence: UInt64) in
      (s.closed ? [] : s.tracker.ordinaryDown, s.ordinarySequence)
    }
    guard !captured.keys.isEmpty else { return }
    let answers = reader(captured.keys)
    let readAt = clock()
    let stale = state.withLock { s -> Observation? in
      // A stale reading is dropped, never applied: the next sweep asks again.
      guard !s.closed, s.ordinarySequence == captured.sequence else { return nil }
      let removed = s.tracker.resyncOrdinary(answers.filter { $0.value == .up }, at: readAt)
      Self.forgetSpaceIfUp(&s)
      return Self.firstStale(&s, .ordinary, removed: removed)
    }
    if let stale { observe(stale) }
  }

  /// The observation for the first `removed` > 0 of `kind` in this installation, marking it
  /// reported; nil otherwise.
  private static func firstStale(_ s: inout State, _ kind: StaleKind, removed: Int) -> Observation? {
    guard removed > 0, s.staleReported.insert(kind).inserted else { return nil }
    return .staleKeyCleared(kind)
  }

  // MARK: - Sweep

  /// Schedule the next sweep when something is held and none is pending.
  private func armSweepIfNeeded() {
    let ownedByEngine = engine.ownedListenerKey != nil
    let token = state.withLock { s -> UInt64? in
      guard !s.closed, s.sweepPending == nil,
        !s.tracker.held.isEmpty || ownedByEngine || !s.tracker.ordinaryDown.isEmpty
      else {
        return nil
      }
      s.nextSweepToken &+= 1
      s.sweepPending = s.nextSweepToken
      return s.nextSweepToken
    }
    guard let token else { return }
    let handle = scheduler(Self.sweepInterval) { [weak self] in self?.sweepFired(token) }
    // Kept only while this sweep is still the pending one; one that already fired or was closed
    // needs no cancel handle.
    let stale = state.withLock { s -> Bool in
      guard s.sweepPending == token else { return true }
      s.sweepHandle = handle
      return false
    }
    if stale { handle.cancel() }
  }

  private func sweepFired(_ token: UInt64) {
    let current = state.withLock { s -> Bool in
      guard !s.closed, s.sweepPending == token else { return false }
      s.sweepPending = nil
      s.sweepHandle = nil
      return true
    }
    guard current else { return }
    reconcile()
    armSweepIfNeeded()
  }

  // MARK: - Tests

  /// Test seam: the keys this installation sees held.
  package var heldKeysForTesting: Set<UInt16> {
    state.withLock { Set($0.tracker.held.keys) }
  }
}
