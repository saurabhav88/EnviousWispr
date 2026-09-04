import EnviousWisprCore
import Foundation
import os

/// The only code permitted to start, stop or swap the bundled polish server
/// (#2649, contract delta C6).
///
/// **The defect this closes is quiet and would not have shown up in any
/// single-model test.** `EGOneServerManager.start(configuration:)` returns
/// early when the server is already `.ready` — deliberately, because
/// activation is called from launch, provider switch and settings-open and must
/// be idempotent. It compares STATE, not which model's configuration produced
/// that state. So with EG-1 resident, S1-mini's activation would no-op and
/// every S1-mini polish would be answered by EG-1's weights, at the right
/// endpoint, with a 200 and plausible text. Nothing would look broken.
///
/// **And two runtimes could not have enforced this between them.** Each
/// constructed its own `EGOneServerManager`, so two managers meant two
/// processes and 3.4 GB resident. One-at-a-time is a property of the SET, and a
/// property of a set needs an owner that can see the whole set.
///
/// So residency is enforced two ways at once, and both are load-bearing:
/// containment, because this holds the single manager and hands it to nobody;
/// and identity, because it records WHICH model that manager is running and
/// stops the old one before starting a different one.
public actor LocalPolishServerCoordinator {
  /// The one manager. Deliberately not exposed: handing it out would restore
  /// exactly the two-owners situation this type exists to remove.
  private let manager = EGOneServerManager()

  /// Which model the manager is currently running, or nil when nothing is.
  /// This is the identity half of the rule; the manager's own state is the
  /// process half, and neither alone is sufficient.
  private var resident: LLMProvider?

  /// One observer per model. See `setStateObserver(for:_:)` for why a single
  /// slot was a regression rather than merely a limitation.
  private var observers: [LLMProvider: @Sendable (EGOneServerManager.ServerState) -> Void] = [:]
  private var managerObserverInstalled = false

  /// A non-isolated mirror of `resident`, read from inside the manager's own
  /// callback so an event carries the identity it was emitted UNDER. The
  /// actor-isolated field cannot be read there without a hop, and the hop is
  /// exactly the window this closes.
  private let observedResident = OSAllocatedUnfairLock<LLMProvider?>(initialState: nil)

  /// Monotonic token for a residency TRANSITION.
  ///
  /// **The class, named because two instances of it reached review one at a
  /// time.** An actor does not hold isolation across an `await`, so every
  /// `guard resident == provider` followed by an await is a check-then-act:
  /// the value that was true when checked can be false when used. Five sites
  /// had this shape — both mutating paths and all three reading ones — and
  /// fixing them individually would have left the next one to be found by the
  /// next reviewer.
  ///
  /// Mutating paths bump this and re-check it after every await, so a superseded
  /// transition abandons rather than overwriting a newer one. Reading paths
  /// re-check RESIDENCY after their await, because the answer is only useful if
  /// it is still about the model that asked.
  private var transitionGeneration = 0

  /// One writer for both, so the mirror cannot drift from the field it mirrors.
  private func setResident(_ provider: LLMProvider?) {
    resident = provider
    observedResident.withLock { $0 = provider }
  }

  public init() {}

  /// Start `provider`'s server, stopping a DIFFERENT model's first.
  ///
  /// Re-activating the model that is already resident stays idempotent, which
  /// is required: launch, provider switch and settings-open all call this and
  /// must not restart a working server.
  public func start(_ provider: LLMProvider, configuration: EGOneServerManager.Configuration)
    async
  {
    transitionGeneration += 1
    let generation = transitionGeneration

    if let resident, resident != provider {
      // A different model holds the process. Stop it BEFORE recording the new
      // resident, so a failure to start leaves the field honestly empty rather
      // than claiming a model that is not running.
      await manager.stop()
      // Two rapid switches can both reach here having seen the same outgoing
      // model. Without this the older continuation resumes afterwards and
      // overwrites the newer resident, so the field names a model nobody
      // selected.
      guard generation == transitionGeneration else { return }
      observers[resident]?(.stopped)
      setResident(nil)
    }
    guard generation == transitionGeneration else { return }
    setResident(provider)
    await manager.start(configuration: configuration)
  }

  /// Stop `provider`'s server. A stop request from a model that is NOT resident
  /// is ignored rather than obeyed: during a switch the outgoing model's
  /// deactivate can arrive after the incoming model has started, and obeying it
  /// would kill the server the user is now waiting on.
  public func stop(_ provider: LLMProvider) async {
    guard resident == provider else { return }
    transitionGeneration += 1
    let generation = transitionGeneration
    await manager.stop()
    // A switch that started during the stop owns the field now; clearing it
    // here would evict the model the user just selected.
    guard generation == transitionGeneration else { return }
    observers[provider]?(.stopped)
    setResident(nil)
  }

  /// Health for `provider`. Returns red when a DIFFERENT model is resident,
  /// rather than the manager's state — which would describe the other model's
  /// process and read green about the wrong thing.
  public func probeHealth(_ provider: LLMProvider, promptFamily: PromptFamily,
    spec: EGOneServerManager.ProbeSpec) async -> EGOneHealth
  {
    guard resident == provider else { return .red(reason: "not_running") }
    let result = await manager.probeHealth(promptFamily: promptFamily, spec: spec)
    // A probe takes real time. If the user switched during it, this verdict
    // describes a process the asking model no longer owns, and reporting it
    // would put another model's health on this model's row.
    guard resident == provider else { return .red(reason: "not_running") }
    return result
  }

  /// The live endpoint for `provider`, or nil when another model holds the
  /// process. A polish request must never be answered by different weights.
  public func endpoint(for provider: LLMProvider) async -> EGOneEndpoint? {
    guard resident == provider else { return nil }
    let endpoint = await manager.activeEndpoint()
    // The most consequential of the five: handing back an endpoint the asking
    // model no longer owns is the wrong-model polish this whole type exists to
    // prevent, arriving through the door that was supposed to stop it.
    guard resident == provider else { return nil }
    return endpoint
  }

  public func reapOrphansIfIdle(binaryPath: String) async {
    await manager.reapOrphansIfIdle(binaryPath: binaryPath)
  }

  /// Server-state observation, KEYED BY MODEL.
  ///
  /// `EGOneServerManager.setStateObserver` holds ONE closure, so two runtimes
  /// registering against it meant the second silently replaced the first. That
  /// is an EG-1 REGRESSION, not just a gap in the new model: depending on which
  /// unstructured registration task won, EG-1 could stop receiving state
  /// entirely and sit on "Starting", or receive S1-mini's state and report
  /// health about the wrong process.
  ///
  /// Keying by provider fixes the replacement. Gating delivery on residency
  /// fixes the other half: a model that does not hold the process must not be
  /// told the process changed, because the change is not about it.
  public func setStateObserver(
    for provider: LLMProvider,
    _ observer: @escaping @Sendable (EGOneServerManager.ServerState) -> Void
  ) async {
    observers[provider] = observer
    // Seed with the caller's OWN truth rather than the manager's state: a model
    // that is not resident is stopped as far as it is concerned, whatever the
    // other one is doing.
    let seed: EGOneServerManager.ServerState =
      resident == provider ? await manager.currentState() : .stopped
    // Re-checked after the await for the same reason as the readers above: a
    // switch during registration would seed this model with the other's state.
    observer(resident == provider ? seed : .stopped)
    await installManagerObserverIfNeeded()
  }

  /// One closure on the manager, forever, fanning out to whoever is resident.
  /// Re-registering per model is what created the replacement in the first
  /// place, so this installs exactly once.
  private func installManagerObserverIfNeeded() async {
    guard !managerObserverInstalled else { return }
    managerObserverInstalled = true
    await manager.setStateObserver { [weak self, observedResident] state in
      // Identity is captured AT EMISSION, not read when the task runs. Reading
      // it later is a real race and it delivers to the wrong model: during an
      // eviction the manager emits `.stopped` for the OUTGOING model, and
      // residency can flip to the incoming one before the queued task executes.
      // The outgoing model's stop would then arrive at the model that just
      // started, telling a live server it is stopped.
      let provider = observedResident.withLock { $0 }
      Task { await self?.publish(state, for: provider) }
    }
  }

  private func publish(_ state: EGOneServerManager.ServerState, for provider: LLMProvider?) {
    // Both halves matter: the event must belong to a model, and that model must
    // STILL be resident when it lands. A stale event for a model that has since
    // been evicted is not news it can act on.
    guard let provider, resident == provider, let observer = observers[provider] else { return }
    observer(state)
  }

  /// App quit. Synchronous by necessity: `applicationWillTerminate` cannot await
  /// into an actor, and a `Process` child is NOT killed when its parent exits.
  public nonisolated func terminateForAppQuit() {
    manager.terminateImmediately()
  }

  /// Test seam. Reading the resident identity is how a test proves the SWAP
  /// happened rather than proving the coordinator merely returned.
  var residentModelForTesting: LLMProvider? { resident }
}

/// The set of local polish engines the app constructed, so a view can reach the
/// SECOND one (#2649).
///
/// SwiftUI keys `@Environment` by TYPE, and both engines are `EGOneRuntime`, so
/// injecting two of them would have the second silently replace the first. This
/// holder gives the settings screen an unambiguous way to ask for a specific
/// engine rather than "the" engine — which is the same mistake the server
/// coordinator exists to prevent, one layer up.
@MainActor
@Observable
public final class LocalPolishRuntimeSet {
  public let egOne: EGOneRuntime
  public let s1Mini: EGOneRuntime

  public init(egOne: EGOneRuntime, s1Mini: EGOneRuntime) {
    self.egOne = egOne
    self.s1Mini = s1Mini
  }
}
