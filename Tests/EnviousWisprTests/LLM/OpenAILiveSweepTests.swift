import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #1330 ship gate: every OpenAI model the picker would offer must polish
/// successfully through the SHIPPED connector with the founder's real key.
///
/// LIVE test — network + spend (sub-cent per model). Disabled unless
/// `EW_OPENAI_LIVE_SWEEP=1`, so CI and ordinary local runs never execute it.
/// Run: `TEST_RUNNER_EW_OPENAI_LIVE_SWEEP=1 scripts/xcode-test.sh --filter
/// EnviousWisprTests/OpenAILiveSweepTests` (xcodebuild forwards TEST_RUNNER_-
/// prefixed vars into the test process). The DEBUG test bundle's key store is
/// the dev file store, so the key is the founder's local mirror file.
@Suite(
  "OpenAI all-models live sweep",
  .enabled(if: ProcessInfo.processInfo.environment["EW_OPENAI_LIVE_SWEEP"] == "1"))
struct OpenAILiveSweepTests {

  @Test(.timeLimit(.minutes(10)))
  func everyOfferedModelPolishesSuccessfully() async throws {
    let keychain = KeychainManager()
    let apiKey = try keychain.retrieve(key: KeychainManager.openAIKeyID)

    // The exact candidate population the picker offers: live models list
    // through the shipped filter + availability probe.
    let discovered = try await LLMModelDiscovery().discoverModels(provider: .openAI, apiKey: apiKey)
    let offered = discovered.filter(\.isAvailable)
    #expect(!offered.isEmpty, "discovery returned no available models — sweep cannot run")

    let connector = OpenAIConnector(keychainManager: keychain)
    var failures: [String] = []
    var report: [String] = []

    for model in offered {
      // Mirror LLMPolishStep's config decisions for this model.
      let capabilities = LLMProvider.openAI.modelCapabilities(model: model.id)
      let config = LLMProviderConfig(
        model: model.id,
        apiKeyKeychainId: KeychainManager.openAIKeyID,
        outputTokens: .providerDefault,
        temperature: 0,
        thinkingBudget: nil,
        reasoningEffort: capabilities.supportsReasoning ? "low" : nil
      )

      let start = ContinuousClock.now
      do {
        let result = try await connector.polish(
          text: "so um I think we should uh probably move the meeting to thursday afternoon",
          instructions: .default, config: config, onToken: nil)
        let elapsed = ContinuousClock.now - start
        let strips = OpenAIConnector.memoizedOmissions(model: model.id)
        let stripNote = strips.isEmpty ? "" : " adapted=\(strips.sorted().joined(separator: "+"))"
        report.append(
          "PASS \(model.id) \(elapsed)\(stripNote) -> \(result.polishedText.prefix(60))")
        if result.polishedText.isEmpty { failures.append("\(model.id): empty polish") }
      } catch {
        let elapsed = ContinuousClock.now - start
        failures.append("\(model.id): \(error) after \(elapsed)")
        report.append("FAIL \(model.id) \(elapsed) \(error)")
      }
    }

    print("=== OpenAI live sweep (\(offered.count) offered models) ===")
    for line in report { print(line) }

    #expect(failures.isEmpty, "sweep failures: \(failures.joined(separator: " | "))")
  }
}
