import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
@testable import EnviousWisprServices

/// #4287: the Summaries tab edits its OWN engine through the shared polish editor
/// (`ProviderSetupSurface.meetingSummary`).
///
/// When these fail, the user sees a summary engine change move their dictation or Transcribe
/// a File engine (or the reverse), a picked summary model that is never used, or an Ollama
/// download cancelled while another screen still needs it.
@MainActor
@Suite("Meeting summary surface routing (#4287)", .tags(.productOutcome))
struct MeetingSummarySurfaceRoutingTests {
  private static func freshSettings() -> SettingsManager {
    SettingsManager(defaults: TestDefaults.suite("ew.tests.4287.surface.\(UUID().uuidString)")!)
  }

  private static func row(_ id: String, provider: LLMProvider) -> LLMModelInfo {
    LLMModelInfo(id: id, displayName: id, provider: provider, isAvailable: true, isRemote: false)
  }

  @Test("the summary surface reads and writes only the summary fields")
  func readsAndWritesOnlySummaryFields() {
    let settings = Self.freshSettings()
    settings.llmProvider = .gemini
    settings.fileImportLLMProvider = .claude
    let dictationModel = settings.llmModel
    let importModel = settings.fileImportLLMModel

    PolishSettings.setProvider(.openAI, on: .meetingSummary, in: settings)
    PolishSettings.setCloudModel("gpt-5.2", on: .meetingSummary, in: settings)

    #expect(PolishSettings.provider(on: .meetingSummary, in: settings) == .openAI)
    #expect(PolishSettings.cloudModel(on: .meetingSummary, in: settings) == "gpt-5.2")
    #expect(settings.meetingSummarySelection.model == "gpt-5.2")
    #expect(settings.llmProvider == .gemini)
    #expect(settings.llmModel == dictationModel)
    #expect(settings.fileImportLLMProvider == .claude)
    #expect(settings.fileImportLLMModel == importModel)
  }

  @Test("an unmigrated summary choice reads as no engine, never dictation's")
  func unmigratedReadsAsNone() {
    let settings = Self.freshSettings()
    settings.llmProvider = .openAI
    #expect(settings.meetingSummaryLLMProvider == nil)
    #expect(PolishSettings.provider(on: .meetingSummary, in: settings) == .none)
  }

  @Test("a summary provider change is normalized before observers hear it")
  func normalizedBeforeNotification() {
    let settings = Self.freshSettings()
    settings.meetingSummaryLLMProvider = .egOne
    var modelSeenByObserver: String?
    settings.onChange = { key in
      if key == .meetingSummaryLLMProvider { modelSeenByObserver = settings.meetingSummaryLLMModel }
    }
    settings.meetingSummaryLLMProvider = .openAI
    #expect(modelSeenByObserver == LLMProvider.defaultModel(for: .openAI))
  }

  @Test("each summary field emits its own change")
  func eachFieldEmits() {
    let settings = Self.freshSettings()
    var keys: [SettingsManager.SettingKey] = []
    settings.onChange = { keys.append($0) }
    settings.meetingSummaryLLMProvider = .claude
    settings.meetingSummaryLLMModel = "claude-sonnet-4-5"
    settings.meetingSummaryOllamaModel = "mistral"
    #expect(keys.contains(.meetingSummaryLLMProvider))
    #expect(keys.contains(.meetingSummaryLLMModel))
    #expect(keys.contains(.meetingSummaryOllamaModel))
  }

  @Test("the surface revision counts A to B to A on the summary surface only")
  func surfaceRevisionTracksSummary() {
    let settings = Self.freshSettings()
    let start = ProviderSetupSurface.meetingSummary.selectionRevision(in: settings)
    let dictationStart = ProviderSetupSurface.dictation.selectionRevision(in: settings)
    settings.meetingSummaryLLMProvider = .openAI
    settings.meetingSummaryLLMProvider = .claude
    settings.meetingSummaryLLMProvider = .openAI
    #expect(ProviderSetupSurface.meetingSummary.selectionRevision(in: settings) == start + 3)
    #expect(ProviderSetupSurface.dictation.selectionRevision(in: settings) == dictationStart)
  }

  @Test("a summary catalog repairs only the summary model, and only for its own provider")
  func repairRoutesToSummaryFields() {
    let settings = Self.freshSettings()
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-4o-mini"
    settings.meetingSummaryLLMProvider = .openAI
    settings.meetingSummaryLLMModel = "gpt-4o-retired"

    settings.applyDiscoveredModelsForMeetingSummary(
      [Self.row("gpt-5.2", provider: .openAI)], for: .openAI)
    #expect(settings.meetingSummaryLLMModel == "gpt-5.2")
    #expect(settings.llmModel == "gpt-4o-mini")

    settings.applyDiscoveredModelsForMeetingSummary(
      [Self.row("gemini-3-flash", provider: .gemini)], for: .gemini)
    #expect(settings.meetingSummaryLLMModel == "gpt-5.2")
  }

  @Test("discovery started from the Summaries tab repairs the summary model, not dictation's")
  func discoveryRoutesBySurface() async {
    let settings = Self.freshSettings()
    settings.llmProvider = .ollama
    settings.ollamaModel = "llama3"
    settings.meetingSummaryLLMProvider = .ollama
    settings.meetingSummaryOllamaModel = "gone-model"
    let discovery = LLMModelDiscoveryCoordinator(
      keychainManager: KeychainManager(),
      cacheDefaults: TestDefaults.suite("ew.tests.4287.cache.\(UUID().uuidString)")!,
      validationEmitter: { _, _, _, _, _ in },
      discoverModels: { _, _ in [Self.row("mistral", provider: .ollama)] })

    await discovery.validateKeyAndDiscoverModels(
      provider: .ollama, settings: settings, surface: .meetingSummary)

    #expect(settings.meetingSummaryOllamaModel == "mistral")
    #expect(settings.ollamaModel == "llama3")
  }

  private static func coordinator(
    cache: UserDefaults = TestDefaults.suite("ew.tests.4287.cache.\(UUID().uuidString)")!,
    discover: @escaping @MainActor (LLMProvider, String) async throws -> [LLMModelInfo]
  ) -> LLMModelDiscoveryCoordinator {
    LLMModelDiscoveryCoordinator(
      keychainManager: KeychainManager(), cacheDefaults: cache,
      validationEmitter: { _, _, _, _, _ in }, discoverModels: discover)
  }

  @Test("discovery keeps a stored EG-1 Ollama summary model that the catalog lacks")
  func discoveryKeepsStoredUnsupportedModel() async {
    let settings = Self.freshSettings()
    settings.meetingSummaryLLMProvider = .ollama
    settings.meetingSummaryOllamaModel = "eg-1:latest"
    let discovery = Self.coordinator { _, _ in [Self.row("mistral", provider: .ollama)] }
    await discovery.validateKeyAndDiscoverModels(
      provider: .ollama, settings: settings, surface: .meetingSummary)
    #expect(settings.meetingSummaryOllamaModel == "eg-1:latest")
  }

  @Test("discovery never arms an EG-1 or S1-mini Ollama model for summaries")
  func discoveryNeverArmsUnsupportedModel() async {
    let settings = Self.freshSettings()
    settings.meetingSummaryLLMProvider = .ollama
    settings.meetingSummaryOllamaModel = "gone-model"
    let discovery = Self.coordinator { _, _ in
      [Self.row("eg-1:latest", provider: .ollama),
       Self.row("hf.co/superwhisper/s1-mini-GGUF:Q4_K_M", provider: .ollama)]
    }
    await discovery.validateKeyAndDiscoverModels(
      provider: .ollama, settings: settings, surface: .meetingSummary)
    #expect(!MeetingSummaryModelPolicy.isUnsupportedOllamaModel(settings.meetingSummaryOllamaModel))
    #expect(!MeetingSummaryModelPolicy.isUnsupportedOllamaModel(settings.meetingSummarySelection.model))
  }

  @Test("a summary discovery whose selection moved A to B to A while in flight repairs nothing")
  func staleSummaryDiscoveryIsDropped() async {
    let settings = Self.freshSettings()
    settings.meetingSummaryLLMProvider = .ollama
    settings.meetingSummaryOllamaModel = "gone-model"
    let discovery = Self.coordinator { _, _ in
      settings.meetingSummaryLLMProvider = .claude
      settings.meetingSummaryLLMProvider = .ollama
      return [Self.row("mistral", provider: .ollama)]
    }
    await discovery.validateKeyAndDiscoverModels(
      provider: .ollama, settings: settings, surface: .meetingSummary)
    #expect(settings.meetingSummaryOllamaModel == "gone-model")
  }

  @Test("a cached catalog load repairs an excluded summary model and leaves dictation's alone")
  func cachedRepairRoutesToSummary() throws {
    let cache = TestDefaults.suite("ew.tests.4287.cache.\(UUID().uuidString)")!
    let rows = [Self.row("gpt-5.2", provider: .openAI), Self.row("gpt-image-1", provider: .openAI)]
    cache.set(try JSONEncoder().encode(rows), forKey: "cachedModels_openAI")
    let settings = Self.freshSettings()
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-4o-mini"
    settings.meetingSummaryLLMProvider = .openAI
    settings.meetingSummaryLLMModel = "gpt-image-1"
    let discovery = Self.coordinator(cache: cache) { _, _ in [] }
    discovery.loadCachedModels(for: .openAI, settings: settings, surface: .meetingSummary)
    #expect(settings.meetingSummaryLLMModel == "gpt-5.2")
    #expect(settings.llmModel == "gpt-4o-mini")
  }

  @Test("shared Ollama work is cancelled only when neither other surface is on Ollama")
  func cleanupNeedsBothOtherSurfacesOff() {
    for leaving in [ProviderSetupSurface.dictation, .fileImport, .meetingSummary] {
      #expect(
        SharedOllamaCleanup.mayCancel(
          leaving: leaving, dictation: .openAI, importEffective: .openAI, summary: .openAI))
    }
    #expect(
      !SharedOllamaCleanup.mayCancel(
        leaving: .dictation, dictation: .openAI, importEffective: .openAI, summary: .ollama))
    #expect(
      !SharedOllamaCleanup.mayCancel(
        leaving: .fileImport, dictation: .openAI, importEffective: .openAI, summary: .ollama))
    #expect(
      !SharedOllamaCleanup.mayCancel(
        leaving: .meetingSummary, dictation: .ollama, importEffective: .openAI, summary: .openAI))
    #expect(
      !SharedOllamaCleanup.mayCancel(
        leaving: .meetingSummary, dictation: .openAI, importEffective: .ollama, summary: .openAI))
  }

  @Test("the summary surface's download list leaves out EG-1 and S1-mini")
  func summaryCatalogHidesFirstParty() {
    func entry(_ name: String) -> OllamaModelCatalogEntry {
      OllamaModelCatalogEntry(
        name: name, displayName: name, parameterCount: "", downloadSize: "", isDownloaded: false)
    }
    let entries = [entry("mistral"), entry("eg-1:latest")]
    #expect(ProviderSetupSurface.meetingSummary.offeredCatalog(entries).map(\.name) == ["mistral"])
    #expect(ProviderSetupSurface.dictation.offeredCatalog(entries).count == 2)
  }

  @Test("a typed EG-1 name in the Models sheet search is not offered as a summary download")
  func typedSuggestionRespectsSummaryPolicy() {
    // The S1-mini Hugging Face name is never a typed suggestion (`nameDropReason` drops it).
    for name in ["eg-1:latest", "eg-1:q5"] {
      let suggestion = OllamaCatalogPresentation.typedDownloadSuggestion(
        query: name, catalog: [], searchMatchedAnyRow: false)
      #expect(suggestion?.name == name, "the producer offers it on the other surfaces")
      #expect(suggestion.flatMap { ProviderSetupSurface.meetingSummary.offeredCatalog([$0]).first }?.name == nil)
      #expect(suggestion.flatMap { ProviderSetupSurface.dictation.offeredCatalog([$0]).first }?.name == name)
    }
  }

  @Test("the guided download never offers a kept EG-1 summary model")
  func guidedDownloadAvoidsUnsupportedModel() {
    #expect(ProviderSetupSurface.meetingSummary.guidedDownloadModel(remembered: "eg-1:latest") == "qwen2.5:3b")
    #expect(ProviderSetupSurface.meetingSummary.guidedDownloadModel(remembered: "mistral") == "mistral")
    #expect(ProviderSetupSurface.dictation.guidedDownloadModel(remembered: "eg-1:latest") == "eg-1:latest")
  }

  @Test("the summary surface offers no EG-1 or S1-mini Ollama models; other surfaces do")
  func summaryHidesFirstPartyOllamaModels() {
    let models = [
      Self.row("mistral", provider: .ollama), Self.row("eg-1:latest", provider: .ollama),
      Self.row("hf.co/superwhisper/s1-mini-GGUF:Q4_K_M", provider: .ollama),
    ]
    #expect(
      ProviderSetupSurface.meetingSummary.offeredModels(models, provider: .ollama).map(\.id)
        == ["mistral"])
    #expect(ProviderSetupSurface.dictation.offeredModels(models, provider: .ollama).count == 3)
    #expect(ProviderSetupSurface.fileImport.offeredModels(models, provider: .ollama).count == 3)
  }

  @Test("a stored unsupported summary model is kept until the user picks another")
  func storedUnsupportedModelIsKept() {
    let settings = Self.freshSettings()
    settings.meetingSummaryLLMProvider = .ollama
    settings.meetingSummaryOllamaModel = "eg-1:latest"
    settings.applyDiscoveredModelsForMeetingSummary(
      [Self.row("eg-1:latest", provider: .ollama), Self.row("mistral", provider: .ollama)],
      for: .ollama)
    #expect(settings.meetingSummaryOllamaModel == "eg-1:latest")
  }

  @Test("an Ollama pick on the Summaries tab arms the summary Ollama model only")
  func summaryOllamaPickMirrors() {
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = DictationRuntimeFixtures.tempStore()
    let sync = PipelineSettingsSync(
      kernelDriver: DictationRuntimeFixtures.makeParakeetDriver(
        audioCapture: audio, asrManager: asr, store: store),
      whisperKernelDriver: DictationRuntimeFixtures.makeWhisperPipeline(
        audioCapture: audio, store: store),
      audioCapture: audio, asrManager: asr,
      hotkeyService: HotkeyService(effects: RecordingDesktopHotkeyEffects()),
      ollamaRemotenessLookup: { _ in false })
    sync.evictionScheduler = { _ in }
    let settings = Self.freshSettings()
    settings.ollamaModel = "llama3"
    settings.fileImportOllamaModel = "qwen3"
    settings.meetingSummaryLLMProvider = .ollama
    settings.meetingSummaryLLMModel = "mistral"

    sync.handleSettingChanged(.meetingSummaryLLMModel, settings: settings)

    #expect(settings.meetingSummaryOllamaModel == "mistral")
    #expect(settings.meetingSummarySelection.model == "mistral")
    #expect(settings.ollamaModel == "llama3")
    #expect(settings.fileImportOllamaModel == "qwen3")
  }
}
