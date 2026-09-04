import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// #2649 contract delta C6: at most one local polish server, and it must be the
/// one the selected model asked for.
///
/// Every row here needs TWO models to mean anything. A single-model test cannot
/// distinguish a coordinator that swaps correctly from one that no-ops, because
/// with one model those are the same behaviour — which is exactly how the
/// underlying defect survived: `EGOneServerManager.start` compares STATE, not
/// which model produced it, so a second model's activation silently returns
/// while the first model keeps answering.
@Suite("One local polish server, and it is the right one (#2649 C6)", .tags(.driftGuard))
struct LocalPolishServerCoordinatorTests {

  /// A configuration pointing at a binary that does not exist. The server never
  /// comes up, which is fine and deliberate: these rows are about the IDENTITY
  /// bookkeeping, and asserting it without a real 484 MB model is the whole
  /// reason the manager takes an injectable configuration.
  static func target(_ provider: LLMProvider, _ name: String) -> LocalPolishTarget {
    LocalPolishTarget(
      provider: provider,
      configuration: EGOneServerManager.Configuration(
        serverBinaryURL: URL(fileURLWithPath: "/nonexistent/\(name)-server"),
        modelURL: URL(fileURLWithPath: "/nonexistent/\(name).gguf"),
        contextTokens: 8192,
        readinessBudgetSeconds: 1))
  }

  static func run(_ provider: LLMProvider, _ name: String) -> LocalPolishIntent {
    .run(target(provider, name))
  }

  @Test("nothing is resident before anything starts")
  func startsEmpty() async {
    let coordinator = LocalPolishServerCoordinator()
    #expect(await coordinator.residentModelForTesting == nil)
  }

  @Test("starting a model records it as resident")
  func startRecordsResident() async {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.transition(to: Self.run(.egOne, "eg1"), intent: coordinator.claimIntent())
    #expect(await coordinator.residentModelForTesting == .egOne)
  }

  /// THE row. Two models, and the second must take the process from the first.
  @Test("starting a second model takes the process from the first")
  func switchingModelsSwapsResidency() async {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.transition(to: Self.run(.egOne, "eg1"), intent: coordinator.claimIntent())
    await coordinator.transition(to: Self.run(.s1Mini, "s1"), intent: coordinator.claimIntent())
    #expect(await coordinator.residentModelForTesting == .s1Mini)
  }

  /// The other half, and the one that would break real users: a polish request
  /// must never be answered by a different model's weights. With EG-1 resident,
  /// S1-mini has no endpoint — so the limb skips and the user keeps their
  /// deterministic text, rather than silently receiving EG-1's output labelled
  /// as S1-mini's.
  @Test("a model that is not resident gets no endpoint and no green health")
  func nonResidentModelIsRefusedAnEndpoint() async {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.transition(to: Self.run(.egOne, "eg1"), intent: coordinator.claimIntent())

    #expect(await coordinator.endpoint(for: .s1Mini) == nil)
    let health = await coordinator.probeHealth(
      .s1Mini, promptFamily: .s1ControlLine, spec: .s1Mini)
    #expect(health == .red(reason: "not_running"))
  }

  /// **The founder's bug, 2026-09-04: "it's also breaking EG-1 when I swap back
  /// to it."** This is the exact call sequence the settings reconciler makes.
  ///
  /// Selecting EG-1 deactivates every unselected engine TWICE — once in the
  /// stop-outgoing pass, and again in the main pass, which runs AFTER EG-1 has
  /// started. That second deactivate therefore carries the NEWEST stamp. A stop
  /// that spoke for the whole resource obeyed it and shut EG-1 down, leaving
  /// the row on "Attention" until the user pressed refresh.
  @Test("a later deactivate of the OTHER engine cannot stop the one just selected")
  func idleFromAnotherEngineCannotEvictTheResident() async {
    let coordinator = LocalPolishServerCoordinator()
    // The user was on S1-mini.
    await coordinator.transition(to: Self.run(.s1Mini, "s1"), intent: coordinator.claimIntent())

    // Reconciler, selecting EG-1, in its real order.
    await coordinator.transition(to: .idle(.s1Mini), intent: coordinator.claimIntent())
    await coordinator.transition(to: Self.run(.egOne, "eg1"), intent: coordinator.claimIntent())
    // The redundant second pass over the unselected engine. NEWEST stamp.
    await coordinator.transition(to: .idle(.s1Mini), intent: coordinator.claimIntent())

    #expect(
      await coordinator.residentModelForTesting == .egOne,
      "the engine the user selected was stopped by the other engine's deactivate")
  }

  /// The defect that made two guarded methods into one intent primitive.
  ///
  /// A provider switch reaches the coordinator as two separate unstructured
  /// tasks, and Swift does not order them. The user's order is known only where
  /// it was observed — on the main actor — so it is stamped there. Delivering
  /// the stamps out of order must change nothing.
  @Test("an older stop cannot beat a newer start, whatever order the tasks run in")
  func laterIntentWinsRegardlessOfDeliveryOrder() async {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.transition(to: Self.run(.egOne, "eg1"), intent: coordinator.claimIntent())

    let stopIntent = coordinator.claimIntent()
    let startIntent = coordinator.claimIntent()

    // The tasks arrive in the OPPOSITE order to the stamps.
    await coordinator.transition(to: Self.run(.s1Mini, "s1"), intent: startIntent)
    await coordinator.transition(to: .idle(.egOne), intent: stopIntent)

    #expect(
      await coordinator.residentModelForTesting == .s1Mini,
      "the engine the user selected must be resident even when the stop lands last")
  }

  /// Two-way control for the row above: delivered in the order they were
  /// claimed, the same two stamps must reach the same state. Without this, a
  /// coordinator that ignored every stop would pass the inversion row.
  @Test("in-order delivery of the same intents reaches the same state")
  func inOrderDeliveryAgrees() async {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.transition(to: Self.run(.egOne, "eg1"), intent: coordinator.claimIntent())

    let stopIntent = coordinator.claimIntent()
    let startIntent = coordinator.claimIntent()
    await coordinator.transition(to: .idle(.egOne), intent: stopIntent)
    await coordinator.transition(to: Self.run(.s1Mini, "s1"), intent: startIntent)

    #expect(await coordinator.residentModelForTesting == .s1Mini)
  }

  /// And the stop must still WORK when the resident asks for it. A coordinator
  /// that simply never stopped would pass both rows above and the founder's row.
  @Test("the resident asking to idle actually stops it")
  func residentIdleStops() async {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.transition(to: Self.run(.egOne, "eg1"), intent: coordinator.claimIntent())
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
    #expect(await coordinator.residentModelForTesting == nil)
  }

  /// Re-activating the SAME model must stay idempotent. Launch, provider switch
  /// and settings-open all call activation, and restarting a working server on
  /// every settings-open would be a visible regression for EG-1 users.
  @Test("re-activating the resident model does not swap it out")
  func reactivationIsIdempotent() async {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.transition(to: Self.run(.egOne, "eg1"), intent: coordinator.claimIntent())
    await coordinator.transition(to: Self.run(.egOne, "eg1"), intent: coordinator.claimIntent())
    #expect(await coordinator.residentModelForTesting == .egOne)
  }

  /// Stamps are unique and monotonic, which is what lets `transition` compare
  /// them at all. Claimed off the actor deliberately: the point of the stamp is
  /// that a main-actor caller can take it without awaiting into this actor.
  @Test("intent stamps are monotonic and never repeat")
  func intentStampsAreMonotonic() {
    let coordinator = LocalPolishServerCoordinator()
    let stamps = (0..<64).map { _ in coordinator.claimIntent() }
    #expect(stamps == stamps.sorted(), "stamps must increase in claim order")
    #expect(Set(stamps).count == stamps.count, "two callers must never share a stamp")
  }
}
