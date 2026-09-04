import EnviousWisprCore
import Foundation

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

  public init() {}

  /// Start `provider`'s server, stopping a DIFFERENT model's first.
  ///
  /// Re-activating the model that is already resident stays idempotent, which
  /// is required: launch, provider switch and settings-open all call this and
  /// must not restart a working server.
  public func start(_ provider: LLMProvider, configuration: EGOneServerManager.Configuration)
    async
  {
    if let resident, resident != provider {
      // A different model holds the process. Stop it BEFORE recording the new
      // resident, so a failure to start leaves the field honestly empty rather
      // than claiming a model that is not running.
      await manager.stop()
      self.resident = nil
    }
    resident = provider
    await manager.start(configuration: configuration)
  }

  /// Stop `provider`'s server. A stop request from a model that is NOT resident
  /// is ignored rather than obeyed: during a switch the outgoing model's
  /// deactivate can arrive after the incoming model has started, and obeying it
  /// would kill the server the user is now waiting on.
  public func stop(_ provider: LLMProvider) async {
    guard resident == provider else { return }
    await manager.stop()
    resident = nil
  }

  /// Health for `provider`. Returns red when a DIFFERENT model is resident,
  /// rather than the manager's state — which would describe the other model's
  /// process and read green about the wrong thing.
  public func probeHealth(_ provider: LLMProvider, promptFamily: PromptFamily,
    spec: EGOneServerManager.ProbeSpec) async -> EGOneHealth
  {
    guard resident == provider else { return .red(reason: "not_running") }
    return await manager.probeHealth(promptFamily: promptFamily, spec: spec)
  }

  /// The live endpoint for `provider`, or nil when another model holds the
  /// process. A polish request must never be answered by different weights.
  public func endpoint(for provider: LLMProvider) async -> EGOneEndpoint? {
    guard resident == provider else { return nil }
    return await manager.activeEndpoint()
  }

  public func reapOrphansIfIdle(binaryPath: String) async {
    await manager.reapOrphansIfIdle(binaryPath: binaryPath)
  }

  public func setStateObserver(_ observer: @escaping @Sendable (EGOneServerManager.ServerState) -> Void)
    async
  {
    await manager.setStateObserver(observer)
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
