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
      let checker = try #require(LearnedWordCheckUATDoor.configuration(environment: [
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
      #expect((await eligibility.selection(provider: .egOne, language: nil)).identity
        == "uat_scripted")
      let emptyChecker = LearnedWordCheckUATDoor.configuration(environment: [
        LearnedWordCheckUATDoor.environmentKey: " ,  \t ",
      ])
      #expect(emptyChecker?.armName == nil)
      let emptyEligibility = EGOneCheckerEligibility(
        delivery: delivery, base: nil, promptTemplateID: nil, runtime: runtime,
        debugScriptedChecker: emptyChecker)
      #expect((await emptyEligibility.selection(provider: .s1Mini, language: "de")).absence
        == .notEGOne)
    }
  #endif

  private func pins() throws -> (EGOneCheckerContract, AdmittedEGOneBase) {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let resources = root.appendingPathComponent("Sources/EnviousWispr/Resources")
    let checker = try DeliveryManifest.load(from: Data(contentsOf: resources
      .appendingPathComponent("eg1-checker-delivery-manifest.json")))
    let contract = try #require(checker.checkerContract)
    let base = try DeliveryManifest.load(from: Data(contentsOf: resources
      .appendingPathComponent("eg1-delivery-manifest.json")))
    return (contract, AdmittedEGOneBase(
      manifest: base, promptTemplateID: contract.base.promptTemplateID))
  }

  @Test("ready, loading, mismatch, absent, and language refusal use one owner")
  func decisionMatrix() throws {
    let (contract, base) = try pins()
    let ready = EGOneEndpoint(
      port: 12345, authToken: "test", contextTokens: 1024,
      hasLearnedWordAdapter: true)
    func select(
      provider: LLMProvider = .egOne, baseAdmitted: Bool = true,
      adapterAdmitted: Bool = true, state: DeliveryState = .admitted,
      admittedBase: AdmittedEGOneBase? = nil, language: String? = "en",
      endpoint: EGOneEndpoint? = nil, serverReason: String? = nil
    ) -> LearnedWordCheckerSelection {
      EGOneCheckerEligibility.evaluate(
        provider: provider, baseAdmitted: baseAdmitted,
        adapterAdmitted: adapterAdmitted, deliveryState: state,
        contract: contract, admittedBase: admittedBase ?? base,
        language: language, endpoint: endpoint ?? ready,
        serverReason: serverReason)
    }
    #expect(select().checker != nil)
    #expect(select(provider: .s1Mini).absence == .notEGOne)
    #expect(select(provider: .appleIntelligence).absence == .notEGOne)
    #expect(select(provider: .openAI).absence == .notEGOne)
    #expect(select(baseAdmitted: false).absence == .baseNotAdmitted)
    #expect(select(adapterAdmitted: false, state: .downloading(
      fractionCompleted: 0.5, bytesWritten: 1, totalBytes: 2)).absence == .adapterDownloading)
    #expect(select(adapterAdmitted: false, state: .cancelled(resumable: true))
      .absence == .adapterDeliveryFailed)
    #expect(select(admittedBase: try mismatchedBase()).absence
      == .baseMismatch("prompt_template"))
    #expect(select(language: "de").absence == .unqualifiedLanguage)
    #expect(select(language: nil).absence == .unqualifiedLanguage)
    #expect(EGOneCheckerEligibility.evaluate(
      provider: .egOne, baseAdmitted: true, adapterAdmitted: true,
      deliveryState: .admitted, contract: contract, admittedBase: base,
      language: "en", endpoint: nil, serverReason: nil).absence == .serverUnavailable)
    #expect(select(endpoint: .init(port: 12345, authToken: "test", contextTokens: 1024),
      serverReason: "adapter_server_exited").absence
      == .serverWithoutAdapter("adapter_server_exited"))
  }

  private func mismatchedBase() throws -> AdmittedEGOneBase {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let base = try DeliveryManifest.load(from: Data(contentsOf: root.appendingPathComponent(
      "Sources/EnviousWispr/Resources/eg1-delivery-manifest.json")))
    return AdmittedEGOneBase(manifest: base, promptTemplateID: "wrong")
  }
}
