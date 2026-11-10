import EnviousWisprCore
import EnviousWisprLlamaEngine
import EnviousWisprLocalPolish
import EnviousWisprModelDelivery
import Foundation
import Testing

@testable import EnviousWisprLLM

extension LocalPolishLaunchSpec {
  /// A launch spec for tests, with an explicit fixture identity: no test reads a real manifest
  /// to name the artifact it pretends to serve. Values are taken as given; nothing is derived.
  static func fixture(
    modelID: LocalPolishModelID = .singleModel(for: .egOne), identityRevision: String = "fixture-a",
    serverBinaryURL: URL, modelURL: URL, contextTokens: Int, learnedWordAdapterURL: URL? = nil,
    extraArguments: [String] = [], learnedWordAdapterArguments: [String] = []
  ) -> LocalPolishLaunchSpec {
    LocalPolishLaunchSpec(
      engineKind: .llamaServer, modelID: modelID,
      artifactIdentity: ModelIdentity(
        family: .egOne, name: "fixture", revision: identityRevision, variant: "fixture",
        runtimeABI: "fixture"),
      serverBinaryURL: serverBinaryURL, modelURL: modelURL, contextTokens: contextTokens,
      learnedWordAdapterURL: learnedWordAdapterURL, extraArguments: extraArguments,
      learnedWordAdapterArguments: learnedWordAdapterArguments)
  }
}

/// #4473: the coordinator decides "same process or a different one" by comparing the requested
/// launch specs.
///
/// Customer harm when it is wrong, both silent: a missed difference leaves the OLD model
/// answering after the user picked another size or after an update installed new bytes (polish
/// comes from a model the app says is not selected), and a false difference restarts the model
/// on every restatement (launch, settings open), so the next dictation pastes unpolished text
/// while the model reloads. Encounter: every model switch, model update and checker arrival.
/// Owner: plan #4473 §3.1.1 S10 (one resident model). Rig: the existing lifecycle fixture, whose
/// fake server writes one line per real launch, so the count is the process's own record.
@Suite("A different launch spec is a different process (#4473)", .serialized, .tags(.driftGuard))
struct LocalPolishLaunchSpecTests {
  typealias Fixture = EGOneAdapterLifecycleTests.Fixture

  /// One representative change per field the comparison covers.
  enum Difference: String, CaseIterable, Sendable {
    case modelID, artifactIdentity, executable, modelFile, contextTokens, baseFlags, adapter
    case adapterArguments
  }

  private static func base(_ fixture: Fixture) -> LocalPolishLaunchSpec {
    fixture.configuration(adapterURL: fixture.adapter).spec
  }

  /// The base spec with exactly one field changed.
  private static func changed(_ difference: Difference, _ fixture: Fixture) throws
    -> LocalPolishLaunchSpec
  {
    let base = Self.base(fixture)
    var modelID = base.modelID
    var revision = "fixture-a"
    var binary = base.serverBinaryURL
    var model = base.modelURL
    var context = base.contextTokens
    var adapter = base.learnedWordAdapterURL
    var flags = base.extraArguments
    var adapterFlags = base.learnedWordAdapterArguments
    switch difference {
    case .modelID:
      modelID = .egOne(.mini)
    case .artifactIdentity:
      revision = "fixture-b"
    case .executable:
      // The same script under a second name in the same folder, so it logs to the same file.
      binary = fixture.root.appendingPathComponent("fake-server-2")
      try FileManager.default.copyItem(at: fixture.binary, to: binary)
    case .modelFile:
      model = fixture.root.appendingPathComponent("base-2.gguf")
      try Data("base-2".utf8).write(to: model)
    case .contextTokens:
      context = 8192
    case .baseFlags:
      flags.append("--fixture-flag")
    case .adapter:
      adapter = nil
      adapterFlags = []
    case .adapterArguments:
      adapterFlags.append("--fixture-adapter-flag")
    }
    return .fixture(
      modelID: modelID, identityRevision: revision, serverBinaryURL: binary, modelURL: model,
      contextTokens: context, learnedWordAdapterURL: adapter, extraArguments: flags,
      learnedWordAdapterArguments: adapterFlags)
  }

  private static func target(_ spec: LocalPolishLaunchSpec) -> LocalPolishTarget {
    LocalPolishTarget(
      configuration: EGOneServerManager.Configuration(
        spec: spec, makeArguments: LlamaServerLaunchBuilder.arguments, readinessBudgetSeconds: 4))
  }

  @Test("the same spec asked again leaves the running model alone")
  func equalSpecsLaunchOnce() async throws {
    let fixture = try Fixture()
    let coordinator = LocalPolishServerCoordinator()
    defer { fixture.cleanup() }
    await coordinator.transition(
      to: .run(Self.target(Self.base(fixture))), intent: coordinator.claimIntent())
    #expect(await coordinator.endpoint(for: .egOne) != nil)
    #expect(try fixture.launches().count == 1)

    // Built again from the same values: equal by content, not by being the same instance.
    await coordinator.transition(
      to: .run(Self.target(Self.base(fixture))), intent: coordinator.claimIntent())
    #expect(try fixture.launches().count == 1)

    // How long to wait and who renders the arguments are execution details, not identity.
    var restated = Self.target(Self.base(fixture)).configuration
    restated.readinessBudgetSeconds = 9
    restated.makeArguments = { spec, port, token in
      LlamaServerLaunchBuilder.arguments(spec: spec, port: port, authToken: token)
    }
    #expect(restated.spec == Self.base(fixture))
    await coordinator.transition(
      to: .run(LocalPolishTarget(configuration: restated)), intent: coordinator.claimIntent())
    #expect(try fixture.launches().count == 1)
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
  }

  /// About 1.06 seconds per case, measured: each case starts the fake server as a real child
  /// process twice (the base spec, then the changed one), the lifecycle fixture's half-second
  /// floor per launch. Only a real second launch shows that the old process was replaced.
  @Test(
    "one changed field stops the old process and starts the new one", arguments: Difference.allCases
  )
  func oneDifferenceRelaunches(_ difference: Difference) async throws {
    let fixture = try Fixture()
    let coordinator = LocalPolishServerCoordinator()
    defer { fixture.cleanup() }
    let base = Self.base(fixture)
    let changed = try Self.changed(difference, fixture)
    #expect(changed != base)
    await coordinator.transition(to: .run(Self.target(base)), intent: coordinator.claimIntent())
    #expect(try fixture.launches().count == 1)
    let firstPID = try fixture.lastPID()

    await coordinator.transition(to: .run(Self.target(changed)), intent: coordinator.claimIntent())
    #expect(await coordinator.endpoint(for: .egOne) != nil)
    #expect(try fixture.launches().count == 2, "\(difference.rawValue) did not start a new process")
    #expect(try fixture.lastPID() != firstPID)
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
  }

  /// About 1.59 seconds, measured: three real launches of the fake server (the adapter launch
  /// that fails, its bare-base fallback, then the changed request), each a real child process.
  @Test("after a fallback the coordinator still remembers the request WITH the checker")
  func requestedSpecSurvivesFallback() async throws {
    let fixture = try Fixture()
    let coordinator = LocalPolishServerCoordinator()
    defer { fixture.cleanup() }
    try Data().write(to: fixture.root.appendingPathComponent("fail_adapter"))
    let adapted = Self.base(fixture)
    await coordinator.transition(to: .run(Self.target(adapted)), intent: coordinator.claimIntent())
    // One failed launch with the checker, one launch without it.
    #expect(await coordinator.endpoint(for: .egOne)?.hasLearnedWordAdapter == false)
    #expect(try fixture.launches().count == 2)

    // Asking for the checker again is the SAME request, so nothing restarts.
    await coordinator.transition(to: .run(Self.target(adapted)), intent: coordinator.claimIntent())
    #expect(try fixture.launches().count == 2)

    // Asking for no checker is a DIFFERENT request, although the running process already has
    // none: had the fallback copy replaced the remembered request, this would not restart.
    let bare = try Self.changed(.adapter, fixture)
    #expect(bare == adapted.withoutLearnedWordAdapter())
    await coordinator.transition(to: .run(Self.target(bare)), intent: coordinator.claimIntent())
    #expect(try fixture.launches().count == 3)
    #expect(await coordinator.endpoint(for: .egOne)?.hasLearnedWordAdapter == false)
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())
  }
}
