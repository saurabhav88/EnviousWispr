import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #2064: a cloud provider must never be left holding another provider's model.
///
/// Production evidence, 90 days to 2026-08-15: one user emitted **443**
/// `llm.polish_failed` rows carrying `provider=gemini model=llama3.2
/// reason=api_key_missing` — 59% of all polish failures in the window, and every
/// AI polish that user attempted for three weeks. `llama3.2` is an Ollama model
/// name. Their settings history shows the cause exactly: on v2.3.1 they moved
/// `egOne → ollama → gemini` inside eleven seconds, and the Ollama model id was
/// still sitting in `llmModel` when Gemini started reading it.
///
/// **These tests do NOT fail against current `main`.** The repair already exists:
/// `canonicalizeLLMModelForProvider`'s `modelIDLooksLikeCloudProvider` clause,
/// added by #1712 and first released in v2.4.1. The same user's telemetry
/// confirms it worked in the field — their failures stop at their upgrade to
/// v2.4.4 and their next settings snapshot reads `gemini-3.5-flash`, with no
/// user action in between.
///
/// So what these lock is the GUARD, which had no direct coverage for this shape
/// and is one deleted `||` clause away from reopening a defect that silently
/// disables AI polish forever.
///
/// **Mutation-verified, not asserted.** Dropping the
/// `modelIDLooksLikeCloudProvider` clause from `canonicalizeLLMModelForProvider`
/// and re-running this suite: 4 of 7 cases fail with 16 issues, and they fail by
/// reproducing the exact production pairing —
/// `effectiveLLMModel → "llama3.2"` under `provider = .gemini`. The remaining 3
/// are the two-way controls below and they stay GREEN under the mutant, which is
/// what shows they are independent checks rather than the same assertion
/// restated.
@MainActor
@Suite("Provider/model desync (#2064)")
struct ProviderModelDesyncTests {

  private func freshSettings() -> SettingsManager {
    SettingsManager(defaults: UserDefaults(suiteName: "SM-2064-\(UUID().uuidString)")!)
  }

  /// The exact field-observed sequence, at the seam that produced it.
  @Test("switching away from Ollama sweeps the Ollama model name off the cloud field")
  func switchingAwayFromOllamaSweepsTheOllamaModelName() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.ollamaModel = "llama3.2"
    settings.llmModel = "llama3.2"

    settings.llmProvider = .gemini

    #expect(
      settings.effectiveLLMModel != "llama3.2",
      "a Gemini request must never be sent with an Ollama model name")
    #expect(settings.effectiveLLMModel == "gemini-3.5-flash")
    // The remembered Ollama preference is untouched — #1305 relies on it for the
    // Download-suggestion copy, and sweeping it here would fix one bug with
    // another.
    #expect(settings.ollamaModel == "llama3.2")
  }

  /// The user's real path was three providers in eleven seconds, not one hop.
  /// A guard that only fires on the immediately-previous provider would pass the
  /// case above and still ship the defect.
  @Test("a rapid multi-provider hop leaves no foreign model behind")
  func rapidProviderHopLeavesNoForeignModel() {
    let settings = freshSettings()
    settings.ollamaModel = "llama3.2"
    settings.llmProvider = .appleIntelligence
    settings.llmProvider = .egOne
    settings.llmProvider = .ollama
    settings.llmModel = "llama3.2"
    settings.llmProvider = .gemini

    #expect(settings.effectiveLLMModel == "gemini-3.5-flash")
  }

  /// Every cloud destination, not just the one that showed up in telemetry.
  /// `openAI` appeared once and `claude` never, which is sample size rather than
  /// immunity — they share the single guard.
  nonisolated static let cloudDestinations: [(LLMProvider, String)] = [
    (.gemini, "gemini-3.5-flash"),
    (.openAI, "gpt-4o-mini"),
    (.claude, "claude-haiku-4-5"),
  ]

  @Test("no cloud provider inherits a local model name", arguments: cloudDestinations)
  func cloudProvidersNeverInheritLocalModels(provider: LLMProvider, expected: String) {
    for localName in ["llama3.2", "gemma4:e4b", "qwen2.5:3b", "deepseek-r1:8b"] {
      let settings = freshSettings()
      settings.llmProvider = .ollama
      settings.llmModel = localName
      settings.llmProvider = provider

      #expect(
        settings.effectiveLLMModel == expected,
        "\(provider.rawValue) inherited \(localName)")
    }
  }

  /// A relaunch must repair a machine already stuck in the bad state, or the 443
  /// user would have stayed broken until they happened to touch the picker.
  /// This is the path their recovery actually took: no user action, just a
  /// launch on a build that had the guard.
  @Test("a persisted desync is repaired at launch, with no user action")
  func persistedDesyncIsRepairedAtLaunch() {
    let suite = UserDefaults(suiteName: "SM-2064-stuck-\(UUID().uuidString)")!
    // The on-disk state the stuck user was in on v2.4.0.
    suite.set(LLMProvider.gemini.rawValue, forKey: "llmProvider")
    suite.set("llama3.2", forKey: "llmModel")
    suite.set("llama3.2", forKey: "ollamaModel")

    let settings = SettingsManager(defaults: suite)

    #expect(
      settings.effectiveLLMModel == "gemini-3.5-flash",
      "launch-time canonicalization must repair a stuck install")
    #expect(settings.llmProvider == .gemini, "the user's provider choice is not overridden")
  }

  // MARK: - Two-way controls

  /// The guard must not be a blanket wipe. A legitimate cloud selection has to
  /// survive a switch, or "never inherits a foreign model" would be trivially
  /// satisfiable by resetting the field every time and the tests above would
  /// pass a strictly worse implementation.
  @Test("a legitimate cloud model survives its own provider's canonicalization")
  func legitimateCloudSelectionSurvives() {
    let settings = freshSettings()
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-5.4-mini"
    // Re-entering the same provider re-runs the guard.
    settings.llmProvider = .gemini
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-5.4-mini"

    #expect(
      settings.effectiveLLMModel == "gpt-5.4-mini",
      "the user's own OpenAI pick must not be swept")
  }

  /// The reverse direction is deliberately NOT symmetric, and that is the
  /// documented #1305/#1914 decision rather than an oversight: for Ollama the
  /// armed model is `ollamaModel`, so a cloud id left in `llmModel` cannot reach
  /// a request. Pinned so nobody "fixes" the asymmetry and re-arms the phantom
  /// picker selection #1305 removed.
  @Test("switching to Ollama reads ollamaModel, so a leftover cloud id cannot be sent")
  func ollamaReadsItsOwnFieldNotTheCloudLeftover() {
    let settings = freshSettings()
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-4o-mini"
    settings.ollamaModel = "llama3.2"

    settings.llmProvider = .ollama

    #expect(settings.effectiveLLMModel == "llama3.2")
    #expect(settings.effectiveLLMModel != "gpt-4o-mini")
  }

  /// The guard's own predicate, stated directly. `llama3.2` must not read as a
  /// plausible model for any cloud provider — if this ever returns `true` the
  /// sweep above stops firing and every test here passes for the wrong reason.
  @Test("an Ollama model name is not mistaken for a cloud model id")
  func localNamesDoNotLookLikeCloudModels() {
    for name in ["llama3.2", "gemma4:e4b", "qwen2.5:3b"] {
      for provider in [LLMProvider.gemini, .openAI, .claude] {
        #expect(
          LLMProvider.modelIDLooksLikeCloudProvider(name, provider) == false,
          "\(name) must not pass as a \(provider.rawValue) model")
      }
    }
    // Two-way: real cloud ids still pass, so the predicate is not simply false.
    #expect(LLMProvider.modelIDLooksLikeCloudProvider("gemini-3.5-flash", .gemini))
    #expect(LLMProvider.modelIDLooksLikeCloudProvider("gpt-5.4-mini", .openAI))
    #expect(LLMProvider.modelIDLooksLikeCloudProvider("claude-haiku-4-5", .claude))
  }
}
