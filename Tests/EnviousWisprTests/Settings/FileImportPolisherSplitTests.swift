import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #2772 chunk 2 — the file-import polisher is a SEPARATE choice from dictation's.
///
/// The founder found the defect in UAT: picking a cleanup engine for one import silently
/// changed the engine every later DICTATION used, because the wizard wrote
/// `settings.llmProvider`. These rows pin the split that replaced it.
@MainActor
@Suite("File-import polisher split (#2772)", .tags(.productOutcome))
struct FileImportPolisherSplitTests {
  /// A settings store nobody else is writing to, so a row cannot pass or fail on another
  /// suite's leftovers.
  private static func freshSettings() -> SettingsManager {
    let suite = "ew.tests.2772.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return SettingsManager(defaults: defaults)
  }

  @Test("a user who never chose follows dictation, provider and model together")
  func neverChosenFollowsDictation() {
    let settings = Self.freshSettings()
    settings.llmProvider = .gemini
    settings.llmModel = "gemini-3-flash"

    #expect(settings.fileImportLLMProvider == nil, "opening nothing must store nothing")
    #expect(settings.effectiveFileImportLLMProvider == .gemini)
    #expect(settings.effectiveFileImportLLMModel == "gemini-3-flash")

    // Following means following: a later dictation change carries through.
    settings.llmProvider = .claude
    #expect(settings.effectiveFileImportLLMProvider == .claude)
  }

  /// The founder's own example, in one row.
  @Test("Gemini for dictation and OpenAI for imports, at the same time")
  func theTwoSurfacesHoldDifferentEngines() {
    let settings = Self.freshSettings()
    settings.llmProvider = .gemini
    settings.seedFileImportPolishModelsIfNeeded()
    settings.fileImportLLMProvider = .some(.openAI)

    #expect(settings.llmProvider == .gemini, "the import pick must not touch dictation")
    #expect(settings.effectiveFileImportLLMProvider == .openAI)
  }

  /// Choosing the same engine on purpose is still choosing. Were it not recorded, the
  /// next dictation change would silently drag the import along with it.
  @Test("picking dictation's own engine still creates an override")
  func pickingTheSameEngineIsStillAChoice() {
    let settings = Self.freshSettings()
    settings.llmProvider = .gemini
    settings.seedFileImportPolishModelsIfNeeded()
    settings.fileImportLLMProvider = .some(.gemini)

    settings.llmProvider = .claude
    #expect(
      settings.effectiveFileImportLLMProvider == .gemini,
      "an explicit pick must not resume following on the next dictation change")
  }

  /// The third state. `LLMProvider` has its own `.none` case, so one optional carries
  /// never-chose, explicitly-off, and a real provider. Flattening off into never-chose
  /// would make a later dictation change silently switch imports back on.
  @Test("polish off for imports is not the same as never having chosen")
  func polishOffIsNotFollowing() {
    let settings = Self.freshSettings()
    settings.llmProvider = .gemini
    settings.fileImportLLMProvider = .some(LLMProvider.none)

    #expect(settings.effectiveFileImportLLMProvider == LLMProvider.none)
    settings.llmProvider = .claude
    #expect(
      settings.effectiveFileImportLLMProvider == LLMProvider.none,
      "an explicit off must not follow dictation back on")
  }

  @Test("there is a way back to following dictation")
  func followingCanBeRestored() {
    let settings = Self.freshSettings()
    settings.llmProvider = .gemini
    settings.seedFileImportPolishModelsIfNeeded()
    settings.fileImportLLMProvider = .some(.openAI)
    settings.followDictationForFileImportPolish()

    #expect(settings.fileImportLLMProvider == nil)
    #expect(settings.effectiveFileImportLLMProvider == .gemini)
  }

  /// #2772 §3.3 — the shipped defect. For Ollama the ARMED model is `ollamaModel`;
  /// `llmModel` can still hold another provider's id after a visit away and back
  /// (`applyDiscoveredModels`, #1305/#1914). The import path froze the raw field, so an
  /// Ollama import could be configured with a cloud model name.
  @Test("an Ollama import resolves the Ollama model, never a stale cloud id")
  func ollamaImportResolvesTheArmedModel() {
    let settings = Self.freshSettings()
    settings.llmProvider = .ollama
    settings.ollamaModel = "qwen3:8b"
    // The state the code's own comment describes: a leftover from another provider.
    settings.llmModel = "gpt-4o-mini"

    #expect(
      settings.effectiveFileImportLLMModel == "qwen3:8b",
      "the import must use the armed Ollama model, not the leftover cloud id")
  }

  /// Seeding exists so that changing only the PROVIDER does not silently change the model
  /// out from under a user who was looking at dictation's.
  @Test("becoming an overrider seeds the models the user was already seeing")
  func seedingCarriesTheVisibleModels() {
    let settings = Self.freshSettings()
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-5-mini"
    settings.ollamaModel = "qwen3:8b"

    settings.seedFileImportPolishModelsIfNeeded()
    settings.fileImportLLMProvider = .some(.openAI)
    #expect(settings.effectiveFileImportLLMModel == "gpt-5-mini")

    // A second call must not overwrite the user's own later edits.
    settings.fileImportLLMModel = "gpt-5-nano"
    settings.seedFileImportPolishModelsIfNeeded()
    #expect(settings.effectiveFileImportLLMModel == "gpt-5-nano")
  }

  /// #2772 chunk-2 review, blocking finding 1. Seeding copies DICTATION's model; picking a
  /// different provider immediately after would otherwise leave the new provider holding
  /// the old one's model id. This is the founder's own example, and it failed before the
  /// shared normalisation landed.
  @Test("switching the import provider sweeps the previous provider's model id")
  func switchingImportProviderNormalisesTheModel() {
    let settings = Self.freshSettings()
    settings.llmProvider = .gemini
    settings.llmModel = "gemini-3-flash"
    settings.seedFileImportPolishModelsIfNeeded()

    settings.fileImportLLMProvider = .openAI
    let resolved = settings.effectiveFileImportLLMModel
    #expect(
      resolved != "gemini-3-flash",
      "an OpenAI import must not carry a Gemini model id")
    #expect(
      LLMProvider.modelIDLooksLikeCloudProvider(resolved, .openAI),
      "the swept value must be a real OpenAI id, got \(resolved)")
  }

  /// A fixed-literal engine's id must not leak into a cloud provider either — the #1271
  /// class, now reachable through the import fields as well.
  @Test("a bundled engine's literal never leaks into an import cloud provider")
  func bundledLiteralDoesNotLeak() {
    let settings = Self.freshSettings()
    settings.llmProvider = .egOne
    settings.seedFileImportPolishModelsIfNeeded()
    settings.fileImportLLMProvider = .egOne
    #expect(settings.effectiveFileImportLLMModel == LLMProvider.egOneModelName)

    settings.fileImportLLMProvider = .claude
    #expect(
      settings.effectiveFileImportLLMModel != LLMProvider.egOneModelName,
      "eg-1's literal must not become Claude's model name")
  }

  /// The choice has to survive a relaunch, or the split is a session-only illusion.
  @Test("the import choice survives a reload")
  func theChoiceIsPersisted() {
    let suite = "ew.tests.2772.persist.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let first = SettingsManager(defaults: defaults)
    first.llmProvider = .gemini
    first.seedFileImportPolishModelsIfNeeded()
    first.fileImportLLMProvider = .openAI

    let reloaded = SettingsManager(defaults: defaults)
    #expect(reloaded.fileImportLLMProvider == .openAI)
    #expect(reloaded.effectiveFileImportLLMProvider == .openAI)

    reloaded.followDictationForFileImportPolish()
    let afterFollow = SettingsManager(defaults: defaults)
    #expect(afterFollow.fileImportLLMProvider == nil, "following must survive a reload too")
  }
}
