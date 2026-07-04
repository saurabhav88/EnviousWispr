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
}
