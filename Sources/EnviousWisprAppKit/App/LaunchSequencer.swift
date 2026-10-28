import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Observation
import SwiftUI

// #3252 (plan 3.3 to 3.5): a launch from a temporary or read-only location is offered the move
// BEFORE the app starts any work. A healthy launch builds the app exactly where it always has.
//
// Three owners, one per reason to change:
// - `LaunchSequencer`: when the lifecycle target (the bootstrapper) is built and how the launch
//   callbacks reach it.
// - `LaunchGate`: what the scenes draw while the target does not exist yet.
// - `LaunchOfferDriver`: the order of "answer the offer, start the app, then show the failure
//   card". Only a bad-location launch has one.

/// The lifecycle methods `WisprBootstrapper` has, so launch ordering can be tested
/// in the app-shell library with a fake target. `EnviousWisprTests` links this module, not the
/// live composition root (`Package.swift`).
@MainActor
package protocol LaunchTarget: AnyObject {
  func applicationWillFinishLaunching()
  func applicationDidFinishLaunching()
  func applicationDidBecomeActive()
  func applicationShouldHandleReopen() -> Bool
  /// True when the app may quit now. Otherwise the target calls `reply` exactly once,
  /// later, with whether to quit (#4086).
  func applicationShouldTerminate(reply: @escaping @MainActor (Bool) -> Void) -> Bool
  func applicationWillTerminate()
}

extension WisprBootstrapper: LaunchTarget {}

/// What the scene declarations need without a bootstrapper. The bootstrapper's own window
/// properties return these same values, so there is one definition.
package enum LaunchWindowIdentity {
  package static let mainTitle = AppConstants.appName
  package static let onboardingTitle = AppConstants.onboardingWindowTitle
  package static let onboardingID = AppConstants.onboardingWindowID
}

// MARK: - Sequencer

/// Decides when the app's lifecycle target is built and forwards lifecycle callbacks to it.
///
/// `startImmediately` builds the target inside `init`, in the caller's position, so a healthy
/// launch is today's synchronous construction. Otherwise the target stays absent and the launch
/// callbacks are held until `startNormally()`.
@MainActor
@Observable
package final class LaunchSequencer<Target: LaunchTarget> {
  package enum Phase: Equatable {
    /// No target yet; launch callbacks are held.
    case waiting
    /// `makeTarget` is running. A repeated start, or a termination, finds this phase.
    case starting
    case started
    /// Terminated or handed off. Nothing is constructed or forwarded to a missing target again.
    case terminal
  }

  package private(set) var phase: Phase = .waiting
  package private(set) var target: Target?

  package var isWaiting: Bool { phase == .waiting }

  @ObservationIgnored private let makeTarget: @MainActor () -> Target
  @ObservationIgnored private var heldWill = false
  @ObservationIgnored private var heldDid = false
  @ObservationIgnored private var heldActivation = false
  @ObservationIgnored private var didDelivered = false
  @ObservationIgnored private var terminationRequestedWhileStarting = false

  package init(startImmediately: Bool, makeTarget: @escaping @MainActor () -> Target) {
    self.makeTarget = makeTarget
    if startImmediately {
      phase = .starting
      target = makeTarget()
      phase = .started
    }
  }

  package func applicationWillFinishLaunching() {
    switch phase {
    case .started: target?.applicationWillFinishLaunching()
    case .waiting, .starting: heldWill = true
    case .terminal: break
    }
  }

  package func applicationDidFinishLaunching() {
    switch phase {
    case .started:
      target?.applicationDidFinishLaunching()
      guard phase == .started else { return }
      didDelivered = true
      replayMissedActivationIfDue()
    case .waiting, .starting: heldDid = true
    case .terminal: break
    }
  }

  /// While the target is absent the only activation is the one that fires with the offer on
  /// screen; the target never sees it unless it is replayed once after did-finish launching
  /// (Chunk 0 S1). Several held activations are one.
  package func applicationDidBecomeActive() {
    switch phase {
    case .started: target?.applicationDidBecomeActive()
    case .waiting, .starting: heldActivation = true
    case .terminal: break
    }
  }

  /// Reopen with no target has nothing to open yet: the system keeps its default handling.
  package func applicationShouldHandleReopen() -> Bool {
    phase == .started ? (target?.applicationShouldHandleReopen() ?? true) : true
  }

  /// Only a running target can have work to finish first; with none, quit now.
  package func applicationShouldTerminate(reply: @escaping @MainActor (Bool) -> Void) -> Bool {
    guard phase == .started, let target else { return true }
    return target.applicationShouldTerminate(reply: reply)
  }

  package func applicationWillTerminate() {
    switch phase {
    case .started:
      phase = .terminal
      target?.applicationWillTerminate()
    case .waiting:
      phase = .terminal
    case .starting:
      // Construction is running right now. Finish the contract once it returns.
      terminationRequestedWhileStarting = true
    case .terminal: break
    }
  }

  /// The move succeeded and this process is quitting: nothing may start the app afterwards.
  /// A no-op in every phase except `waiting`.
  package func handOff() {
    if phase == .waiting { phase = .terminal }
  }

  /// Builds the target once, then delivers the held launch callbacks in order. Returns whether
  /// this call started the app: a repeated, reentrant, post-termination or post-hand-off call
  /// starts nothing and returns false.
  @discardableResult
  package func startNormally() -> Bool {
    guard phase == .waiting else { return false }
    phase = .starting
    let built = makeTarget()
    target = built

    if finishRequestedTermination(built) { return false }

    if heldWill {
      heldWill = false
      built.applicationWillFinishLaunching()
      if finishRequestedTermination(built) { return false }
    }

    if heldDid {
      heldDid = false
      built.applicationDidFinishLaunching()
      if finishRequestedTermination(built) { return false }
      didDelivered = true
    }

    phase = .started
    replayMissedActivationIfDue()
    return phase == .started
  }

  /// A termination reported while `.starting` (construction or a held callback was running) is
  /// honoured at the next checkpoint: the phase ends terminal and the target hears it exactly once.
  private func finishRequestedTermination(_ built: Target) -> Bool {
    guard terminationRequestedWhileStarting else { return false }
    terminationRequestedWhileStarting = false
    heldActivation = false
    phase = .terminal
    built.applicationWillTerminate()
    return true
  }

  /// A missed activation is replayed once, and only after did-finish launching was delivered
  /// (the order a healthy launch has is will, did, active).
  private func replayMissedActivationIfDue() {
    guard phase == .started, heldActivation, didDelivered, let target else { return }
    heldActivation = false
    target.applicationDidBecomeActive()
  }
}

// MARK: - Gate

/// Draws nothing until the sequencer has started its target, then the real content.
/// Reads observed state inside `body`, never a captured initial optional. While waiting,
/// it hides the hosting window and restores it when the real content mounts.
package struct LaunchGate<Target: LaunchTarget, Content: View>: View {
  private let sequencer: LaunchSequencer<Target>
  private let content: (Target) -> Content

  package init(
    _ sequencer: LaunchSequencer<Target>, @ViewBuilder content: @escaping (Target) -> Content
  ) {
    self.sequencer = sequencer
    self.content = content
  }

  package var body: some View {
    if sequencer.phase == .started, let target = sequencer.target {
      content(target)
    } else {
      Color.clear.background(LaunchWindowHiderView())
    }
  }
}

/// Hides windows and puts back exactly what it changed. Several waiting placeholders can sit in
/// one window (the scenes can re-evaluate), so a window is restored only when its last owner
/// lets go, and the values it is restored to are the ones it had before the FIRST hide, never an
/// assumed alpha of 1.
@MainActor
final class LaunchWindowHider {
  static let shared = LaunchWindowHider()

  private struct Entry {
    weak var window: NSWindow?
    let alpha: CGFloat
    let ignoresMouseEvents: Bool
    var owners: Set<ObjectIdentifier>
  }

  private var entries: [ObjectIdentifier: Entry] = [:]

  func hide(_ window: NSWindow, owner: AnyObject) {
    entries = entries.filter { $0.value.window != nil }
    let key = ObjectIdentifier(window)
    if var entry = entries[key], entry.window === window {
      entry.owners.insert(ObjectIdentifier(owner))
      entries[key] = entry
    } else {
      entries[key] = Entry(
        window: window, alpha: window.alphaValue, ignoresMouseEvents: window.ignoresMouseEvents,
        owners: [ObjectIdentifier(owner)])
    }
    window.alphaValue = 0
    window.ignoresMouseEvents = true
  }

  func release(_ window: NSWindow, owner: AnyObject) {
    let key = ObjectIdentifier(window)
    guard var entry = entries[key], entry.window === window else { return }
    entry.owners.remove(ObjectIdentifier(owner))
    if entry.owners.isEmpty {
      window.alphaValue = entry.alpha
      window.ignoresMouseEvents = entry.ignoresMouseEvents
      entries.removeValue(forKey: key)
    } else {
      entries[key] = entry
    }
  }

  /// Windows currently held hidden, for tests.
  var hiddenWindowCount: Int { entries.values.filter { $0.window != nil }.count }
}

final class LaunchWindowHiderNSView: NSView {
  private weak var hiddenWindow: NSWindow?

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    releaseHiddenWindow()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    hiddenWindow = window
    LaunchWindowHider.shared.hide(window, owner: self)
  }

  func releaseHiddenWindow() {
    guard let window = hiddenWindow else { return }
    hiddenWindow = nil
    LaunchWindowHider.shared.release(window, owner: self)
  }
}

private struct LaunchWindowHiderView: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { LaunchWindowHiderNSView() }
  func updateNSView(_ nsView: NSView, context: Context) {}
  static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
    (nsView as? LaunchWindowHiderNSView)?.releaseHiddenWindow()
  }
}

// MARK: - Relocation launch plan and driver

/// The launch decision for this process and the coordinator that carries it out. Built for EVERY
/// launch: the decision is synchronous and cheap (a path check, a statfs, a defaults read) and
/// builds none of the heavy graph.
@MainActor
package final class RelocationLaunchPlan {
  let coordinator: ApplicationRelocationCoordinator
  /// The blocking location state when this launch is offered the move first; nil otherwise.
  let blockingState: ApplicationLocationState?

  package var offersFirst: Bool { blockingState != nil }

  package convenience init(
    presentation: DesktopPresentationEffects, relauncher: any RelocationRelaunching
  ) {
    self.init(coordinator: .live(presentation: presentation, relauncher: relauncher))
  }

  init(coordinator: ApplicationRelocationCoordinator) {
    self.coordinator = coordinator
    if case .offerFirst(let state) = coordinator.launchDecision() {
      blockingState = state
    } else {
      blockingState = nil
    }
  }
}

/// Early observability for a bad-location launch, which asks the person a question (and emits
/// `update.relocation_offered`) before the bootstrapper exists. Same order the bootstrapper uses:
/// the one-time settings migration, then the stored switches, then the idempotent initialize. A
/// healthy launch never runs this; the bootstrapper's own later `initialize` finds it done.
@MainActor
enum LaunchObservability {
  static func initializeForOffer(
    migrate: @MainActor () -> Void = { SettingsDefaultsMigration.migrateIfNeeded() },
    readSwitches: @MainActor () -> SettingsManager.StoredTelemetrySwitches = {
      SettingsManager.storedTelemetrySwitches()
    },
    initialize: @MainActor (Bool, Bool) -> Void = {
      ObservabilityBootstrap.initialize(usageMetrics: $0, crashReports: $1)
    }
  ) {
    // Migration first: a wrong early read would become launch-stable, because `crashReports`
    // holds for the whole run (`ObservabilityBootstrap`).
    migrate()
    let switches = readSwitches()
    initialize(switches.usageMetrics, switches.crashReports)
  }
}

/// The order of a bad-location launch: answer the offer, THEN start the app, THEN show the
/// failure card. The card is modal and its copy says the app keeps working, so it may only
/// appear over a running app, on a later run-loop turn; showing it first would block startup
/// behind a card nobody has dismissed.
///
/// Single-flight: the offer is scheduled once, and a completion is consumed once, so a repeated
/// callback or a second completion cannot start the app or show a card twice.
@MainActor
package final class LaunchOfferDriver<Target: LaunchTarget> {
  struct Steps {
    var prepareObservability: @MainActor () -> Void
    var runPreflight: @MainActor (ApplicationLocationState) async -> PreflightOutcome
    var presentFailure: @MainActor (RelocationFailurePresentation) -> Void
    /// Runs the work on a later main-loop turn. The app can become active first, and launch
    /// continues without awaiting the offer.
    var schedule: @MainActor (@escaping @MainActor () async -> Void) -> Void
  }

  private let sequencer: LaunchSequencer<Target>
  private let state: ApplicationLocationState
  private let steps: Steps
  private var scheduled = false
  private var completed = false

  /// nil when the plan does not offer first: a healthy launch gets no driver and runs none of
  /// this.
  package convenience init?(sequencer: LaunchSequencer<Target>, plan: RelocationLaunchPlan) {
    guard let state = plan.blockingState else { return nil }
    let coordinator = plan.coordinator
    self.init(
      sequencer: sequencer, state: state,
      steps: Steps(
        prepareObservability: { LaunchObservability.initializeForOffer() },
        runPreflight: { await coordinator.runPreflight(state: $0) },
        presentFailure: { coordinator.presentFailure($0) },
        schedule: { work in Task { @MainActor in await work() } }))
  }

  init(sequencer: LaunchSequencer<Target>, state: ApplicationLocationState, steps: Steps) {
    self.sequencer = sequencer
    self.state = state
    self.steps = steps
  }

  /// Called after did-finish launching was forwarded to the sequencer. Schedules the offer once.
  package func didFinishLaunching() {
    guard !scheduled else { return }
    scheduled = true
    steps.schedule { [self] in await run() }
  }

  func run() async {
    // Terminated or handed off before the turn came: there is nothing to offer.
    guard sequencer.isWaiting else { return }
    steps.prepareObservability()
    complete(await steps.runPreflight(state))
  }

  func complete(_ outcome: PreflightOutcome) {
    guard !completed else { return }
    completed = true
    switch outcome {
    case .handedOff:
      sequencer.handOff()
    case .continueNormally(let failure):
      // `startNormally` refuses after termination or hand-off; then nothing is shown either.
      guard sequencer.startNormally() else { return }
      guard let failure else { return }
      // The card runs on a later turn; termination in between must not bring it up.
      steps.schedule { [sequencer, steps] in
        guard sequencer.phase == .started else { return }
        steps.presentFailure(failure)
      }
    }
  }
}
