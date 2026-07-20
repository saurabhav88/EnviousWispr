import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// Issue #158 ship gate: every Claude model the picker would offer must
/// polish successfully through the SHIPPED connector with the founder's
/// real key. Mirrors `OpenAILiveSweepTests.swift`.
///
/// LIVE test — network + spend (sub-cent per model at Haiku pricing; see
/// the plan's Cloud-spend authorization section for the $5 combined cap
/// across all live-API testing in this issue). Disabled unless
/// `EW_CLAUDE_LIVE_SWEEP=1`, so CI and ordinary local runs never execute it.
/// Run: `TEST_RUNNER_EW_CLAUDE_LIVE_SWEEP=1 scripts/xcode-test.sh --filter
/// EnviousWisprTests/ClaudeLiveSweepTests` (xcodebuild forwards TEST_RUNNER_-
/// prefixed vars into the test process). The DEBUG test bundle's key store is
/// the dev file store, so the key is the founder's local mirror file.
@Suite(
  "Claude all-models live sweep",
  .enabled(if: ProcessInfo.processInfo.environment["EW_CLAUDE_LIVE_SWEEP"] == "1"))
struct ClaudeLiveSweepTests {

  @Test(.timeLimit(.minutes(10)))
  func everyOfferedModelPolishesSuccessfully() async throws {
    let keychain = KeychainManager()
    let apiKey = try keychain.retrieve(key: KeychainManager.claudeKeyID)

    // The exact candidate population the picker offers: live models list
    // through the shipped filter + availability probe.
    let discovered = try await LLMModelDiscovery().discoverModels(provider: .claude, apiKey: apiKey)
    let offered = discovered.filter(\.isAvailable)
    #expect(!offered.isEmpty, "discovery returned no available models — sweep cannot run")

    let connector = ClaudeConnector(keychainManager: keychain)
    var failures: [String] = []
    var report: [String] = []

    for model in offered {
      // Mirror LLMPolishStep's config decisions for this model. Claude never
      // reasons (v1) so maxTokens/reasoningEffort never branch on capability
      // the way OpenAI's sweep does.
      let config = LLMProviderConfig(
        model: model.id,
        apiKeyKeychainId: KeychainManager.claudeKeyID,
        maxTokens: 512,
        temperature: 0,
        thinkingBudget: nil,
        reasoningEffort: nil
      )

      let start = ContinuousClock.now
      do {
        let result = try await connector.polish(
          text: "so um I think we should uh probably move the meeting to thursday afternoon",
          instructions: .default, config: config, onToken: nil)
        let elapsed = ContinuousClock.now - start
        report.append("PASS \(model.id) \(elapsed) -> \(result.polishedText.prefix(60))")
        if result.polishedText.isEmpty { failures.append("\(model.id): empty polish") }
      } catch {
        let elapsed = ContinuousClock.now - start
        failures.append("\(model.id): \(error) after \(elapsed)")
        report.append("FAIL \(model.id) \(elapsed) \(error)")
      }
    }

    print("=== Claude live sweep (\(offered.count) offered models) ===")
    for line in report { print(line) }

    #expect(failures.isEmpty, "sweep failures: \(failures.joined(separator: " | "))")
  }
}
