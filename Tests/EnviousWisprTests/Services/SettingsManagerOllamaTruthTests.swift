import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #1305: settings truth for the Ollama model fields. The picker's `llmModel`
/// may never be armed to a model the installed list does not contain — empty
/// discovery clears it (was: refilled the remembered phantom, the #1305 root
/// cause), launch-time canonicalization leaves "" alone, and the remembered
/// `ollamaModel` preference survives both (it powers the Download-suggestion
/// copy).
@MainActor
@Suite("SettingsManager Ollama model truth (#1305)")
struct SettingsManagerOllamaTruthTests {

  private func freshSettings(seed: ((UserDefaults) -> Void)? = nil) -> SettingsManager {
    let suite = UserDefaults(suiteName: "SM-1305-\(UUID().uuidString)")!
    seed?(suite)
    return SettingsManager(defaults: suite)
  }

  private func model(_ id: String, available: Bool = true) -> LLMModelInfo {
    LLMModelInfo(id: id, displayName: id, provider: .ollama, isAvailable: available)
  }

  // MARK: - Empty discovery (the root-cause fix)

  @Test("ollama empty discovery clears llmModel and preserves ollamaModel")
  func emptyDiscoveryClears() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.llmModel = "llama2:latest"  // the Baltimore phantom
    settings.ollamaModel = "llama2:latest"

    settings.applyDiscoveredModels([], for: .ollama)

    #expect(settings.llmModel == "")
    // The remembered preference stays — it drives the Download-button copy.
    #expect(settings.ollamaModel == "llama2:latest")
  }

  @Test("cloud empty discovery keeps the provider default (unchanged behavior)")
  func cloudEmptyDiscoveryKeepsDefault() {
    let settings = freshSettings()
    settings.llmProvider = .openAI

    settings.applyDiscoveredModels([], for: .openAI)

    #expect(settings.llmModel == LLMProvider.defaultModel(for: .openAI))
    #expect(!settings.llmModel.isEmpty)
  }

  @Test("stale empty discovery for a switched-away provider is dropped")
  func staleEmptyDiscoveryDropped() {
    let settings = freshSettings()
    settings.llmProvider = .openAI
    let before = settings.llmModel

    settings.applyDiscoveredModels([], for: .ollama)

    #expect(settings.llmModel == before)
  }

  // MARK: - Armed-model-deleted, others remain (characterization of :754-758)

  @Test("armed model missing from discovery auto-selects the first available and mirrors it")
  func armedMissingAutoSelectsFirst() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.llmModel = "deleted-model"
    settings.ollamaModel = "deleted-model"

    settings.applyDiscoveredModels([model("mistral"), model("phi3")], for: .ollama)

    #expect(settings.llmModel == "mistral")
    #expect(settings.ollamaModel == "mistral")
  }

  @Test("an armed model present in discovery is left alone")
  func armedPresentUntouched() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.llmModel = "phi3"
    settings.ollamaModel = "phi3"

    settings.applyDiscoveredModels([model("mistral"), model("phi3")], for: .ollama)

    #expect(settings.llmModel == "phi3")
    #expect(settings.ollamaModel == "phi3")
  }

  // MARK: - Launch-time canonicalization

  @Test("a persisted empty llmModel stays empty at launch under ollama")
  func persistedEmptyStaysEmpty() {
    let settings = freshSettings { suite in
      suite.set("ollama", forKey: "llmProvider")
      suite.set("", forKey: "llmModel")
      suite.set("llama3.2", forKey: "ollamaModel")
    }

    // Pre-#1305, init's canonicalize pass refilled "" from ollamaModel,
    // silently re-arming the phantom the last discovery pass had cleared.
    #expect(settings.llmProvider == .ollama)
    #expect(settings.llmModel == "")
    #expect(settings.ollamaModel == "llama3.2")
  }

  @Test("a persisted fixed literal is still swept at launch under ollama")
  func fixedLiteralStillSwept() {
    let settings = freshSettings { suite in
      suite.set("ollama", forKey: "llmProvider")
      suite.set("apple-intelligence", forKey: "llmModel")
      suite.set("llama3.2", forKey: "ollamaModel")
    }

    // The fixed-literal sweep (#1271 r7) must survive the empty-stays-empty
    // change: an AFM literal leaking into the ollama slot is still repaired
    // from the remembered preference.
    #expect(settings.llmModel == "llama3.2")
  }

  @Test("cloud providers still refill an empty llmModel at launch (unchanged)")
  func cloudEmptyRefilledAtLaunch() {
    let settings = freshSettings { suite in
      suite.set("openAI", forKey: "llmProvider")
      suite.set("", forKey: "llmModel")
    }

    #expect(settings.llmModel == LLMProvider.defaultModel(for: .openAI))
  }

  // MARK: - Cross-cloud-provider model bleed (#158, Codex r4)

  @Test("a live provider switch away from a cloud provider sweeps that provider's model id")
  func liveSwitchSweepsForeignCloudModel() {
    let settings = freshSettings()
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-4o"

    settings.llmProvider = .claude

    // Without the sweep, "gpt-4o" would survive the switch unchanged and
    // every Claude prewarm/polish request would fail until async discovery
    // happens to repair it (or persist broken across relaunches if
    // discovery never runs, e.g. offline or no key saved yet).
    #expect(settings.llmModel == LLMProvider.defaultModel(for: .claude))
  }

  @Test("a persisted foreign-cloud model id is swept at launch too")
  func launchSweepsForeignCloudModel() {
    let settings = freshSettings { suite in
      suite.set("claude", forKey: "llmProvider")
      suite.set("gemini-2.0-flash", forKey: "llmModel")
    }

    #expect(settings.llmModel == LLMProvider.defaultModel(for: .claude))
  }

  // MARK: - Retired-model sweep (#1770)

  /// Google shut down `gemini-2.0-flash` on 2026-06-01. It is a well-formed
  /// Gemini id, so the foreign-provider check waves it through and a pinned
  /// user 404s on every dictation forever — discovery does not run at launch,
  /// and opening AI Polish settings only loads cached rows.
  @Test("a persisted RETIRED model id is swept at launch")
  func launchSweepsRetiredModel() {
    let settings = freshSettings { suite in
      suite.set("gemini", forKey: "llmProvider")
      suite.set("gemini-2.0-flash", forKey: "llmModel")
    }

    #expect(settings.llmModel == LLMProvider.defaultModel(for: .gemini))
  }

  /// The direction that protects user choice. This sweep rewrites a persisted
  /// setting, so it must touch ONLY ids the provider actually withdrew — a
  /// predicate that caught legitimate models would silently override what the
  /// user picked, which is far worse than the bug it fixes.
  @Test("a persisted LIVE model id is NOT swept")
  func launchPreservesLiveModel() {
    for live in ["gemini-3.6-flash", "gemini-2.5-pro", "gemini-3.1-flash-lite"] {
      let settings = freshSettings { suite in
        suite.set("gemini", forKey: "llmProvider")
        suite.set(live, forKey: "llmModel")
      }
      #expect(settings.llmModel == live, "\(live) is live and must survive the sweep untouched")
    }
  }

  /// The sweep runs during initialization, and this file persists
  /// initialization-time values by write-through rather than relying on the
  /// `didSet` observer. Without that, the repair would be forgotten on quit.
  @Test("the swept value survives a reload")
  func sweptValuePersistsAcrossReload() {
    let suiteName = "ew-tests-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.set("gemini", forKey: "llmProvider")
    suite.set("gemini-2.0-flash", forKey: "llmModel")

    _ = SettingsManager(defaults: suite)
    let reloaded = SettingsManager(defaults: suite)

    #expect(reloaded.llmModel == LLMProvider.defaultModel(for: .gemini))
    suite.removePersistentDomain(forName: suiteName)
  }

  @Test("turning polish off preserves the selected model (#158 Codex r5 P1 claim, verified false)")
  func polishOffPreservesSelectedModel() {
    let settings = freshSettings()
    settings.llmProvider = .claude
    settings.llmModel = "claude-opus-4-8"

    // `.none` is the "polish off" state (#1285). `modelIDLooksLikeCloudProvider`
    // returns true for `.none` specifically so this arm's sweep condition
    // never fires for it -- a real cloud model must survive polish being
    // turned off, or turning it back on would silently lose the user's pick.
    settings.llmProvider = .none

    #expect(settings.llmModel == "claude-opus-4-8")
  }

  @Test("a model id that already belongs to the currently selected cloud provider is left alone")
  func ownProviderModelSurvivesCanonicalization() {
    let settings = freshSettings()
    settings.llmProvider = .claude
    settings.llmModel = "claude-opus-4-8"

    // Re-selecting the SAME provider (the didSet still fires, still
    // re-canonicalizes) must not disturb a model id that already belongs
    // to it -- this is a user's real, deliberately picked non-default
    // model, not a stale foreign one the sweep should touch.
    settings.llmProvider = .claude

    #expect(settings.llmModel == "claude-opus-4-8")
  }
}
