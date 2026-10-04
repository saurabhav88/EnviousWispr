import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #3425 ship gate for Gemini: every Gemini model the picker would offer must polish real
/// dictations successfully through the SHIPPED connector with the founder's real key, using
/// the thinking value `LLMModelCapabilities` resolves for it. `gemini-3.8-flash` is required
/// to be offered: it is the model whose missing thinking row took 3 to 14 seconds per
/// dictation, and the report prints every model's median latency so a regression shows.
///
/// LIVE test — network + spend (sub-cent per model). Disabled unless
/// `EW_GEMINI_LIVE_SWEEP=1`. Run: `TEST_RUNNER_EW_GEMINI_LIVE_SWEEP=1 scripts/xcode-test.sh
/// --filter EnviousWisprTests/GeminiLiveSweepTests`. The key is the dev file store's mirror.
@Suite(
  "Gemini all-models live sweep",
  .tags(.productOutcome, .realBoundary),
  .enabled(if: ProcessInfo.processInfo.environment["EW_GEMINI_LIVE_SWEEP"] == "1"))
struct GeminiLiveSweepTests {

  @Test(.timeLimit(.minutes(15)))
  func everyOfferedModelPolishesSuccessfully() async throws {
    let keychain = KeychainManager()
    let apiKey = try keychain.retrieve(key: KeychainManager.geminiKeyID)

    let discovered = try await LLMModelDiscovery().discoverModels(provider: .gemini, apiKey: apiKey)
    let offered = LiveSweepSupport.narrowed(discovered.filter(\.isAvailable))
    #expect(!offered.isEmpty, "discovery returned no available models — sweep cannot run")
    if ProcessInfo.processInfo.environment["EW_SWEEP_ONLY"] == nil {
      #expect(
        offered.contains { $0.id == "gemini-3.8-flash" },
        "gemini-3.8-flash must be offered; offered: \(offered.map(\.id))")
    }

    let connector = GeminiConnector(keychainManager: keychain)
    var failures: [String] = []
    var report: [String] = []
    let sentences = Array(LiveSweepSupport.realDictations.prefix(5))

    for model in offered {
      var thinking: ResolvedThinking?
      switch LLMProvider.gemini.modelCapabilities(model: model.id).thinkingControl {
      case .budget(let value): thinking = .budget(value)
      case .level(let value): thinking = .level(value)
      case .effort, .unsupported: thinking = nil
      }
      let config = LLMProviderConfig(
        model: model.id, apiKeyKeychainId: KeychainManager.geminiKeyID,
        outputTokens: .providerDefault, temperature: 0, thinking: thinking)

      var times: [Double] = []
      var problems: [String] = []
      for sentence in sentences {
        let envelope = LiveSweepSupport.productionEnvelope(
          provider: .gemini, modelID: model.id, transcript: sentence)
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
      let median = Int(LiveSweepSupport.medianMs(times))
      let shape = thinking.map { "\($0)" } ?? "none"
      if problems.isEmpty {
        report.append("PASS \(model.id) thinking=\(shape) median=\(median)ms n=\(times.count)")
      } else {
        failures.append("\(model.id): \(problems.joined(separator: "; "))")
        report.append("FAIL \(model.id) thinking=\(shape) \(problems.joined(separator: "; "))")
      }
    }

    print("=== Gemini live sweep (\(offered.count) offered models) ===")
    for line in report { print(line) }

    #expect(failures.isEmpty, "sweep failures: \(failures.joined(separator: " | "))")
  }
}
