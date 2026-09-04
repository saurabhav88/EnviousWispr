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
  /// bookkeeping, and asserting it without a real 462 MB model is the whole
  /// reason the manager takes an injectable configuration.
  static func configuration(_ name: String) -> EGOneServerManager.Configuration {
    EGOneServerManager.Configuration(
      serverBinaryURL: URL(fileURLWithPath: "/nonexistent/\(name)-server"),
      modelURL: URL(fileURLWithPath: "/nonexistent/\(name).gguf"),
      contextTokens: 8192,
      readinessBudgetSeconds: 1)
  }

  @Test("nothing is resident before anything starts")
  func startsEmpty() async {
    let coordinator = LocalPolishServerCoordinator()
    #expect(await coordinator.residentModelForTesting == nil)
  }

  @Test("starting a model records it as resident")
  func startRecordsResident() async {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.start(.egOne, configuration: Self.configuration("eg1"))
    #expect(await coordinator.residentModelForTesting == .egOne)
  }

  /// THE row. Two models, and the second must take the process from the first.
  @Test("starting a second model takes the process from the first")
  func switchingModelsSwapsResidency() async {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.start(.egOne, configuration: Self.configuration("eg1"))
    await coordinator.start(.s1Mini, configuration: Self.configuration("s1"))
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
    await coordinator.start(.egOne, configuration: Self.configuration("eg1"))

    #expect(await coordinator.endpoint(for: .s1Mini) == nil)
    let health = await coordinator.probeHealth(
      .s1Mini, promptFamily: .s1ControlLine, spec: .egOne)
    #expect(health == .red(reason: "not_running"))
  }

  /// A stop from the model that has already been superseded must NOT kill the
  /// server the user is now waiting on. During a provider switch the outgoing
  /// model's deactivate can genuinely arrive after the incoming model started.
  @Test("a stale stop from the superseded model is ignored")
  func staleStopIsIgnored() async {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.start(.egOne, configuration: Self.configuration("eg1"))
    await coordinator.start(.s1Mini, configuration: Self.configuration("s1"))

    await coordinator.stop(.egOne)  // late arrival from the outgoing model
    #expect(
      await coordinator.residentModelForTesting == .s1Mini,
      "a late deactivate from the superseded model must not evict the live one")
  }

  @Test("the resident model can stop itself")
  func residentCanStop() async {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.start(.egOne, configuration: Self.configuration("eg1"))
    await coordinator.stop(.egOne)
    #expect(await coordinator.residentModelForTesting == nil)
  }

  /// Re-activating the SAME model must stay idempotent. Launch, provider switch
  /// and settings-open all call activation, and restarting a working server on
  /// every settings-open would be a visible regression for EG-1 users.
  @Test("re-activating the resident model does not swap it out")
  func reactivationIsIdempotent() async {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.start(.egOne, configuration: Self.configuration("eg1"))
    await coordinator.start(.egOne, configuration: Self.configuration("eg1"))
    #expect(await coordinator.residentModelForTesting == .egOne)
  }
}
