import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLlamaEngine
import EnviousWisprLocalPolish
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import EnviousWisprEG1Engine
import Foundation
import Testing

@testable import EnviousWisprAppKit
import EnviousWisprAppKitTestSupport

@MainActor
@Suite("Learned-word checker eligibility (#3105)", .tags(.productOutcome))
struct LearnedWordCheckerEligibilityTests {
  #if DEBUG
    @Test("scripted UAT checker bypasses every model gate and wins over the adapter door")
    func scriptedDoorSelection() async throws {
      let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let resources = root.appendingPathComponent("Sources/EnviousWispr/Resources")
      let temp = URL(fileURLWithPath: TestTemporaryDirectory.path)
        .appendingPathComponent("ew-3105-scripted-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
      let delivery = ModelDeliveryHome(
        engineMutationScope: .live(
          tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
        manifestBundle: try #require(Bundle(url: resources)), appSupportOverride: temp)
      let runtime = LocalPolishRuntime(
        manifest: nil, serverBinaryURL: nil, delivery: nil,
        engine: TestLocalPolishEngine())
      let checker = try #require(
        LearnedWordCheckUATDoor.configuration(environment: [
          LearnedWordCheckUATDoor.environmentKey: "Tuist",
          "EW_LEARNED_CHECK_EG1_ADAPTER": "/missing/checker.gguf",
          "EW_LEARNED_CHECK_EG1_THRESHOLD": "0.99",
        ]))
      let eligibility = LearnedWordCheckerEligibility(
        delivery: delivery,
        engines: [
          .egOne(.full): .init(
            base: nil, promptTemplateID: nil, runtime: runtime, debugThreshold: 0.99)
        ],
        currentModel: { .singleModel(for: $0) },
        debugScriptedChecker: checker)
      for provider in [LLMProvider.egOne, .s1Mini, .appleIntelligence] {
        let selection = await eligibility.selection(
          model: .singleModel(for: provider), language: "de")
        #expect(selection.identity == "uat_scripted")
        #expect(selection.checker?.armName == "uat_scripted")
        #expect(selection.absence == nil)
      }
      #expect(
        (await eligibility.selection(model: .egOne, language: nil)).identity
          == "uat_scripted")
      let emptyChecker = LearnedWordCheckUATDoor.configuration(environment: [
        LearnedWordCheckUATDoor.environmentKey: " ,  \t "
      ])
      #expect(emptyChecker?.armName == nil)
      let emptyEligibility = LearnedWordCheckerEligibility(
        delivery: delivery,
        engines: [
          .egOne(.full): .init(
            base: nil, promptTemplateID: nil, runtime: runtime, debugThreshold: nil)
        ],
        currentModel: { .singleModel(for: $0) },
        debugScriptedChecker: emptyChecker)
      #expect(
        (await emptyEligibility.selection(
          model: .singleModel(for: .appleIntelligence), language: "de")).absence
          == .engineHasNoChecker)
      #expect(
        (await emptyEligibility.selection(model: .s1Mini, language: "de")).absence
          == .engineHasNoChecker, "an engine the owner was not given has no checker")
      // #4473: the table serves EG-1 at its full size. Another size is not that model: it gets
      // no checker (it is never checked on the full size's adapter); the full size itself gets
      // past this point and is refused later, for its own reason.
      for size in [EGOneSize.mini, .micro] {
        #expect(
          (await emptyEligibility.selection(model: .egOne(size), language: "de")).absence
            == .engineHasNoChecker)
      }
      #expect(
        (await emptyEligibility.selection(model: .egOne(.full), language: "de")).absence
          == .baseNotAdmitted)
    }

    /// The UAT drills set and clear these exact keys (`CHECKER_DOOR_KEYS` in
    /// `learn_from_edits_uat.py`, `ENGINES` in `auto_dictionary_bench.py`).
    @Test("each engine's adapter door reads only its own keys")
    func adapterDoorPerEngine() throws {
      let adapter = TestTemporaryDirectory.url
        .appendingPathComponent("door-\(UUID().uuidString).gguf")
      try Data([0]).write(to: adapter)
      defer { try? FileManager.default.removeItem(at: adapter) }
      let s1Only = [
        "EW_LEARNED_CHECK_S1_ADAPTER": adapter.path, "EW_LEARNED_CHECK_S1_THRESHOLD": "0.858",
      ]
      let s1 = try #require(LearnedWordCheckAdapterDoor.configuration(.s1Mini, environment: s1Only))
      #expect(s1.url.path == adapter.path)
      #expect(s1.threshold == 0.858)
      #expect(
        LearnedWordCheckAdapterDoor.configuration(.egOne(.full), environment: s1Only) == nil)
      // #4473: EG-1's own keys are refused for every size. Its checker is an MLX adapter in
      // its own engine; a GGUF file is never handed to it.
      let egOneOnly = [
        "EW_LEARNED_CHECK_EG1_ADAPTER": adapter.path, "EW_LEARNED_CHECK_EG1_THRESHOLD": "0.481",
      ]
      for size in EGOneSize.allCases {
        #expect(
          LearnedWordCheckAdapterDoor.configuration(.egOne(size), environment: egOneOnly) == nil)
      }
      #expect(LearnedWordCheckAdapterDoor.configuration(.s1Mini, environment: egOneOnly) == nil)
      #expect(LearnedWordCheckerEngine.s1Mini.label == "S1-mini")
      #expect(LearnedWordCheckerEngine.egOne(.micro).label == "EG-1")
    }
  #endif

  private static let resources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/EnviousWispr/Resources")

  private static func manifest(_ name: String) throws -> DeliveryManifest {
    try DeliveryManifest.load(
      from: Data(contentsOf: resources.appendingPathComponent("\(name).json")))
  }

  /// Each engine's shipped checker contract and its own admitted base.
  private func pins(
    _ engine: LearnedWordCheckerEngine
  ) throws -> (LearnedWordCheckerContract, AdmittedCheckerBase) {
    let contract = try #require(try Self.manifest(engine.manifestResource).checkerContract)
    return (
      contract,
      AdmittedCheckerBase(
        manifest: try Self.manifest(Self.baseName(engine)),
        promptTemplateID: contract.base.promptTemplateID)
    )
  }

  /// The bundled base manifest of an engine's model.
  private static func baseName(_ engine: LearnedWordCheckerEngine) -> String {
    switch engine {
    case .egOne(.micro): "eg1-micro-delivery-manifest"
    case .egOne(.mini): "eg1-mini-delivery-manifest"
    case .egOne: "eg1-mlx-delivery-manifest"
    case .s1Mini: "s1-delivery-manifest"
    }
  }

  @Test(
    "ready, loading, mismatch and absent use one owner for every published checker; the decision reads no language",
    arguments: LearnedWordCheckerEngine.published)
  @MainActor
  func decisionMatrix(engine: LearnedWordCheckerEngine) throws {
    let runtime = LocalPolishRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, engine: TestLocalPolishEngine(),
      modelID: engine.model)
    let (contract, base) = try pins(engine)
    let ready = LocalPolishEndpoint(
      port: 12345, authToken: "test", contextTokens: 1024,
      hasLearnedWordAdapter: true)
    func select(
      baseAdmitted: Bool = true, adapterAdmitted: Bool = true, state: DeliveryState = .admitted,
      hostConfigured: Bool = true, deliveryEnabled: Bool = true,
      admittedBase: AdmittedCheckerBase? = nil,
      endpoint: LocalPolishEndpoint? = nil, missingEndpoint: Bool = false,
      serverReason: String? = nil
    ) -> LearnedWordCheckerSelection {
      LearnedWordCheckerEligibility.evaluate(
        engine: engine, language: "de", baseAdmitted: baseAdmitted,
        adapterAdmitted: adapterAdmitted, deliveryState: state,
        hostConfigured: hostConfigured, deliveryEnabled: deliveryEnabled,
        contract: contract, admittedBase: admittedBase ?? base,
        endpoint: missingEndpoint ? nil : (endpoint ?? ready),
        serverReason: serverReason,
        makeChecker: { engine.makeChecker(threshold: $0, language: "de", runtime: runtime) })
    }
    // #4473: each model's own checker: EG-1's in its own engine, S1-mini's on llama-server.
    let checker = try #require(select().checker)
    switch engine {
    case .egOne:
      #expect(checker is EnviousDecodeWordChecker && checker.armName == "eg1_lora")
    case .s1Mini:
      #expect(checker is LlamaLearnedWordChecker && checker.armName == "s1_lora")
    }
    #expect(select(baseAdmitted: false).absence == .baseNotAdmitted)
    #expect(
      select(
        adapterAdmitted: false,
        state: .downloading(fractionCompleted: 0.5, bytesWritten: 1, totalBytes: 2)
      ).absence == .adapterDownloading)
    #expect(
      select(adapterAdmitted: false, state: .cancelled(resumable: true)).absence
        == .adapterDeliveryFailed)
    #expect(select(adapterAdmitted: false, state: .cancelled(resumable: true)).retryAvailable)
    #expect(!select(adapterAdmitted: false, state: .notReady, hostConfigured: false).retryAvailable)
    #expect(
      select(adapterAdmitted: false, state: .notReady, deliveryEnabled: false).absence
        == .deliveryDisabled)
    #expect(
      select(adapterAdmitted: false, state: .notReady, hostConfigured: false, deliveryEnabled: false)
        .absence == .deliveryDisabled)
    #expect(select(deliveryEnabled: false).checker != nil, "an admitted adapter outlives the switch")
    #expect(
      select(
        admittedBase: AdmittedCheckerBase(
          manifest: try Self.manifest(Self.baseName(engine)), promptTemplateID: "wrong")
      ).absence
        == .baseMismatch("prompt_template"))
    #expect(select(missingEndpoint: true).absence == .serverUnavailable)
    #expect(
      select(
        endpoint: .init(port: 12345, authToken: "test", contextTokens: 1024),
        serverReason: "adapter_server_exited"
      ).absence
        == .serverWithoutAdapter("adapter_server_exited"))
  }

  @Test("a checker never runs on the other engine's base")
  func crossFamilyBaseIsRefused() throws {
    let (egOneContract, egOneBase) = try pins(.egOne(.full))
    let (microContract, microBase) = try pins(.egOne(.micro))
    let (s1Contract, s1Base) = try pins(.s1Mini)
    #expect(
      compatibility(contract: egOneContract, checkerFamily: .egOneChecker, admittedBase: s1Base)
        == .refused(.baseFamilyMismatch))
    #expect(
      compatibility(contract: s1Contract, checkerFamily: .s1MiniChecker, admittedBase: egOneBase)
        == .refused(.baseFamilyMismatch))
    #expect(
      compatibility(contract: s1Contract, checkerFamily: .egOneChecker, admittedBase: s1Base)
        == .refused(.baseFamilyMismatch), "the contract's family, not its base pin, decides")
    #expect(
      compatibility(contract: s1Contract, checkerFamily: .s1Mini, admittedBase: s1Base)
        == .refused(.baseFamilyMismatch), "a family that is not a checker is refused")
    #expect(
      compatibility(contract: egOneContract, checkerFamily: .egOneChecker, admittedBase: egOneBase)
        == .compatible)
    #expect(
      compatibility(contract: s1Contract, checkerFamily: .s1MiniChecker, admittedBase: s1Base)
        == .compatible)
    // #4473: one EG-1 size's checker never runs on another size's model.
    #expect(
      compatibility(
        contract: microContract, checkerFamily: .egOneMicroChecker, admittedBase: microBase)
        == .compatible)
    #expect(
      compatibility(
        contract: microContract, checkerFamily: .egOneMicroChecker, admittedBase: egOneBase)
        == .refused(.baseFamilyMismatch))
    #expect(
      compatibility(contract: egOneContract, checkerFamily: .egOneChecker, admittedBase: microBase)
        == .refused(.baseFamilyMismatch))
  }

  @Test("admission edges fire on a change of admission, never on a repeat")
  func admissionEdges() {
    let edges = AdmissionEdges()
    let a = ModelIdentity(family: .s1MiniChecker, name: "s1c", revision: "r", variant: "f16", runtimeABI: "x")
    let b = ModelIdentity(family: .egOneChecker, name: "eg1c", revision: "r", variant: "f16", runtimeABI: "x")
    #expect(edges.changed(a, admitted: true), "the first value seen is a change")
    #expect(!edges.changed(a, admitted: true), "a republished .admitted is not")
    #expect(!edges.changed(a, admitted: true))
    #expect(edges.changed(b, admitted: true), "identities are tracked apart")
    #expect(edges.changed(a, admitted: false), "removal is a change")
    #expect(!edges.changed(a, admitted: false))
    #expect(edges.changed(a, admitted: true), "re-admission is a change")
  }

  // A first download of Mini or Micro must bring that size's word check, not wait on the full size.
  @Test("each engine's checker download follows its own model's admission")
  func eachCheckerFollowsItsOwnBase() {
    func identity(_ name: String) -> ModelIdentity {
      ModelIdentity(family: .egOne, name: name, revision: "r", variant: "v", runtimeABI: "a")
    }
    let bases: [EGOneSize: ModelIdentity] = [
      .full: identity("full"), .mini: identity("mini"), .micro: identity("micro"),
    ]
    let s1 = identity("s1")
    for size in EGOneSize.allCases {
      #expect(
        LearnedWordCheckerEngine.egOne(size).baseIdentity(egOne: { bases[$0] }, s1Mini: s1)
          == bases[size])
    }
    #expect(LearnedWordCheckerEngine.s1Mini.baseIdentity(egOne: { bases[$0] }, s1Mini: s1) == s1)
    // A size this build has no registration for owes nothing; it does not borrow full's.
    #expect(
      LearnedWordCheckerEngine.egOne(.mini).baseIdentity(
        egOne: { $0 == .full ? bases[.full] : nil }, s1Mini: s1) == nil)
  }

  @Test("each model maps to its own checker or to none; every EG-1 size is published")
  func engineTable() {
    for provider in LLMProvider.allCases {
      #expect(
        LearnedWordCheckerEngine.hasOwnChecker(provider)
          == (provider == .egOne || provider == .s1Mini))
      if provider != .egOne, provider != .s1Mini {
        #expect(LearnedWordCheckerEngine(model: .singleModel(for: provider)) == nil)
      }
    }
    for size in EGOneSize.allCases {
      let engine = LearnedWordCheckerEngine(model: .egOne(size))
      #expect(engine == .egOne(size) && engine?.model == .egOne(size))
    }
    #expect(LearnedWordCheckerEngine(model: .singleModel(for: .s1Mini)) == .s1Mini)
    #expect(
      LearnedWordCheckerEngine.published
        == [.egOne(.full), .egOne(.mini), .egOne(.micro), .s1Mini])
    #expect(
      LearnedWordCheckerEngine.published.map(\.checkerFamily)
        == [.egOneChecker, .egOneMiniChecker, .egOneMicroChecker, .s1MiniChecker])
    #expect(
      LearnedWordCheckerEngine.published.map(\.installFolder) == [
        "Models/eg-1-checker", "Models/eg-1-mini-checker", "Models/eg-1-micro-checker",
        "Models/s1-mini-checker",
      ])
  }
}
