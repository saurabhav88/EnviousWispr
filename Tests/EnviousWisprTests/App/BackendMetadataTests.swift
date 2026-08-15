import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Unit tests for `BackendMetadata` (PR7 of epic #763). Covers the three
/// display surfaces exposed to views/AppDelegate: `modelLabel`,
/// `llmLabel`, and `statusText(for:)`. Behavior parity with pre-PR7
/// the former root state getters is the contract.
@MainActor
@Suite("BackendMetadata")
struct BackendMetadataTests {

  // MARK: - modelLabel

  @Test("modelLabel: Parakeet backend returns 'Parakeet v3'")
  func modelLabelParakeet() {
    let bm = makeBackendMetadata()
    bm.settings.selectedBackend = .parakeet
    #expect(bm.modelLabel == "Parakeet v3")
  }

  @Test("modelLabel: WhisperKit backend returns 'WhisperKit'")
  func modelLabelWhisperKit() {
    let bm = makeBackendMetadata()
    bm.settings.selectedBackend = .whisperKit
    #expect(bm.modelLabel == "WhisperKit")
  }

  // MARK: - llmLabel

  @Test("llmLabel: provider .none returns 'LLM Deactivated'")
  func llmLabelDeactivated() {
    let bm = makeBackendMetadata()
    bm.settings.llmProvider = .none
    #expect(bm.llmLabel == "LLM Deactivated")
  }

  @Test("llmLabel: empty model returns provider displayName")
  func llmLabelEmptyModelFallsBackToProviderName() {
    let bm = makeBackendMetadata()
    bm.settings.llmProvider = .openAI
    bm.settings.llmModel = ""
    #expect(bm.llmLabel == "OpenAI")
  }

  @Test("llmLabel: unknown model ID returns the raw ID")
  func llmLabelUnknownModelReturnsRawID() {
    let bm = makeBackendMetadata()
    bm.settings.llmProvider = .gemini
    bm.settings.llmModel = "gemini-future-model"
    bm.llmDiscovery.discoveredModels = []
    #expect(bm.llmLabel == "gemini-future-model")
  }

  @Test("llmLabel: discovered model returns its displayName")
  func llmLabelDiscoveredModelReturnsDisplayName() {
    let bm = makeBackendMetadata()
    bm.settings.llmProvider = .openAI
    bm.settings.llmModel = "gpt-4o-mini"
    bm.llmDiscovery.discoveredModels = [
      LLMModelInfo(
        id: "gpt-4o-mini",
        displayName: "GPT-4o Mini",
        provider: .openAI,
        isAvailable: true,
        isRemote: false)
    ]
    #expect(bm.llmLabel == "GPT-4o Mini")
  }

  @Test("llmLabel: Ollama provider reads ollamaModel, not llmModel")
  func llmLabelOllamaReadsOllamaModel() {
    let bm = makeBackendMetadata()
    bm.settings.llmProvider = .ollama
    bm.settings.ollamaModel = "llama3.2"
    bm.llmDiscovery.discoveredModels = []
    #expect(bm.llmLabel == "llama3.2")
  }

  // MARK: - polishLabel

  @Test("polishLabel: provider .none returns 'Off' even with stale model fields populated")
  func polishLabelOffIgnoresStaleModels() {
    let bm = makeBackendMetadata()
    bm.settings.llmProvider = LLMProvider.none
    bm.settings.llmModel = "gpt-4o-mini"
    bm.settings.ollamaModel = "llama3.2"
    #expect(bm.polishLabel == "Off")
  }

  @Test("polishLabel: discovered cloud model returns its displayName")
  func polishLabelDiscoveredModelReturnsDisplayName() {
    let bm = makeBackendMetadata()
    bm.settings.llmProvider = .openAI
    bm.settings.llmModel = "gpt-4o-mini"
    bm.llmDiscovery.discoveredModels = [
      LLMModelInfo(
        id: "gpt-4o-mini",
        displayName: "GPT-4o Mini",
        provider: .openAI,
        isAvailable: true,
        isRemote: false)
    ]
    #expect(bm.polishLabel == "GPT-4o Mini")
  }

  @Test("polishLabel: cloud model before discovery returns the raw ID")
  func polishLabelPreDiscoveryReturnsRawID() {
    let bm = makeBackendMetadata()
    bm.settings.llmProvider = .gemini
    bm.settings.llmModel = "gemini-2.0-flash"
    bm.llmDiscovery.discoveredModels = []
    #expect(bm.polishLabel == "gemini-2.0-flash")
  }

  @Test("polishLabel: Apple Intelligence is named directly, never the raw model id")
  func polishLabelAppleIntelligenceNamedDirectly() {
    let bm = makeBackendMetadata()
    bm.settings.llmProvider = .appleIntelligence
    bm.settings.llmModel = "apple-intelligence"
    bm.llmDiscovery.discoveredModels = []
    #expect(bm.polishLabel == "Apple Intelligence")
  }

  @Test("polishLabel: Ollama provider reads ollamaModel")
  func polishLabelOllamaReadsOllamaModel() {
    let bm = makeBackendMetadata()
    bm.settings.llmProvider = .ollama
    bm.settings.ollamaModel = "llama3.2"
    bm.llmDiscovery.discoveredModels = []
    #expect(bm.polishLabel == "llama3.2")
  }

  // MARK: - statusText(for:)

  /// #2065 replaced the per-engine cases here. There used to be a Parakeet block
  /// and a WhisperKit block, each pinning the active engine and
  /// asserting the same four strings — and only the WhisperKit block covered
  /// `.loadingModel`, which is precisely why the missing Parakeet case shipped.
  /// Two tables tested twice still leaves the untested cell untested.
  ///
  /// `statusText` no longer reads the engine at all, so an engine dimension here
  /// would assert a coupling the code does not have.
  nonisolated static let activeStates: [(PipelineState, String)] = [
    (.loadingModel, "Loading Model"),
    (.recording, "Recording"),
    (.transcribing, "Transcribing"),
    (.polishing, "Polishing"),
    (.error(.modelWedged), "Error"),
  ]

  @Test("statusText names every active phase, whichever engine is running", arguments: activeStates)
  func statusTextNamesActivePhases(state: PipelineState, expected: String) {
    let bm = makeBackendMetadata()
    #expect(bm.statusText(for: state) == expected)
  }

  /// The regression this issue was filed for. Against pre-fix `main` this case
  /// returns "Unloaded" — the engine-health label — while the model is loading.
  @Test("statusText: a loading model never reports the engine-health label")
  func loadingModelNeverReportsHealthLabel() {
    // Both health values, because the pre-fix bug rendered whichever one the
    // health closure happened to hold: "Unloaded" mid-load, or a flat "Loaded"
    // that is equally wrong while a load is in flight.
    for loaded in [true, false] {
      let bm = makeBackendMetadata(modelLoaded: loaded)
      let text = bm.statusText(for: .loadingModel)
      #expect(text == "Loading Model")
      #expect(text != "Unloaded")
      #expect(text != "Loaded")
    }
  }

  /// The two-way control for the fix: the states that SHOULD show engine health
  /// still do. Without this, deleting the health fallback entirely would pass
  /// the case above.
  @Test("statusText: idle, complete and advisory still report engine health")
  func restingStatesReportEngineHealth() {
    let unloaded = makeBackendMetadata(modelLoaded: false)
    #expect(unloaded.statusText(for: .idle) == "Unloaded")
    #expect(unloaded.statusText(for: .complete) == "Unloaded")

    let loaded = makeBackendMetadata(modelLoaded: true)
    #expect(loaded.statusText(for: .idle) == "Loaded")
  }

  /// #1891, pinned so the #2065 collapse cannot quietly take it with it: an
  /// advisory is NOT an error in the sidebar. The microphone sent nothing; the
  /// engine is fine, so the health label is the honest answer.
  @Test("statusText: advisory keeps falling through to health, never 'Error'")
  func advisoryIsNotAnError() {
    let bm = makeBackendMetadata(modelLoaded: true)
    #expect(bm.statusText(for: .advisory(.noTransport)) == "Loaded")
    #expect(bm.statusText(for: .advisory(.noTransport)) != "Error")
  }

  // MARK: - Fixture

  /// `modelLoaded` drives the engine-health label, which is what `.loadingModel`
  /// used to be mistaken for on the non-WhisperKit path (#2065).
  private func makeBackendMetadata(modelLoaded: Bool = false) -> BackendMetadata {
    let settings = SettingsManager()
    let llmDiscovery = LLMModelDiscoveryCoordinator(keychainManager: KeychainManager())
    return BackendMetadata(
      settings: settings,
      llmDiscovery: llmDiscovery,
      activeModelLoaded: { modelLoaded }
    )
  }
}
