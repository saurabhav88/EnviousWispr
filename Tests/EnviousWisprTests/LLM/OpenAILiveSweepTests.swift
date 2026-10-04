import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #1330 ship gate: every OpenAI model the picker would offer must polish
/// successfully through the SHIPPED connector with the founder's real key.
///
/// #3425: each model now polishes the real dictations in `LiveSweepSupport` using the thinking
/// value `LLMModelCapabilities` resolves for it (the earlier version hardcoded effort `low`,
/// which would have hidden a wrong table row), and the report prints each model's median
/// latency so a slow generation is visible.
///
/// LIVE test — network + spend (sub-cent per model). Disabled unless
/// `EW_OPENAI_LIVE_SWEEP=1`, so CI and ordinary local runs never execute it.
/// Run: `TEST_RUNNER_EW_OPENAI_LIVE_SWEEP=1 scripts/xcode-test.sh --filter
/// EnviousWisprTests/OpenAILiveSweepTests` (xcodebuild forwards TEST_RUNNER_-
/// prefixed vars into the test process). The DEBUG test bundle's key store is
/// the dev file store, so the key is the founder's local mirror file; when that file is
/// absent, pass the key through the environment without writing it anywhere:
/// `get-key launch openai-api-key TEST_RUNNER_EW_LIVE_OPENAI_KEY -- scripts/xcode-test.sh ...`.
@Suite(
  "OpenAI all-models live sweep",
  .enabled(if: ProcessInfo.processInfo.environment["EW_OPENAI_LIVE_SWEEP"] == "1"))
struct OpenAILiveSweepTests {

  @Test(.timeLimit(.minutes(15)))
  func everyOfferedModelPolishesSuccessfully() async throws {
    let keychain = LiveSweepSupport.keychain(
      keyID: KeychainManager.openAIKeyID, envVar: "EW_LIVE_OPENAI_KEY")
    let apiKey = try keychain.retrieve(key: KeychainManager.openAIKeyID)

    // The exact candidate population the picker offers: live models list
    // through the shipped filter + availability probe.
    let discovered = try await LLMModelDiscovery().discoverModels(provider: .openAI, apiKey: apiKey)
    let offered = LiveSweepSupport.narrowed(discovered.filter(\.isAvailable))
    #expect(!offered.isEmpty, "discovery returned no available models — sweep cannot run")
    // #3425: a nonempty set can pass while the changed models are missing from it, so every id the
    // effort table names, plus the two that reject `none`, must be offered.
    if ProcessInfo.processInfo.environment["EW_SWEEP_ONLY"] == nil {
      for required in [
        "gpt-6-luna", "gpt-6-sol", "gpt-6-astra", "gpt-6.1-sol", "gpt-5.6-luna", "gpt-5.6-terra",
        "gpt-5.6-sol", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.2",
      ] {
        #expect(offered.contains { $0.id == required }, "\(required) must be offered")
      }
    }

    let connector = OpenAIConnector(keychainManager: keychain)
    var failures: [String] = []
    var report: [String] = []

    // Real dictations, 5 per model keeps the whole sweep within the time limit.
    let sentences = Array(LiveSweepSupport.realDictations.prefix(5))

    for model in offered {
      // Mirror LLMPolishStep's config decisions for this model.
      let capabilities = LLMProvider.openAI.modelCapabilities(model: model.id)
      var thinking: ResolvedThinking?
      if case .effort(let value) = capabilities.thinkingControl { thinking = .effort(value) }
      let config = LLMProviderConfig(
        model: model.id,
        apiKeyKeychainId: KeychainManager.openAIKeyID,
        outputTokens: .providerDefault,
        temperature: 0,
        thinking: thinking
      )

      var times: [Double] = []
      var problems: [String] = []
      for sentence in sentences {
        let envelope = LiveSweepSupport.productionEnvelope(
          provider: .openAI, modelID: model.id, transcript: sentence)
        let start = ContinuousClock.now
        do {
          let result = try await connector.polish(envelope: envelope, config: config, onToken: nil)
          let elapsed = ContinuousClock.now - start
          times.append(
            Double(elapsed.components.seconds) * 1000
              + Double(elapsed.components.attoseconds) / 1e15)
          if let problem = LiveSweepSupport.problem(input: sentence, output: result.polishedText) {
            problems.append("\(problem) for \"\(sentence.prefix(40))\"")
          }
        } catch {
          problems.append("\(error) for \"\(sentence.prefix(40))\"")
        }
      }
      let strips = OpenAIConnector.memoizedOmissions(model: model.id)
      // A stripped `reasoning_effort` means the table sent a value OpenAI rejected and the
      // connector silently fell back to the provider default (slower): that is a failure here.
      if strips.contains("reasoning_effort") {
        problems.append("reasoning_effort was rejected and stripped (table value is wrong)")
      }
      let stripNote = strips.isEmpty ? "" : " adapted=\(strips.sorted().joined(separator: "+"))"
      let effort: String
      if case .effort(let value)? = thinking { effort = value } else { effort = "-" }
      let median = Int(LiveSweepSupport.medianMs(times))
      if problems.isEmpty {
        report.append(
          "PASS \(model.id) effort=\(effort) median=\(median)ms n=\(times.count)\(stripNote)")
      } else {
        failures.append("\(model.id): \(problems.joined(separator: "; "))")
        report.append("FAIL \(model.id) effort=\(effort) \(problems.joined(separator: "; "))")
      }
    }

    print("=== OpenAI live sweep (\(offered.count) offered models) ===")
    for line in report { print(line) }

    #expect(failures.isEmpty, "sweep failures: \(failures.joined(separator: " | "))")
  }
}
