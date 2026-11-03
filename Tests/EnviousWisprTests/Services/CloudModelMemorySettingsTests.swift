import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4353 D1: Dictation, Transcribe a File and meeting summaries each remember their own cloud
/// model per provider, so switching provider and back gives the user their own pick, and model
/// discovery never replaces a remembered pick.
@MainActor
@Suite("Cloud model memory in settings (#4353)", .tags(.productOutcome))
struct CloudModelMemorySettingsTests {

  private static func freshDefaults() -> UserDefaults {
    let name = "SM-4353-\(UUID().uuidString)"
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private static func row(_ id: String, available: Bool = true) -> LLMModelInfo {
    LLMModelInfo(
      id: id, displayName: id, provider: .openAI, isAvailable: available, isRemote: false)
  }

  // MARK: - Round trips

  @Test("dictation: OpenAI to Claude and back keeps each pick")
  func dictationRoundTrip() {
    let settings = SettingsManager(defaults: Self.freshDefaults())
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-6-luna"
    settings.llmProvider = .claude
    settings.llmModel = "claude-haiku-5-5"
    settings.llmProvider = .openAI
    #expect(settings.llmModel == "gpt-6-luna")
    settings.llmProvider = .claude
    #expect(settings.llmModel == "claude-haiku-5-5")
  }

  @Test("Transcribe a File: its own picks survive a round trip and never touch dictation")
  func importRoundTripIsIsolated() {
    let settings = SettingsManager(defaults: Self.freshDefaults())
    settings.llmProvider = .gemini
    settings.llmModel = "gemini-4-argon"
    settings.seedFileImportPolishModelsIfNeeded(for: .openAI)
    settings.fileImportLLMProvider = .openAI
    settings.fileImportLLMModel = "gpt-6-luna"
    settings.fileImportLLMProvider = .claude
    settings.fileImportLLMModel = "claude-haiku-5-5"
    settings.fileImportLLMProvider = .openAI
    #expect(settings.fileImportLLMModel == "gpt-6-luna")
    settings.fileImportLLMProvider = .claude
    #expect(settings.fileImportLLMModel == "claude-haiku-5-5")
    #expect(settings.llmModel == "gemini-4-argon")
    #expect(settings.dictationCloudModelMemory.model(for: .openAI) == nil)
    #expect(settings.dictationCloudModelMemory.model(for: .claude) == nil)
  }

  @Test("meeting summaries: their own picks survive a round trip and never touch dictation")
  func summaryRoundTripIsIsolated() {
    let settings = SettingsManager(defaults: Self.freshDefaults())
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-4o-mini"
    settings.meetingSummaryLLMProvider = .openAI
    settings.meetingSummaryLLMModel = "gpt-6.1-terra"
    settings.meetingSummaryLLMProvider = .claude
    settings.meetingSummaryLLMModel = "claude-fable-5"
    settings.meetingSummaryLLMProvider = .openAI
    #expect(settings.meetingSummaryLLMModel == "gpt-6.1-terra")
    settings.meetingSummaryLLMProvider = .claude
    #expect(settings.meetingSummaryLLMModel == "claude-fable-5")
    #expect(settings.llmModel == "gpt-4o-mini")
    #expect(settings.dictationCloudModelMemory.model(for: .claude) == nil)
  }

  @Test(
    "a trip through an Ollama model with a cloud-shaped name gives back the cloud pick",
    arguments: Surface.allCases)
  func ollamaTripWithCloudShapedName(surface: Surface) {
    let settings = SettingsManager(defaults: Self.freshDefaults())
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-6-luna"
    switch surface {
    case .dictation:
      settings.llmProvider = .ollama
      settings.ollamaModel = "gpt-oss:20b"
      settings.llmModel = "gpt-oss:20b"
      settings.llmProvider = .openAI
      #expect(settings.llmModel == "gpt-6-luna")
      #expect(settings.dictationCloudModelMemory.model(for: .openAI) == "gpt-6-luna")
    case .fileImport:
      settings.seedFileImportPolishModelsIfNeeded(for: .openAI)
      settings.fileImportLLMProvider = .openAI
      settings.fileImportLLMProvider = .ollama
      settings.fileImportOllamaModel = "gpt-oss:20b"
      settings.fileImportLLMModel = "gpt-oss:20b"
      settings.fileImportLLMProvider = .openAI
      #expect(settings.fileImportLLMModel == "gpt-6-luna")
      #expect(settings.fileImportCloudModelMemory.model(for: .openAI) == "gpt-6-luna")
    case .meetingSummary:
      settings.meetingSummaryLLMProvider = .openAI
      settings.meetingSummaryLLMModel = "gpt-6-luna"
      settings.meetingSummaryLLMProvider = .ollama
      settings.meetingSummaryOllamaModel = "gpt-oss:20b"
      settings.meetingSummaryLLMModel = "gpt-oss:20b"
      settings.meetingSummaryLLMProvider = .openAI
      #expect(settings.meetingSummaryLLMModel == "gpt-6-luna")
      #expect(settings.meetingSummaryCloudModelMemory.model(for: .openAI) == "gpt-6-luna")
    }
  }

  enum LeftoverRoute: CaseIterable { case direct, throughPolishOff, importOverride, summary }

  @Test(
    "an Ollama model with a cloud-shaped name never becomes a first-visit cloud pick",
    arguments: LeftoverRoute.allCases)
  func leftoverNeverBecomesCloudPick(route: LeftoverRoute) {
    let leftover = "claude-local:7b"
    let settings = SettingsManager(defaults: Self.freshDefaults())
    let model: String
    let memory: CloudModelMemory
    switch route {
    case .direct, .throughPolishOff:
      settings.llmProvider = .ollama
      settings.ollamaModel = leftover
      settings.llmModel = leftover
      if route == .throughPolishOff { settings.llmProvider = .none }
      settings.llmProvider = .claude
      (model, memory) = (settings.llmModel, settings.dictationCloudModelMemory)
    case .importOverride:
      settings.llmProvider = .ollama
      settings.ollamaModel = leftover
      settings.llmModel = leftover
      settings.seedFileImportPolishModelsIfNeeded(for: .claude)
      settings.fileImportLLMProvider = .claude
      (model, memory) = (settings.fileImportLLMModel, settings.fileImportCloudModelMemory)
    case .summary:
      settings.meetingSummaryLLMProvider = .ollama
      settings.meetingSummaryOllamaModel = leftover
      settings.meetingSummaryLLMModel = leftover
      settings.meetingSummaryLLMProvider = .claude
      (model, memory) = (settings.meetingSummaryLLMModel, settings.meetingSummaryCloudModelMemory)
    }
    #expect(model != leftover)
    #expect(memory.model(for: .claude) != leftover)
  }

  @Test("a following import uses dictation's remembered pick and keeps no memory of its own")
  func followerUsesDictation() {
    let settings = SettingsManager(defaults: Self.freshDefaults())
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-6-luna"
    settings.llmProvider = .claude
    settings.llmProvider = .openAI
    #expect(settings.fileImportLLMProvider == nil)
    #expect(settings.effectiveFileImportLLMModel == "gpt-6-luna")
    #expect(settings.fileImportCloudModelMemory == CloudModelMemory())
  }

  // MARK: - Becoming an import override

  @Test("becoming an override copies only dictation's entry for the target provider")
  func overrideSeedsOnlyTarget() {
    let settings = SettingsManager(defaults: Self.freshDefaults())
    settings.llmProvider = .claude
    settings.llmModel = "claude-haiku-5-5"
    settings.llmProvider = .gemini
    settings.llmModel = "gemini-4-argon"
    settings.seedFileImportPolishModelsIfNeeded(for: .claude)
    settings.fileImportLLMProvider = .claude
    #expect(settings.fileImportLLMModel == "claude-haiku-5-5")
    #expect(settings.fileImportCloudModelMemory.model(for: .claude) == "claude-haiku-5-5")
    #expect(settings.fileImportCloudModelMemory.model(for: .gemini) == nil)
  }

  @Test("an earlier import pick wins over dictation's, even for dictation's own provider")
  func existingImportEntryWins() {
    let settings = SettingsManager(defaults: Self.freshDefaults())
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-4o-mini"
    settings.seedFileImportPolishModelsIfNeeded(for: .openAI)
    settings.fileImportLLMProvider = .openAI
    settings.fileImportLLMModel = "gpt-6-luna"
    settings.followDictationForFileImportPolish()

    settings.seedFileImportPolishModelsIfNeeded(for: .openAI)
    settings.fileImportLLMProvider = .openAI
    #expect(settings.fileImportLLMModel == "gpt-6-luna")
    #expect(settings.llmModel == "gpt-4o-mini")
  }

  // MARK: - Relaunch and migration

  @Test("the remembered picks survive a relaunch")
  func survivesRelaunch() {
    let defaults = Self.freshDefaults()
    let first = SettingsManager(defaults: defaults)
    first.llmProvider = .openAI
    first.llmModel = "gpt-6-luna"
    first.llmProvider = .claude
    first.llmModel = "claude-haiku-5-5"

    let reloaded = SettingsManager(defaults: defaults)
    #expect(reloaded.llmModel == "claude-haiku-5-5")
    reloaded.llmProvider = .openAI
    #expect(reloaded.llmModel == "gpt-6-luna")
  }

  @Test("an upgrade keeps a stored selection, retired and audio ids included")
  func upgradeKeepsStoredSelections() {
    let retired = Self.freshDefaults()
    retired.set("gemini", forKey: "llmProvider")
    retired.set("gemini-2.0-flash", forKey: "llmModel")
    let retiredSettings = SettingsManager(defaults: retired)
    #expect(retiredSettings.llmModel == "gemini-2.0-flash")
    #expect(retiredSettings.dictationCloudModelMemory.model(for: .gemini) == "gemini-2.0-flash")

    let audio = Self.freshDefaults()
    audio.set("openAI", forKey: "llmProvider")
    audio.set("gpt-4o-audio-preview", forKey: "llmModel")
    #expect(SettingsManager(defaults: audio).llmModel == "gpt-4o-audio-preview")
  }

  @Test("an upgrade never remembers another provider's id")
  func upgradeIgnoresForeignId() {
    let defaults = Self.freshDefaults()
    defaults.set("claude", forKey: "llmProvider")
    defaults.set("gpt-6-luna", forKey: "llmModel")
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.dictationCloudModelMemory.model(for: .openAI) == nil)
    #expect(settings.llmModel.hasPrefix("claude-"))
  }

  @Test("an upgrade with polish off keeps the pick under the engine the toggle restores")
  func upgradeWithPolishOff() {
    let defaults = Self.freshDefaults()
    defaults.set("none", forKey: "llmProvider")
    defaults.set("claude", forKey: "lastLLMProvider")
    defaults.set("claude-haiku-5-5", forKey: "llmModel")
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.dictationCloudModelMemory.model(for: .claude) == "claude-haiku-5-5")
    settings.llmProvider = .openAI
    settings.llmProvider = .claude
    #expect(settings.llmModel == "claude-haiku-5-5")
  }

  @Test("an upgrade gives a following import no memory from its dormant fields")
  func upgradeFollowerGetsNoMemory() {
    let defaults = Self.freshDefaults()
    defaults.set("openAI", forKey: "llmProvider")
    defaults.set("gpt-6-luna", forKey: "llmModel")
    defaults.set("gpt-5", forKey: "fileImportLLMModel")
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.fileImportCloudModelMemory == CloudModelMemory())
  }

  @Test("a memory that was already seeded, even empty, is never seeded again")
  func presentEmptyMemoryIsNotReseeded() throws {
    let defaults = Self.freshDefaults()
    defaults.set("gemini", forKey: "llmProvider")
    defaults.set("gemini-2.0-flash", forKey: "llmModel")
    defaults.set(try JSONEncoder().encode(CloudModelMemory()), forKey: "cloudModelByProvider")
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.dictationCloudModelMemory.model(for: .gemini) != "gemini-2.0-flash")
    #expect(settings.llmModel == "gemini-3.7-flash")
  }

  @Test("the launch-time summary migration copies the stored dictation model as stored")
  func summaryMigrationAtLaunchUsesRawModel() {
    let defaults = Self.freshDefaults()
    defaults.set("completed", forKey: "onboardingState")
    defaults.set("gemini", forKey: "llmProvider")
    defaults.set("gemini-2.0-flash", forKey: "llmModel")
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.meetingSummaryLLMProvider == .gemini)
    #expect(settings.meetingSummaryLLMModel == "gemini-2.0-flash")
    #expect(settings.meetingSummaryCloudModelMemory.model(for: .gemini) == "gemini-2.0-flash")
  }

  @Test("the summary migration at onboarding completion takes the pick made in onboarding")
  func summaryMigrationAtOnboarding() {
    let settings = SettingsManager(defaults: Self.freshDefaults())
    #expect(settings.meetingSummaryLLMProvider == nil)
    settings.llmProvider = .claude
    settings.llmModel = "claude-haiku-5-5"
    settings.onboardingState = .completed
    #expect(settings.meetingSummaryLLMProvider == .claude)
    #expect(settings.meetingSummaryLLMModel == "claude-haiku-5-5")
    #expect(settings.meetingSummaryCloudModelMemory.model(for: .claude) == "claude-haiku-5-5")
  }

  @Test("finishing onboarding later keeps a retired dictation pick for meeting summaries")
  func summaryMigrationAtOnboardingKeepsRetiredPick() {
    let defaults = Self.freshDefaults()
    defaults.set("gemini", forKey: "llmProvider")
    defaults.set("gemini-2.0-flash", forKey: "llmModel")
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.meetingSummaryLLMProvider == nil)
    settings.onboardingState = .completed
    #expect(settings.meetingSummaryLLMProvider == .gemini)
    #expect(settings.meetingSummaryLLMModel == "gemini-2.0-flash")
    #expect(settings.meetingSummaryCloudModelMemory.model(for: .gemini) == "gemini-2.0-flash")
    let reloaded = SettingsManager(defaults: defaults)
    #expect(reloaded.meetingSummaryLLMModel == "gemini-2.0-flash")
  }

  @Test("an upgrade keeps a stored import override and remembers it for the import only")
  func upgradeKeepsImportOverride() {
    let defaults = Self.freshDefaults()
    defaults.set("openAI", forKey: "llmProvider")
    defaults.set("gpt-6-luna", forKey: "llmModel")
    defaults.set("claude", forKey: "fileImportLLMProvider")
    defaults.set("claude-haiku-5-5", forKey: "fileImportLLMModel")
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.fileImportCloudModelMemory.model(for: .claude) == "claude-haiku-5-5")
    #expect(settings.dictationCloudModelMemory.model(for: .claude) == nil)
    let reloaded = SettingsManager(defaults: defaults)
    reloaded.fileImportLLMProvider = .openAI
    reloaded.fileImportLLMProvider = .claude
    #expect(reloaded.fileImportLLMModel == "claude-haiku-5-5")
    #expect(reloaded.llmModel == "gpt-6-luna")
  }

  @Test("an upgrade keeps a stored summary selection, retired ids included")
  func upgradeKeepsStoredSummary() {
    let defaults = Self.freshDefaults()
    defaults.set("openAI", forKey: "llmProvider")
    defaults.set("gpt-6-luna", forKey: "llmModel")
    defaults.set("gemini", forKey: "meetingSummaryLLMProvider")
    defaults.set("gemini-2.0-flash", forKey: "meetingSummaryLLMModel")
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.meetingSummaryLLMModel == "gemini-2.0-flash")
    #expect(settings.meetingSummaryCloudModelMemory.model(for: .gemini) == "gemini-2.0-flash")
    #expect(settings.dictationCloudModelMemory.model(for: .gemini) == nil)
    let reloaded = SettingsManager(defaults: defaults)
    #expect(reloaded.meetingSummaryLLMModel == "gemini-2.0-flash")
    #expect(reloaded.llmModel == "gpt-6-luna")
  }

  // MARK: - Discovery never replaces a remembered pick

  enum Surface: CaseIterable { case dictation, fileImport, meetingSummary }
  enum Catalog: CaseIterable { case empty, missing, locked }

  @Test(
    "discovery makes no model write on a remembered pick",
    arguments: Surface.allCases, Catalog.allCases)
  func discoveryLeavesRememberedPickAlone(surface: Surface, catalog: Catalog) {
    let settings = SettingsManager(defaults: Self.freshDefaults())
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-6-luna"
    switch surface {
    case .dictation: break
    case .fileImport:
      settings.seedFileImportPolishModelsIfNeeded(for: .openAI)
      settings.fileImportLLMProvider = .openAI
      settings.fileImportLLMModel = "gpt-6-luna"
    case .meetingSummary:
      settings.meetingSummaryLLMProvider = .openAI
      settings.meetingSummaryLLMModel = "gpt-6-luna"
    }
    let models: [LLMModelInfo]
    switch catalog {
    case .empty: models = []
    case .missing: models = [Self.row("gpt-4o-mini")]
    case .locked: models = [Self.row("gpt-6-luna", available: false), Self.row("gpt-4o-mini")]
    }
    var modelWrites: [SettingsManager.SettingKey] = []
    settings.onChange = { key in
      if [.llmModel, .fileImportLLMModel, .meetingSummaryLLMModel].contains(key) {
        modelWrites.append(key)
      }
    }
    switch surface {
    case .dictation: settings.applyDiscoveredModels(models, for: .openAI)
    case .fileImport: settings.applyDiscoveredModelsForFileImport(models, for: .openAI)
    case .meetingSummary: settings.applyDiscoveredModelsForMeetingSummary(models, for: .openAI)
    }
    settings.onChange = nil
    #expect(modelWrites.isEmpty)
    #expect(settings.llmModel == "gpt-6-luna")
    switch surface {
    case .dictation: break
    case .fileImport: #expect(settings.fileImportLLMModel == "gpt-6-luna")
    case .meetingSummary: #expect(settings.meetingSummaryLLMModel == "gpt-6-luna")
    }
  }
}
