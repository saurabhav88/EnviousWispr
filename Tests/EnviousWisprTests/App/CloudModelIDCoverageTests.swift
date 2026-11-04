import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

#if DEBUG

  /// #3425: `gemini-3.8-flash` was added to the telemetry allowlist but never to the thinking
  /// table (now the cloud model list, #4353 D6), so it shipped thinking by default and took 3 to 14 seconds per dictation. The
  /// two lists have different reasons to change (a privacy deny-list versus a request shape),
  /// so they stay two lists; this suite is the link.
  ///
  /// Class: Drift Guard. When it fails, a developer sees a curated Gemini id with no recorded
  /// thinking decision. The user-facing proof that the decisions work is the live sweeps and
  /// Live UAT. It covers the ids curated here, not every id discovery could return.
  @MainActor
  @Suite("Cloud model id coverage (#3425)", .tags(.driftGuard))
  struct CloudModelIDCoverageTests {

    // #4353 D6 deleted "every curated Gemini id has a recorded thinking decision": it linked
    // two compiled lists (telemetry's Gemini ids and the thinking table) that could drift.
    // Recognition and request policy now come from the same cloud model list row, so a
    // recognised id without a decision cannot exist; `CloudModelListTests` holds the frozen
    // allowlist and baseline proofs.

    @Test("The new OpenAI and Claude ids no longer read as custom in settings snapshots")
    func newIDsAreRecognised() {
      func project(_ provider: LLMProvider, _ model: String) -> String? {
        let suite = TestDefaults.suite("CMIC-\(UUID().uuidString)")!
        let settings = SettingsManager(defaults: suite)
        settings.llmProvider = provider
        settings.llmModel = model
        return SettingsProjection.value(for: .llmModel, settings: settings, list: CloudModelListSeed.current)
      }
      for id in ["gpt-6-luna", "gpt-6-sol", "gpt-6-astra", "gpt-6.1-sol"] {
        #expect(project(.openAI, id) == id, "\(id) must not read as custom")
      }
      for id in ["claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5", "claude-fable-5-1"] {
        #expect(project(.claude, id) == id, "\(id) must not read as custom")
      }
      // The deny-by-default anchor still holds.
      #expect(project(.openAI, "gpt-6-my-private-tune") == "custom")
    }
  }

#endif
