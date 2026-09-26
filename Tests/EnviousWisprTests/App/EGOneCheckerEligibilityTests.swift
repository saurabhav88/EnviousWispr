import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

@MainActor
@Suite("EG-1 checker eligibility (#3105)", .tags(.productOutcome))
struct EGOneCheckerEligibilityTests {
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
      let eligibility = EGOneCheckerEligibility(
        delivery: delivery, base: nil, promptTemplateID: nil, runtime: runtime,
        debugThreshold: 0.99, debugScriptedChecker: checker)
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
      let emptyEligibility = EGOneCheckerEligibility(
        delivery: delivery, base: nil, promptTemplateID: nil, runtime: runtime,
        debugScriptedChecker: emptyChecker)
      #expect(
        (await emptyEligibility.selection(provider: .s1Mini, language: "de")).absence
          == .notEGOne)
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
      #expect(LearnedWordCheckAdapterDoor.Engine.s1Mini.label == "S1-mini")
      #expect(LearnedWordCheckAdapterDoor.Engine.egOne.label == "EG-1")
    }
  #endif

  private func pins() throws -> (EGOneCheckerContract, AdmittedEGOneBase) {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let resources = root.appendingPathComponent("Sources/EnviousWispr/Resources")
    let checker = try DeliveryManifest.load(
      from: Data(
        contentsOf:
          resources
          .appendingPathComponent("eg1-checker-delivery-manifest.json")))
    let contract = try #require(checker.checkerContract)
    let base = try DeliveryManifest.load(
      from: Data(
        contentsOf:
          resources
          .appendingPathComponent("eg1-delivery-manifest.json")))
    return (
      contract,
      AdmittedEGOneBase(
        manifest: base, promptTemplateID: contract.base.promptTemplateID)
    )
  }

  @Test("ready, loading, mismatch and absent use one owner; the decision reads no language")
  func decisionMatrix() throws {
    let (contract, base) = try pins()
    let ready = EGOneEndpoint(
      port: 12345, authToken: "test", contextTokens: 1024,
      hasLearnedWordAdapter: true)
    func select(
      provider: LLMProvider = .egOne, baseAdmitted: Bool = true,
      adapterAdmitted: Bool = true, state: DeliveryState = .admitted,
      admittedBase: AdmittedEGOneBase? = nil,
      endpoint: EGOneEndpoint? = nil, serverReason: String? = nil
    ) -> LearnedWordCheckerSelection {
      EGOneCheckerEligibility.evaluate(
        provider: provider, baseAdmitted: baseAdmitted,
        adapterAdmitted: adapterAdmitted, deliveryState: state,
        contract: contract, admittedBase: admittedBase ?? base,
        endpoint: endpoint ?? ready,
        serverReason: serverReason, hold: { nil })
    }
    #expect(select().checker != nil)
    #expect(select(provider: .s1Mini).absence == .notEGOne)
    #expect(select(provider: .appleIntelligence).absence == .notEGOne)
    #expect(select(provider: .openAI).absence == .notEGOne)
    #expect(select(baseAdmitted: false).absence == .baseNotAdmitted)
    #expect(
      select(
        adapterAdmitted: false,
        state: .downloading(
          fractionCompleted: 0.5, bytesWritten: 1, totalBytes: 2)
      ).absence == .adapterDownloading)
    #expect(
      select(adapterAdmitted: false, state: .cancelled(resumable: true))
        .absence == .adapterDeliveryFailed)
    #expect(
      select(adapterAdmitted: false, state: .cancelled(resumable: true))
        .retryAvailable)
    #expect(
      !EGOneCheckerEligibility.evaluate(
        provider: .egOne, baseAdmitted: true, adapterAdmitted: false,
        deliveryState: .notReady, hostConfigured: false, contract: contract,
        admittedBase: base, endpoint: ready, serverReason: nil, hold: { nil }
      ).retryAvailable)
    #expect(
      EGOneCheckerEligibility.evaluate(
        provider: .egOne, baseAdmitted: true, adapterAdmitted: false,
        deliveryState: .notReady, deliveryEnabled: false, contract: contract,
        admittedBase: base, endpoint: ready, serverReason: nil, hold: { nil }
      ).absence
        == .deliveryDisabled)
    #expect(
      EGOneCheckerEligibility.evaluate(
        provider: .egOne, baseAdmitted: true, adapterAdmitted: false,
        deliveryState: .notReady, hostConfigured: false, deliveryEnabled: false,
        contract: contract, admittedBase: base, endpoint: ready,
        serverReason: nil, hold: { nil }
      ).absence == .deliveryDisabled)
    #expect(
      EGOneCheckerEligibility.evaluate(
        provider: .egOne, baseAdmitted: true, adapterAdmitted: true,
        deliveryState: .admitted, deliveryEnabled: false, contract: contract,
        admittedBase: base, endpoint: ready, serverReason: nil, hold: { nil }
      ).checker != nil)
    #expect(
      select(admittedBase: try mismatchedBase()).absence
        == .baseMismatch("prompt_template"))
    #expect(
      EGOneCheckerEligibility.evaluate(
        provider: .egOne, baseAdmitted: true, adapterAdmitted: true,
        deliveryState: .admitted, contract: contract, admittedBase: base,
        endpoint: nil, serverReason: nil, hold: { nil }
      ).absence == .serverUnavailable)
    #expect(
      select(
        endpoint: .init(port: 12345, authToken: "test", contextTokens: 1024),
        serverReason: "adapter_server_exited"
      ).absence
        == .serverWithoutAdapter("adapter_server_exited"))
  }

  private func mismatchedBase() throws -> AdmittedEGOneBase {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let base = try DeliveryManifest.load(
      from: Data(
        contentsOf: root.appendingPathComponent(
          "Sources/EnviousWispr/Resources/eg1-delivery-manifest.json")))
    return AdmittedEGOneBase(manifest: base, promptTemplateID: "wrong")
  }
}
