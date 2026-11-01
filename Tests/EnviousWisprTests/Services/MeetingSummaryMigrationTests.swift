import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4287: meeting summaries get their own engine, mapped once from dictation's polish
/// engine (founder decisions 13-15) and independent of it afterwards.
///
/// When these fail, the user sees their meeting summaries stop, switch to an engine they
/// never chose, or change whenever they change their dictation engine.
@MainActor
@Suite("Meeting summary engine migration (#4287)", .tags(.productOutcome))
struct MeetingSummaryMigrationTests {
  private static func suite() -> UserDefaults {
    TestDefaults.suite("ew.tests.4287.migration.\(UUID().uuidString)")!
  }

  /// A store that looks like an existing user who finished onboarding.
  private static func onboardedStore(
    dictation: String?, llmModel: String? = nil, ollamaModel: String? = nil
  ) -> UserDefaults {
    let store = suite()
    store.set("completed", forKey: "onboardingState")
    if let dictation { store.set(dictation, forKey: "llmProvider") }
    if let llmModel { store.set(llmModel, forKey: "llmModel") }
    if let ollamaModel { store.set(ollamaModel, forKey: "ollamaModel") }
    return store
  }

  struct Mapping: Sendable, CustomTestStringConvertible {
    let stored: String
    let expected: LLMProvider
    var testDescription: String { "\(stored) -> \(expected.rawValue)" }
  }

  /// Independent literal oracle, one row per shipped `LLMProvider` raw value.
  nonisolated static let mappings: [Mapping] = [
    Mapping(stored: "appleIntelligence", expected: .appleIntelligence),
    Mapping(stored: "egOne", expected: .egOne),
    Mapping(stored: "ollama", expected: .ollama),
    Mapping(stored: "openAI", expected: .openAI),
    Mapping(stored: "gemini", expected: .gemini),
    Mapping(stored: "claude", expected: .claude),
    Mapping(stored: "s1Mini", expected: .none),
    Mapping(stored: "none", expected: .none),
  ]

  @Test("every dictation provider maps to the settled summary provider", arguments: mappings)
  func mapsEveryProvider(_ row: Mapping) {
    let store = Self.onboardedStore(dictation: row.stored)
    let settings = SettingsManager(defaults: store)
    #expect(settings.meetingSummaryLLMProvider == row.expected)
    #expect(store.string(forKey: "meetingSummaryLLMProvider") == row.expected.rawValue)
    let reloaded = SettingsManager(defaults: store)
    #expect(reloaded.meetingSummaryLLMProvider == row.expected)
    if row.expected != .none {
      // A carried-over engine asks for the same model dictation was using.
      #expect(reloaded.meetingSummarySelection.model == reloaded.effectiveLLMModel)
    }
  }

  @Test("the mapping covers every LLMProvider case")
  func mappingCoversEveryCase() {
    #expect(Set(Self.mappings.map(\.stored)) == Set(LLMProvider.allCases.map(\.rawValue)))
  }

  @Test("a cloud user keeps provider and model, so the summary tuple is unchanged")
  func cloudKeepsModel() {
    let store = Self.onboardedStore(dictation: "openAI", llmModel: "gpt-4o")
    let settings = SettingsManager(defaults: store)
    #expect(settings.meetingSummarySelection.provider == .openAI)
    #expect(settings.meetingSummarySelection.model == "gpt-4o")
    let reloaded = SettingsManager(defaults: store)
    #expect(reloaded.meetingSummarySelection.provider == .openAI)
    #expect(reloaded.meetingSummarySelection.model == "gpt-4o")
    // Same (provider, model) as dictation's effective pair: the summary configuration
    // fingerprint, a pure function of that pair, does not change.
    #expect(settings.meetingSummarySelection.provider == settings.llmProvider)
    #expect(settings.meetingSummarySelection.model == settings.effectiveLLMModel)
  }

  @Test("an Ollama user keeps provider and model, including an EG-1 Ollama model")
  func ollamaKeepsModelEvenFirstParty() {
    for model in ["llama3.2:3b", "eg-1:q5", "hf.co/superwhisper/s1-mini-GGUF:Q4_K_M"] {
      let store = Self.onboardedStore(dictation: "ollama", llmModel: model, ollamaModel: model)
      let settings = SettingsManager(defaults: store)
      #expect(settings.meetingSummarySelection.provider == .ollama)
      #expect(settings.meetingSummarySelection.model == model)
      #expect(settings.meetingSummarySelection.model == settings.effectiveLLMModel)
      let reloaded = SettingsManager(defaults: store)
      #expect(reloaded.meetingSummarySelection.provider == .ollama)
      #expect(reloaded.meetingSummarySelection.model == model)
    }
  }

  @Test("an absent dictation value maps like the shipped default (Apple Intelligence)")
  func absentDictationUsesShippedDefault() {
    let settings = SettingsManager(defaults: Self.onboardedStore(dictation: nil))
    #expect(settings.meetingSummaryLLMProvider == .appleIntelligence)
  }

  @Test("a malformed (non-string) stored dictation value maps to no summary engine")
  func malformedDictationMapsToNone() {
    let store = Self.onboardedStore(dictation: nil)
    store.set([1, 2], forKey: "llmProvider")
    let settings = SettingsManager(defaults: store)
    #expect(settings.meetingSummaryLLMProvider == LLMProvider.none)
  }

  @Test("an unknown dictation value maps to no summary engine")
  func unknownDictationMapsToNone() {
    let store = Self.onboardedStore(dictation: "futureProvider")
    let settings = SettingsManager(defaults: store)
    #expect(settings.meetingSummaryLLMProvider == LLMProvider.none)
    #expect(settings.meetingSummarySelection.provider == .none)
    #expect(SettingsManager(defaults: store).meetingSummaryLLMProvider == LLMProvider.none)
  }

  @Test("before onboarding completes nothing migrates; completing onboarding maps it")
  func defersUntilOnboardingCompletes() {
    let store = Self.suite()
    store.set("openAI", forKey: "llmProvider")
    let settings = SettingsManager(defaults: store)
    #expect(settings.meetingSummaryLLMProvider == nil)
    #expect(store.object(forKey: "meetingSummaryLLMProvider") == nil)
    #expect(settings.meetingSummarySelection.provider == .none)
    settings.llmProvider = .gemini
    settings.onboardingState = .completed
    #expect(settings.meetingSummaryLLMProvider == .gemini)
  }

  @Test("a restarted onboarding still migrates for a user who completed it before")
  func everCompletedMigratesDuringRestart() {
    let store = Self.suite()
    store.set("needsMicPermission", forKey: "onboardingState")
    store.set(true, forKey: "ew.onboarding.everCompleted")
    store.set("claude", forKey: "llmProvider")
    let settings = SettingsManager(defaults: store)
    #expect(settings.meetingSummaryLLMProvider == .claude)
  }

  @Test("a stored summary choice is never overwritten, including one this build cannot read")
  func neverOverwritesStoredChoice() {
    let explicit = Self.onboardedStore(dictation: "openAI")
    explicit.set("none", forKey: "meetingSummaryLLMProvider")
    #expect(SettingsManager(defaults: explicit).meetingSummaryLLMProvider == LLMProvider.none)

    let unreadable = Self.onboardedStore(dictation: "openAI")
    unreadable.set("futureProvider", forKey: "meetingSummaryLLMProvider")
    let settings = SettingsManager(defaults: unreadable)
    #expect(settings.meetingSummaryLLMProvider == nil)
    #expect(settings.meetingSummarySelection.provider == .none)
    #expect(unreadable.string(forKey: "meetingSummaryLLMProvider") == "futureProvider")
  }

  @Test("an interrupted migration (models written, provider not) repeats the same mapping")
  func interruptedMigrationRepeats() {
    let store = Self.onboardedStore(
      dictation: "gemini", llmModel: "gemini-2.5-flash", ollamaModel: "llama3.2:3b")
    store.set("stale-model", forKey: "meetingSummaryLLMModel")
    store.set("stale-ollama", forKey: "meetingSummaryOllamaModel")
    let settings = SettingsManager(defaults: store)
    #expect(settings.meetingSummarySelection.provider == .gemini)
    #expect(settings.meetingSummarySelection.model == "gemini-2.5-flash")
    #expect(settings.meetingSummaryOllamaModel == "llama3.2:3b")
    let reloaded = SettingsManager(defaults: store)
    #expect(reloaded.meetingSummarySelection.provider == .gemini)
    #expect(reloaded.meetingSummarySelection.model == "gemini-2.5-flash")
    #expect(reloaded.meetingSummaryOllamaModel == "llama3.2:3b")
  }

  @Test("after migration the summary engine survives reload and ignores dictation changes")
  func independentAndIdempotent() {
    let store = Self.onboardedStore(dictation: "openAI", llmModel: "gpt-4o")
    let first = SettingsManager(defaults: store)
    first.llmProvider = .appleIntelligence
    #expect(first.meetingSummarySelection.provider == .openAI)
    let reloaded = SettingsManager(defaults: store)
    #expect(reloaded.meetingSummarySelection.provider == .openAI)
    #expect(reloaded.meetingSummarySelection.model == "gpt-4o")
    #expect(reloaded.llmProvider == .appleIntelligence)
  }

  @Test("a summary provider change sweeps another provider's model id from the cloud field")
  func normalizesOnProviderChange() {
    let settings = SettingsManager(defaults: Self.onboardedStore(dictation: "egOne"))
    settings.meetingSummaryLLMProvider = .openAI
    #expect(settings.meetingSummaryLLMModel != LLMProvider.egOneModelName)
    #expect(settings.meetingSummarySelection.model == LLMProvider.defaultModel(for: .openAI))
  }

  @Test("the summary revision counts every summary provider change and nothing else")
  func revisionTracksOnlySummaryChanges() {
    let settings = SettingsManager(defaults: Self.onboardedStore(dictation: "openAI"))
    let start = settings.meetingSummaryProviderSelectionRevision
    settings.meetingSummaryLLMProvider = .claude
    settings.meetingSummaryLLMProvider = .openAI
    #expect(settings.meetingSummaryProviderSelectionRevision == start + 2)
    settings.meetingSummaryLLMProvider = .openAI
    settings.llmProvider = .gemini
    #expect(settings.meetingSummaryProviderSelectionRevision == start + 2)
  }
}
