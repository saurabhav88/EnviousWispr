import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3765 PR-C: what the AI Polish screen writes when a person picks a provider or a model,
/// on dictation's screen and on Transcribe a File's, which the dev control door now calls
/// too.
///
/// When this fails, the user sees Transcribe a File start or stop following dictation's
/// polish on its own, a provider pick that changes the model too, or a dictation choice
/// changed by the import screen.
@MainActor
@Suite(.tags(.productOutcome))
struct PolishSettingsTests {
  private static func settings() -> SettingsManager {
    let s = SettingsManager(
      defaults: TestDefaults.suite("ew.tests.3765.polish.\(UUID().uuidString)")!)
    s.llmProvider = .openAI
    s.llmModel = "gpt-dictation"
    s.ollamaModel = "llama-dictation"
    return s
  }

  @Test("reads follow dictation until the import has its own choice")
  func readsFollowDictation() {
    let s = Self.settings()
    #expect(PolishSettings.provider(on: .fileImport, in: s) == .openAI)
    #expect(PolishSettings.cloudModel(on: .fileImport, in: s) == "gpt-dictation")
    #expect(PolishSettings.ollamaModel(on: .fileImport, in: s) == "llama-dictation")
    s.fileImportLLMProvider = .gemini
    s.fileImportLLMModel = "gemini-import"
    s.fileImportOllamaModel = "llama-import"
    #expect(PolishSettings.provider(on: .fileImport, in: s) == .gemini)
    #expect(PolishSettings.cloudModel(on: .fileImport, in: s) == "gemini-import")
    #expect(PolishSettings.ollamaModel(on: .fileImport, in: s) == "llama-import")
    #expect(PolishSettings.provider(on: .dictation, in: s) == .openAI)
    #expect(PolishSettings.cloudModel(on: .dictation, in: s) == "gpt-dictation")
    #expect(PolishSettings.ollamaModel(on: .dictation, in: s) == "llama-dictation")
  }

  @Test("a dictation provider or model pick writes dictation's fields only")
  func dictationWrites() {
    let s = Self.settings()
    PolishSettings.setProvider(.gemini, on: .dictation, in: s)
    #expect(s.llmProvider == .gemini)
    PolishSettings.setCloudModel("gemini-x", on: .dictation, in: s)
    #expect(s.llmModel == "gemini-x")
    #expect(s.fileImportLLMProvider == nil, "the import keeps following")
  }

  @Test(
    "the first import provider pick seeds dictation's models, then overrides, even for the same provider"
  )
  func importProviderPickSeedsAndOverrides() {
    let s = Self.settings()
    PolishSettings.setProvider(.openAI, on: .fileImport, in: s)
    #expect(s.fileImportLLMProvider == .openAI, "picking dictation's own engine is still a pick")
    #expect(s.fileImportLLMModel == "gpt-dictation")
    #expect(s.fileImportOllamaModel == "llama-dictation")
    #expect(s.llmProvider == .openAI && s.llmModel == "gpt-dictation")
  }

  @Test("the first import model edit while following overrides with dictation's provider")
  func importModelEditOverrides() {
    let s = Self.settings()
    PolishSettings.setCloudModel("gpt-import", on: .fileImport, in: s)
    #expect(s.fileImportLLMProvider == .openAI)
    #expect(s.fileImportLLMModel == "gpt-import")
    #expect(s.fileImportOllamaModel == "llama-dictation")
    #expect(s.llmModel == "gpt-dictation", "dictation's model unchanged")
  }

  @Test("an existing override is never reseeded from dictation")
  func overrideIsNotReseeded() {
    let s = Self.settings()
    PolishSettings.setProvider(.openAI, on: .fileImport, in: s)
    s.fileImportOllamaModel = "llama-mine"
    s.llmModel = "gpt-dictation-2"
    PolishSettings.setCloudModel("gpt-import", on: .fileImport, in: s)
    #expect(s.fileImportLLMModel == "gpt-import")
    #expect(s.fileImportOllamaModel == "llama-mine")
    PolishSettings.setProvider(.gemini, on: .fileImport, in: s)
    #expect(s.fileImportLLMProvider == .gemini)
    #expect(s.fileImportOllamaModel == "llama-mine")
  }

  @Test("an import pick of polish off is an override, distinct from following")
  func importOffIsAnOverride() {
    let s = Self.settings()
    PolishSettings.setProvider(LLMProvider.none, on: .fileImport, in: s)
    #expect(s.fileImportLLMProvider == LLMProvider.none)
    #expect(PolishSettings.provider(on: .fileImport, in: s) == LLMProvider.none)
    s.followDictationForFileImportPolish()
    #expect(s.fileImportLLMProvider == nil)
    #expect(PolishSettings.provider(on: .fileImport, in: s) == .openAI)
  }
}
