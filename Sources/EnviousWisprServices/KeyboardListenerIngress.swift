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
/// Wispr Flow ignores it too) change nothing. Every event passes through to the system in P3.
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
  }

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
  }

  package let installation: UInt64
  /// Test seam: runs after a reconciliation commits its actions and before it drains them, so a
  /// test can deliver newer input in exactly that window. Production never sets it.
  package let afterReconcileCommitForTesting: (@Sendable () -> Void)?
  private let engine: RecordGestureEngine
  private let reader: @Sendable (Set<UInt16>) -> [UInt16: KeyStateTracker.Reading]
  private let clock: RecordGestureEngine.Clock
  private let scheduler: RecordGestureEngine.Scheduler
  private let toMain: @Sendable (MainEdge) -> Void
  private let state = OSAllocatedUnfairLock(initialState: State())

  package init(
    installation: UInt64, engine: RecordGestureEngine,
    reader: @escaping @Sendable (Set<UInt16>) -> [UInt16: KeyStateTracker.Reading],
    clock: @escaping RecordGestureEngine.Clock, scheduler: @escaping RecordGestureEngine.Scheduler,
    toMain: @escaping @Sendable (MainEdge) -> Void,
    afterReconcileCommitForTesting: (@Sendable () -> Void)? = nil
  ) {
    self.installation = installation
    self.afterReconcileCommitForTesting = afterReconcileCommitForTesting
    self.engine = engine
    self.reader = reader
    self.clock = clock
    self.scheduler = scheduler
    self.toMain = toMain
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
      s.sweepPending = nil
      defer { s.sweepHandle = nil }
      return s.sweepHandle
    }
    sweep?.cancel()
  }

  // MARK: - Input (listener thread)

  /// One listener event, synchronously on the listener's thread.
  package func receive(_ event: KeyEventValue) {
    switch event.kind {
    case .flagsChanged:
      ingest(event)
    case .tapReenabled:
      // Keys may have moved while the tap was off: the next two sweeps decide.
      restartConfirmation()
      requestOrdinaryResync()
      resyncOrdinaryIfNeeded(except: nil)
    case .secureInputChanged:
      // Leaving Secure Input: key-ups may have been hidden (plan A2). Entering changes nothing
      // for modifiers; for ordinary keys both edges are boundaries, read now.
      guard let enabled = event.secureInput?.enabled else { return }
      if !enabled { restartConfirmation() }
      requestOrdinaryResync()
      resyncOrdinaryIfNeeded(except: nil)
    case .keyDown, .keyUp:
      ingestOrdinary(event)
    case .stormStopped:
      break
    }
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
    let epoch = state.withLock { s -> UInt64? in
      guard !s.closed, s.ordinaryResyncNeeded else { return nil }
      return s.resyncEpoch
    }
    guard let epoch else { return }
    let answers = reader(Self.ordinaryKeyCodes)
    let readAt = clock()
    state.withLock { s in
      guard !s.closed else { return }
      s.tracker.resyncOrdinary(answers, at: readAt, except: except)
      if s.resyncEpoch == epoch { s.ordinaryResyncNeeded = false }
    }
    armSweepIfNeeded()
  }

  /// One ordinary key event (#3544 P4). Updates the local ordinary-key state, and queues a fresh
  /// press for the engine's dismissal decision in input order with modifier events, unless the key
  /// and its modifiers match a configured, eligible chord shortcut (the user reaching for it, not
  /// interference). Nothing about the key leaves this function.
  private func ingestOrdinary(_ event: KeyEventValue) {
    guard !event.isOurs else { return }
    let handled = clock()
    let configuration = engine.listenerClassification().configuration
    let isChord = configuration.bindings.matchesChord(
      keyCode: event.keyCode, rawFlags: event.rawFlags, armed: configuration.armed)
    resyncOrdinaryIfNeeded(except: event.keyCode)
    state.withLock { s in
      guard !s.closed else { return }
      let fresh = s.tracker.ingestOrdinary(event)
      guard fresh, !isChord else { return }
      s.pending.append(
        .otherKey(input: .accepting(stamp: event.timestamp, handled: handled)))
    }
    drain()
    armSweepIfNeeded()
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
  private func drain() {
    let start = state.withLock { s -> Bool in
      guard !s.draining else { return false }
      s.draining = true
      return true
    }
    guard start else { return }
    while true {
      let next = state.withLock { s -> Action? in
        guard !s.closed, !s.pending.isEmpty else {
          s.pending.removeAll()
          s.draining = false
          return nil
        }
        return s.pending.removeFirst()
      }
      guard let next else { return }
      perform(next)
    }
  }

  private func perform(_ action: Action) {
    switch action {
    case .engine(
      let keyCode, let isPress, let input, let generation, let recovery, let onlyAttempt,
      let ordinaryKeyHeld):
      engine.ingestFromListener(
        keyCode: keyCode, isPress: isPress, input: input, generation: generation,
        installation: installation, recovery: recovery, onlyAttempt: onlyAttempt,
        ordinaryKeyHeld: ordinaryKeyHeld)
    case .cancel(let keyCode, let generation):
      engine.cancelFromListener(
        keyCode: keyCode, generation: generation, installation: installation)
    case .main(let edge):
      toMain(edge)
    case .otherKey(let input):
      engine.otherKeyFromListener(input: input, installation: installation)
    }
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
    state.withLock { s in
      // Stale answers are dropped, never applied: the next sweep asks again.
      guard !s.closed, s.inputSequence == captured.sequence,
        engine.listenerConfigurationGeneration == classification.generation
      else {
        // A rejected sweep breaks the run of consecutive readings too.
        s.sweepReadUp.keys.removeAll()
        return
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
    }
    afterReconcileCommitForTesting?()
    drain()
  }

  /// The sweep's ordinary-key part (#3544 P4): a key the events still say is down but that reads
  /// up lost its keyUp (Secure Input that came and went between samples, a tap that was off); it
  /// is removed, remembered with the reading time so no event that occurred earlier is affected.
  /// One reading suffices: ordinary keys read reliably, and a wrong answer can only allow a start.
  private func reconcileOrdinary() {
    let keys = state.withLock { s -> Set<UInt16> in s.closed ? [] : s.tracker.ordinaryDown }
    guard !keys.isEmpty else { return }
    let answers = reader(keys)
    let readAt = clock()
    state.withLock { s in
      guard !s.closed else { return }
      s.tracker.resyncOrdinary(answers.filter { $0.value == .up }, at: readAt)
    }
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
