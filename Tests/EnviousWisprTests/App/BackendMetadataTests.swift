import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWispr
@testable import EnviousWisprASR

/// Unit tests for `BackendMetadata` (PR7 of epic #763). Covers the three
/// display surfaces exposed to views/AppDelegate: `modelLabel`,
/// `llmLabel`, and `statusText(for:)`. Behavior parity with pre-PR7
/// AppState getters is the contract.
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
        isAvailable: true)
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

  // MARK: - statusText(for:) — Parakeet branch

  @Test("statusText Parakeet: .recording returns 'Recording'")
  func statusTextParakeetRecording() {
    let bm = makeBackendMetadata()
    bm.asrManager.setInitialBackendType(.parakeet)
    #expect(bm.statusText(for: .recording) == "Recording")
  }

  @Test("statusText Parakeet: .transcribing returns 'Transcribing'")
  func statusTextParakeetTranscribing() {
    let bm = makeBackendMetadata()
    bm.asrManager.setInitialBackendType(.parakeet)
    #expect(bm.statusText(for: .transcribing) == "Transcribing")
  }

  @Test("statusText Parakeet: .polishing returns 'Polishing'")
  func statusTextParakeetPolishing() {
    let bm = makeBackendMetadata()
    bm.asrManager.setInitialBackendType(.parakeet)
    #expect(bm.statusText(for: .polishing) == "Polishing")
  }

  @Test("statusText Parakeet: .error returns 'Error'")
  func statusTextParakeetError() {
    let bm = makeBackendMetadata()
    bm.asrManager.setInitialBackendType(.parakeet)
    #expect(bm.statusText(for: .error("boom")) == "Error")
  }

  @Test("statusText Parakeet: .idle falls back to model-loaded label")
  func statusTextParakeetIdleFallback() {
    let bm = makeBackendMetadata()
    bm.asrManager.setInitialBackendType(.parakeet)
    // Default isModelLoaded is false → "Unloaded"
    #expect(bm.statusText(for: .idle) == "Unloaded")
  }

  // MARK: - statusText(for:) — WhisperKit branch

  @Test("statusText WhisperKit: .loadingModel returns 'Loading Model'")
  func statusTextWhisperKitLoadingModel() {
    let bm = makeBackendMetadata()
    bm.asrManager.setInitialBackendType(.whisperKit)
    #expect(bm.statusText(for: .loadingModel) == "Loading Model")
  }

  @Test("statusText WhisperKit: .recording returns 'Recording'")
  func statusTextWhisperKitRecording() {
    let bm = makeBackendMetadata()
    bm.asrManager.setInitialBackendType(.whisperKit)
    #expect(bm.statusText(for: .recording) == "Recording")
  }

  @Test("statusText WhisperKit: .idle falls back to model-loaded label")
  func statusTextWhisperKitIdleFallback() {
    let bm = makeBackendMetadata()
    bm.asrManager.setInitialBackendType(.whisperKit)
    #expect(bm.statusText(for: .idle) == "Unloaded")
  }

  // MARK: - Fixture

  private func makeBackendMetadata() -> BackendMetadata {
    let settings = SettingsManager()
    let asrManager = ASRManager()
    let llmDiscovery = LLMModelDiscoveryCoordinator(keychainManager: KeychainManager())
    return BackendMetadata(
      settings: settings,
      asrManager: asrManager,
      llmDiscovery: llmDiscovery
    )
  }
}
