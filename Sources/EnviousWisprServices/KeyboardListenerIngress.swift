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
/// **Reconciliation** (plan §3.5, B3/B4, A2). Held state is checked against the injected key-state
/// reader after a confirmed tap re-enable, when Secure Input clears, every 5 s while any key is held
/// or the engine still owns a record press, and when an event cannot be turned into an edge (a
/// duplicate press, a release of a key never seen down, aggregate-only evidence for a held key).
/// The reader runs outside every lock; its answers apply only if the installation, the
/// configuration generation and the input sequence are unchanged since it was asked. Up releases
/// (release-only recovery), down keeps, unknown changes nothing; age alone never releases a key.
/// Nothing here can start a recording, make a second press or lock a take.
///
/// **Held-record watchdog.** The 5 s sweep also asks about the key of the press the engine owns,
/// even when this installation never saw it (a listener replaced mid-hold), and releases it if it
/// reads up, so a lost key-up cannot leave push-to-talk recording forever.
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
    case engine(keyCode: UInt16, isPress: Bool, input: RecordGesture.InputTime, generation: UInt64)
    case cancel(keyCode: UInt16, generation: UInt64)
    case main(MainEdge)
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
      ingest(event, retried: false)
    case .tapReenabled:
      // Keys may have moved while the tap was off.
      reconcile()
    case .secureInputChanged:
      // Leaving Secure Input: key-ups may have been hidden (plan A2). Entering changes nothing.
      if event.secureInput?.enabled == false { reconcile() }
    case .keyDown, .keyUp, .stormStopped:
      break
    }
  }

  /// `onlyAfter` / `onlyGeneration`: for the one bounded retry, the input sequence it may run at
  /// and the configuration the event was first classified under; newer input or a configuration
  /// change since its verification makes the retry stale, and it is dropped before it can be read
  /// as a different shortcut.
  private func ingest(
    _ event: KeyEventValue, retried: Bool, onlyAfter: UInt64? = nil,
    onlyGeneration: UInt64? = nil
  ) {
    guard !event.isOurs, event.keyCode != Self.ignoredGlobeKeyCode else { return }
    let handled = clock()
    let classification = engine.listenerClassification()
    if let onlyGeneration, classification.generation != onlyGeneration { return }
    let (unplaced, ambiguous) = state.withLock { s -> (Bool, Bool) in
      guard !s.closed else { return (false, false) }
      if let onlyAfter, s.inputSequence != onlyAfter { return (false, false) }
      s.inputSequence &+= 1
      let update = s.tracker.ingest(
        event, handled: handled, configuration: classification.configuration)
      var actions: [Action] = []
      for edge in update.edges {
        route(&s, edge, classification, into: &actions)
      }
      s.pending.append(contentsOf: actions)
      // Verify before trusting the held state this event leaves (unmatched-press recovery, B3): an
      // event the tracker could not turn into an edge contradicts it, and a press of a key no
      // shortcut owns may be the first thing after a missed release of one that is.
      let unmatchedPress = update.edges.contains { $0.phase == .press && $0.role == nil }
      let unplaced =
        ModifierKeyCodes.flag(for: event.keyCode) != nil
        && (update.edges.isEmpty || unmatchedPress)
      return (unplaced, update.ambiguousKey == event.keyCode)
    }
    drain()
    // Verified, but never retried when the event was aggregate-only evidence about a held key:
    // with the family still on (the other side held) it is as likely that key's release as a new
    // press, and once verification reads the key up, a retry would turn that release into a press.
    if unplaced { reconcile(retry: retried || ambiguous ? nil : event) }
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
        actions.append(
          .engine(keyCode: edge.keyCode, isPress: true, input: input, generation: generation))
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
    case .engine(let keyCode, let isPress, let input, let generation):
      engine.ingestFromListener(
        keyCode: keyCode, isPress: isPress, input: input, generation: generation,
        installation: installation)
    case .cancel(let keyCode, let generation):
      engine.cancelFromListener(
        keyCode: keyCode, generation: generation, installation: installation)
    case .main(let edge):
      toMain(edge)
    }
  }

  // MARK: - Reconciliation

  /// Verify held state against the reader. `retry`: the event that could not be placed, ingested
  /// once more if verification released its key (bounded: never retried twice).
  private func reconcile(retry: KeyEventValue? = nil) {
    let classification = engine.listenerClassification()
    let owned = engine.ownedListenerKey
    guard
      let captured = state.withLock({ s -> (sequence: UInt64, held: Set<UInt16>)? in
        s.closed ? nil : (s.inputSequence, Set(s.tracker.held.keys))
      })
    else { return }
    var keys = captured.held
    if let owned { keys.insert(owned) }
    guard !keys.isEmpty else { return }
    // Outside every lock: the reader is an OS call in production.
    let answers = reader(keys)
    let handled = clock()
    let (released, sequence) = state.withLock { s -> (Set<UInt16>, UInt64) in
      // Stale answers are dropped, never applied: a later trigger asks again.
      guard !s.closed, s.inputSequence == captured.sequence,
        engine.listenerConfigurationGeneration == classification.generation
      else { return ([], s.inputSequence) }
      var actions: [Action] = []
      let edges = s.tracker.reconcile(
        handled: handled, configuration: classification.configuration
      ) { _ in answers }
      for edge in edges { route(&s, edge, classification, into: &actions) }
      var released = Set(edges.map(\.keyCode))
      // The watchdog: a record press the engine owns that this installation never saw down.
      if let owned, !captured.held.contains(owned), answers[owned] == .up {
        actions.append(
          .engine(
            keyCode: owned, isPress: false,
            input: RecordGesture.InputTime(handled: handled, occurred: nil),
            generation: classification.generation))
        released.insert(owned)
      }
      s.pending.append(contentsOf: actions)
      return (released, s.inputSequence)
    }
    afterReconcileCommitForTesting?()
    drain()
    if let retry, released.contains(retry.keyCode) {
      ingest(
        retry, retried: true, onlyAfter: sequence, onlyGeneration: classification.generation)
    }
  }

  // MARK: - Sweep

  /// Schedule the next sweep when something is held and none is pending.
  private func armSweepIfNeeded() {
    let ownedByEngine = engine.ownedListenerKey != nil
    let token = state.withLock { s -> UInt64? in
      guard !s.closed, s.sweepPending == nil, !s.tracker.held.isEmpty || ownedByEngine else {
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
