import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #2772 chunk 3 — the model repair that runs when a provider's catalog comes back.
///
/// Chunk 2 deliberately left the import out of it, because the policy was welded to
/// dictation's stored properties and the obvious workaround (swap the import's fields in,
/// run, swap back) fires `llmProvider`'s `didSet`, reporting a dictation provider change
/// that never happened. Chunk 3 lifted the policy over a value triple, so both surfaces run
/// one decision over their own fields. These rows hold both halves.
@MainActor
@Suite("File-import discovery repair (#2772)", .tags(.productOutcome))
struct FileImportDiscoveryRepairTests {
  private static func freshSettings() -> SettingsManager {
    let suite = "ew.tests.2772.repair.\(UUID().uuidString)"
    return SettingsManager(defaults: UserDefaults(suiteName: suite)!)
  }

  private static func row(
    _ id: String, provider: LLMProvider, available: Bool = true, remote: Bool = false
  ) -> LLMModelInfo {
    LLMModelInfo(
      id: id, displayName: id, provider: provider, isAvailable: available, isRemote: remote)
  }

  /// The point of the whole lift: a catalog fetched for the import's provider repairs the
  /// import's model and leaves dictation's alone. Before this, one pair of fields took every
  /// result, so an import-side refresh rewrote the model dictation was about to use.
  @Test("an import catalog repairs the import's model and never dictation's")
  func importDiscoveryLeavesDictationAlone() {
    let settings = Self.freshSettings()
    settings.llmProvider = .gemini
    settings.llmModel = "gemini-3-flash"
    settings.seedFileImportPolishModelsIfNeeded()
    settings.fileImportLLMProvider = .some(.openAI)
    settings.fileImportLLMModel = "gpt-4o-retired"

    settings.applyDiscoveredModelsForFileImport(
      [Self.row("gpt-5.2", provider: .openAI)], for: .openAI)

    #expect(settings.fileImportLLMModel == "gpt-5.2", "the import's stale id was not repaired")
    #expect(settings.llmModel == "gemini-3-flash", "dictation's model was rewritten")
    #expect(settings.llmProvider == .gemini, "dictation's provider was rewritten")
  }

  /// A follower has no fields of its own: its provider and model ARE dictation's. Giving it
  /// a private copy would leave the import running whatever was seeded at the moment of the
  /// fetch while the screen showed dictation's live pick.
  @Test("a follower's discovery repairs dictation's fields, because those are its fields")
  func aFollowerIsRoutedToDictation() {
    let settings = Self.freshSettings()
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-4o-retired"
    #expect(settings.fileImportLLMProvider == nil, "this test is about a follower")

    settings.applyDiscoveredModelsForFileImport(
      [Self.row("gpt-5.2", provider: .openAI)], for: .openAI)

    #expect(settings.llmModel == "gpt-5.2")
    #expect(settings.effectiveFileImportLLMModel == "gpt-5.2")
    #expect(settings.fileImportLLMProvider == nil, "a repair must not create an override")
  }

  /// A result for a provider the import is not on is stale, exactly as it is for dictation.
  @Test("a catalog for another provider is dropped")
  func staleResultsAreDropped() {
    let settings = Self.freshSettings()
    settings.llmProvider = .gemini
    settings.seedFileImportPolishModelsIfNeeded()
    settings.fileImportLLMProvider = .some(.openAI)
    settings.fileImportLLMModel = "gpt-5.2"

    settings.applyDiscoveredModelsForFileImport(
      [Self.row("claude-haiku-4-5", provider: .claude)], for: .claude)

    #expect(settings.fileImportLLMModel == "gpt-5.2")
  }

  /// #1914's founder decision, over the import's fields. Every available model is hosted, so
  /// arm nothing rather than pick one on the user's behalf. Both fields, because the runtime
  /// reads the Ollama one.
  @Test("an all-hosted Ollama catalog arms nothing for the import")
  func allHostedArmsNothingForTheImport() {
    let settings = Self.freshSettings()
    settings.llmProvider = .egOne
    settings.seedFileImportPolishModelsIfNeeded()
    settings.fileImportLLMProvider = .some(.ollama)
    settings.fileImportOllamaModel = "qwen2.5:3b"

    settings.applyDiscoveredModelsForFileImport(
      [Self.row("deepseek-v4-flash:latest", provider: .ollama, remote: true)], for: .ollama)

    #expect(settings.fileImportOllamaModel == "")
    #expect(settings.fileImportLLMModel == "")
    #expect(settings.effectiveFileImportLLMModel == "", "the runtime is still armed")
  }

  /// The remembered Ollama name survives an EMPTY catalog, because nothing being installed
  /// is not evidence the user's pick is wrong. Same rule dictation has carried since #1305.
  @Test("an empty Ollama catalog keeps the import's remembered name")
  func anEmptyCatalogKeepsTheRememberedName() {
    let settings = Self.freshSettings()
    settings.llmProvider = .egOne
    settings.seedFileImportPolishModelsIfNeeded()
    settings.fileImportLLMProvider = .some(.ollama)
    settings.fileImportOllamaModel = "qwen2.5:3b"

    settings.applyDiscoveredModelsForFileImport([], for: .ollama)

    #expect(settings.fileImportOllamaModel == "qwen2.5:3b")
    #expect(settings.fileImportLLMModel == "", "the picker field must read as nothing armed")
  }

  /// An armed, available model is the user's selection and it stands. The `:latest` spelling
  /// is the case an exact compare gets wrong: the user stored one form and the daemon
  /// reports the other, and repairing there would replace a model that works.
  @Test("an armed Ollama model survives, and syncs to the spelling the daemon reported")
  func anArmedModelSurvivesACanonicalMatch() {
    let settings = Self.freshSettings()
    settings.llmProvider = .egOne
    settings.seedFileImportPolishModelsIfNeeded()
    settings.fileImportLLMProvider = .some(.ollama)
    settings.fileImportOllamaModel = "llama3.2"

    settings.applyDiscoveredModelsForFileImport(
      [
        Self.row("llama3.2:latest", provider: .ollama),
        Self.row("qwen2.5:3b", provider: .ollama),
      ], for: .ollama)

    #expect(settings.fileImportOllamaModel == "llama3.2:latest")
    #expect(settings.fileImportLLMModel == "llama3.2:latest")
  }

  /// The lift must not have changed what dictation does. Taken through the dictation entry
  /// point, against the same catalogs as above.
  ///
  /// **Not one row per branch, and saying so matters.** The branch-by-branch comparison
  /// against the pre-lift body was done by reading, in the chunk 3 review; this covers the
  /// stale cloud id, the all-hosted refusal, the empty catalog, an armed cloud model that
  /// must survive, the default-family preference, and a stale provider. It does not reach
  /// the dated-snapshot suffix rule, which `SettingsManagerTests` already owns.
  @Test("dictation's own repair is unchanged by the lift")
  func dictationBehaviourIsUnchanged() {
    let stale = Self.freshSettings()
    stale.llmProvider = .openAI
    stale.llmModel = "gpt-4o-retired"
    stale.applyDiscoveredModels([Self.row("gpt-5.2", provider: .openAI)], for: .openAI)
    #expect(stale.llmModel == "gpt-5.2")

    let hosted = Self.freshSettings()
    hosted.llmProvider = .ollama
    hosted.ollamaModel = "qwen2.5:3b"
    hosted.applyDiscoveredModels(
      [Self.row("deepseek-v4-flash:latest", provider: .ollama, remote: true)], for: .ollama)
    #expect(hosted.ollamaModel == "" && hosted.llmModel == "")

    let empty = Self.freshSettings()
    empty.llmProvider = .ollama
    empty.ollamaModel = "qwen2.5:3b"
    empty.applyDiscoveredModels([], for: .ollama)
    #expect(empty.ollamaModel == "qwen2.5:3b", "an empty catalog must not clear the memory")
    #expect(empty.llmModel == "")

    let wrongProvider = Self.freshSettings()
    wrongProvider.llmProvider = .gemini
    wrongProvider.llmModel = "gemini-3-flash"
    wrongProvider.applyDiscoveredModels(
      [Self.row("gpt-5.2", provider: .openAI)], for: .openAI)
    #expect(wrongProvider.llmModel == "gemini-3-flash")

    // An armed, available CLOUD model is the user's selection and it stands.
    let armed = Self.freshSettings()
    armed.llmProvider = .openAI
    armed.llmModel = "gpt-5.2"
    armed.applyDiscoveredModels(
      [Self.row("gpt-5.1", provider: .openAI), Self.row("gpt-5.2", provider: .openAI)],
      for: .openAI)
    #expect(armed.llmModel == "gpt-5.2", "a working selection was repaired away")

    // With nothing armed, the provider's own default family wins over whatever sorts first.
    let fresh = Self.freshSettings()
    fresh.llmProvider = .claude
    fresh.llmModel = "claude-retired-1"
    fresh.applyDiscoveredModels(
      [
        Self.row("claude-fable-5-1", provider: .claude),
        Self.row("claude-haiku-4-5", provider: .claude),
      ], for: .claude)
    #expect(
      fresh.llmModel == "claude-haiku-4-5",
      "the default family lost to whatever sorted first")
  }

  /// Switching to Ollama after a cloud provider left the cloud provider's id in the model
  /// field, and the settings sync mirrored it over the armed Ollama model. Found by the
  /// cloud review of PR #2786. One policy for both surfaces, so one test.
  @Test("switching to Ollama sweeps a leftover model id instead of letting it mirror")
  func aLeftoverIdIsSweptWhenSwitchingToOllama() {
    // The previous provider's id: swept, so the mirror sees empty and `llama3` survives.
    #expect(
      SettingsManager.normalizedModel(for: .ollama, cloudModel: "gpt-5", ollamaModel: "llama3")
        == "")
    // An Ollama name discovery has since replaced: also a leftover.
    #expect(
      SettingsManager.normalizedModel(for: .ollama, cloudModel: "llama2", ollamaModel: "llama3")
        == "")
    // In agreement with the armed model: kept.
    #expect(
      SettingsManager.normalizedModel(for: .ollama, cloudModel: "llama3", ollamaModel: "llama3")
        == "llama3")
    // #1305 stands: empty stays empty, never refilled from the armed model.
    #expect(
      SettingsManager.normalizedModel(for: .ollama, cloudModel: "", ollamaModel: "llama3") == "")
  }
}
