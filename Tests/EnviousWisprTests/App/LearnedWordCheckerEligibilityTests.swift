import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

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
      let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ew-3105-scripted-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
      let delivery = ModelDeliveryHome(
        engineMutationScope: .live(
          tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
        manifestBundle: try #require(Bundle(url: resources)), appSupportOverride: temp)
      let runtime = EGOneRuntime(manifest: nil, serverBinaryURL: nil, delivery: nil)
      let checker = try #require(
        LearnedWordCheckUATDoor.configuration(environment: [
          LearnedWordCheckUATDoor.environmentKey: "Tuist",
          "EW_LEARNED_CHECK_EG1_ADAPTER": "/missing/checker.gguf",
          "EW_LEARNED_CHECK_EG1_THRESHOLD": "0.99",
        ]))
      let eligibility = LearnedWordCheckerEligibility(
        delivery: delivery,
        engines: [
          .egOne: .init(base: nil, promptTemplateID: nil, runtime: runtime, debugThreshold: 0.99)
        ],
        debugScriptedChecker: checker)
      for provider in [LLMProvider.egOne, .s1Mini, .appleIntelligence] {
        let selection = await eligibility.selection(provider: provider, language: "de")
        #expect(selection.identity == "uat_scripted")
        #expect(selection.checker?.armName == "uat_scripted")
        #expect(selection.absence == nil)
      }
      #expect(
        (await eligibility.selection(provider: .egOne, language: nil)).identity
          == "uat_scripted")
      let emptyChecker = LearnedWordCheckUATDoor.configuration(environment: [
        LearnedWordCheckUATDoor.environmentKey: " ,  \t "
      ])
      #expect(emptyChecker?.armName == nil)
      let emptyEligibility = LearnedWordCheckerEligibility(
        delivery: delivery,
        engines: [
          .egOne: .init(base: nil, promptTemplateID: nil, runtime: runtime, debugThreshold: nil)
        ],
        debugScriptedChecker: emptyChecker)
      #expect(
        (await emptyEligibility.selection(provider: .appleIntelligence, language: "de")).absence
          == .engineHasNoChecker)
      #expect(
        (await emptyEligibility.selection(provider: .s1Mini, language: "de")).absence
          == .engineHasNoChecker, "an engine the owner was not given has no checker")
    }

    /// The UAT drills set and clear these exact keys (`CHECKER_DOOR_KEYS` in
    /// `learn_from_edits_uat.py`, `ENGINES` in `auto_dictionary_bench.py`).
    @Test("each engine's adapter door reads only its own keys")
    func adapterDoorPerEngine() throws {
      let adapter = FileManager.default.temporaryDirectory
        .appendingPathComponent("door-\(UUID().uuidString).gguf")
      try Data([0]).write(to: adapter)
      defer { try? FileManager.default.removeItem(at: adapter) }
      let s1Only = [
        "EW_LEARNED_CHECK_S1_ADAPTER": adapter.path, "EW_LEARNED_CHECK_S1_THRESHOLD": "0.858",
      ]
      let s1 = try #require(LearnedWordCheckAdapterDoor.configuration(.s1Mini, environment: s1Only))
      #expect(s1.url.path == adapter.path)
      #expect(s1.threshold == 0.858)
      #expect(LearnedWordCheckAdapterDoor.configuration(.egOne, environment: s1Only) == nil)
      let egOneOnly = [
        "EW_LEARNED_CHECK_EG1_ADAPTER": adapter.path, "EW_LEARNED_CHECK_EG1_THRESHOLD": "0.481",
      ]
      let egOne = try #require(LearnedWordCheckAdapterDoor.configuration(.egOne, environment: egOneOnly))
      #expect(egOne.threshold == 0.481)
      #expect(LearnedWordCheckAdapterDoor.configuration(.s1Mini, environment: egOneOnly) == nil)
      #expect(LearnedWordCheckerEngine.s1Mini.label == "S1-mini")
      #expect(LearnedWordCheckerEngine.egOne.label == "EG-1")
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
    let baseName = engine == .egOne ? "eg1-delivery-manifest" : "s1-delivery-manifest"
    return (
      contract,
      AdmittedCheckerBase(
        manifest: try Self.manifest(baseName), promptTemplateID: contract.base.promptTemplateID)
    )
  }

  @Test(
    "ready, loading, mismatch and absent use one owner for both engines; the decision reads no language",
    arguments: LearnedWordCheckerEngine.allCases)
  func decisionMatrix(engine: LearnedWordCheckerEngine) throws {
    let (contract, base) = try pins(engine)
    let ready = EGOneEndpoint(
      port: 12345, authToken: "test", contextTokens: 1024,
      hasLearnedWordAdapter: true)
    func select(
      baseAdmitted: Bool = true, adapterAdmitted: Bool = true, state: DeliveryState = .admitted,
      hostConfigured: Bool = true, deliveryEnabled: Bool = true,
      admittedBase: AdmittedCheckerBase? = nil,
      endpoint: EGOneEndpoint? = nil, missingEndpoint: Bool = false,
      serverReason: String? = nil
    ) -> LearnedWordCheckerSelection {
      LearnedWordCheckerEligibility.evaluate(
        engine: engine, language: "de", baseAdmitted: baseAdmitted,
        adapterAdmitted: adapterAdmitted, deliveryState: state,
        hostConfigured: hostConfigured, deliveryEnabled: deliveryEnabled,
        contract: contract, admittedBase: admittedBase ?? base,
        endpoint: missingEndpoint ? nil : (endpoint ?? ready),
        serverReason: serverReason, hold: { nil })
    }
    let checker = try #require(select().checker as? EGOneLearnedWordChecker)
    #expect(checker.armName == (engine == .egOne ? "eg1_lora" : "s1_lora"))
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
      select(admittedBase: AdmittedCheckerBase(manifest: try Self.manifest(
        engine == .egOne ? "eg1-delivery-manifest" : "s1-delivery-manifest"),
        promptTemplateID: "wrong")).absence
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
    let (egOneContract, egOneBase) = try pins(.egOne)
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
  }

  @Test("every provider maps to its engine or to none, and back")
  func engineTable() {
    for provider in LLMProvider.allCases {
      let engine = LearnedWordCheckerEngine(provider: provider)
      #expect(engine?.provider == (engine == nil ? nil : provider))
    }
    #expect(LearnedWordCheckerEngine(provider: .egOne) == .egOne)
    #expect(LearnedWordCheckerEngine(provider: .s1Mini) == .s1Mini)
    #expect(Set(LearnedWordCheckerEngine.allCases.map(\.checkerFamily)) == [.egOneChecker, .s1MiniChecker])
    #expect(LearnedWordCheckerEngine.egOne.promptStyle(language: "de") == .egOne)
    #expect(LearnedWordCheckerEngine.s1Mini.promptStyle(language: "de") == .s1Mini(language: "de"))
  }
}
