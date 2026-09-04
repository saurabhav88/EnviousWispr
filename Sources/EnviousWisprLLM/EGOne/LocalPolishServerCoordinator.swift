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
/// What the app wants running: a model and the configuration to run it with.
///
/// Nil-as-absence is the whole point — "stop" and "start" become one value, so
/// a caller states an intent rather than issuing two commands that can cross.
public struct LocalPolishTarget: Sendable {
  public let provider: LLMProvider
  public let configuration: EGOneServerManager.Configuration

  public init(provider: LLMProvider, configuration: EGOneServerManager.Configuration) {
    self.provider = provider
    self.configuration = configuration
  }
}

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

  /// Monotonic intent stamp, CLAIMED BY THE CALLER before it spawns its task.
  ///
  /// **The earlier design derived order from execution and that is the wrong
  /// clock.** A counter bumped inside the transition records which task got
  /// here first, not which switch the user asked for last — and activate and
  /// deactivate reach this actor as separate unstructured tasks, which Swift
  /// does not order. So an ordinary EG-1 to S1-mini switch could run the stop
  /// after the start: the stop superseded the newer start, the start bailed at
  /// its own guard, and the user's selected engine never came up with nothing
  /// reporting it.
  ///
  /// The order that matters is the order the user's actions were OBSERVED, and
  /// that is known synchronously on the main actor. `claimIntent()` is taken
  /// there, before any task exists, and `transition` obeys only the newest
  /// stamp it has seen. Two methods guarded separately cannot express "latest
  /// intent wins" at all, which is why they are gone rather than tightened.
  private let intentCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
  private var honouredIntent = 0

  /// Claim the next intent stamp. Synchronous and callable from any isolation,
  /// so a main-actor caller can stamp its request in the order the user made
  /// it and hand that stamp to whatever task carries it out.
  public nonisolated func claimIntent() -> Int {
    intentCounter.withLock { value in
      value += 1
      return value
    }
  }

  /// One writer for both, so the mirror cannot drift from the field it mirrors.
  private func setResident(_ provider: LLMProvider?) {
    resident = provider
    observedResident.withLock { $0 = provider }
  }

  public init() {}

  /// Drive the server to `target`, or to nothing when `target` is nil.
  ///
  /// One entry point, because starting and stopping are not independent
  /// operations on a single-process resource — they are two values of one
  /// question, "what should be running now". Expressed as two methods, the
  /// answer depends on which task the runtime happens to schedule first.
  ///
  /// Re-stating the resident model stays idempotent, which is required:
  /// launch, provider switch and settings-open all arrive here and must not
  /// restart a working server.
  public func transition(to target: LocalPolishTarget?, intent: Int) async {
    // A stamp older than one already honoured describes a world the user has
    // moved on from. Obeying it is exactly the defect this replaced.
    guard intent >= honouredIntent else { return }
    honouredIntent = intent

    if let resident, resident != target?.provider {
      // Stop the outgoing model BEFORE recording the new resident, so a start
      // that fails leaves the field honestly empty rather than naming a model
      // that is not running.
      await manager.stop()
      guard intent >= honouredIntent else { return }
      // Whoever actually lost the process is told so, rather than whichever
      // provider the caller named: its row must not keep showing a live server
      // it no longer owns.
      observers[resident]?(.stopped)
      setResident(nil)
    }

    guard intent >= honouredIntent, let target else { return }
    setResident(target.provider)
    await manager.start(configuration: target.configuration)
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
