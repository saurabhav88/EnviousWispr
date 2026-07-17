import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprServices
import Observation

/// PR7 of epic #763. Display-only labels for the active ASR backend, the
/// LLM polish provider/model, and the pipeline status string. Replaces
/// the former root state's `activeModelName`, `activeLLMDisplayName`, `modelStatusText`.
/// `statusText(for:)` takes the active `PipelineState` as a parameter to
/// keep `EnviousWisprPipeline` out of this home's import set.
@Observable @MainActor
final class BackendMetadata {
  let settings: SettingsManager
  let asrManager: any ASRManagerInterface
  let llmDiscovery: LLMModelDiscoveryCoordinator
  /// Whether the ACTIVE engine's model is resident — the EngineCoordinator's
  /// published truth, injected as a closure. The manager's own flag stopped
  /// covering WhisperKit when #1386 made it Parakeet-only (cloud review P2:
  /// a warmed multilingual model rendered "Unloaded").
  let activeModelLoaded: @MainActor () -> Bool

  init(
    settings: SettingsManager,
    asrManager: any ASRManagerInterface,
    llmDiscovery: LLMModelDiscoveryCoordinator,
    activeModelLoaded: @escaping @MainActor () -> Bool
  ) {
    self.settings = settings
    self.asrManager = asrManager
    self.llmDiscovery = llmDiscovery
    self.activeModelLoaded = activeModelLoaded
  }

  var modelLabel: String {
    settings.selectedBackend == .parakeet ? "Parakeet v3" : "WhisperKit"
  }

  /// Sidebar AI Polish row label. Reads the CONFIGURED polish target
  /// (a settings readout), not runtime availability or last-polish
  /// success — a configured-but-unreachable provider still shows its
  /// model name; per-dictation outcomes surface on the transcript.
  /// Apple Intelligence is named directly: its model id never varies
  /// and discovery only runs when the settings pane is visited.
  var polishLabel: String {
    switch settings.llmProvider {
    case .none: "Off"
    case .appleIntelligence: "Apple Intelligence"
    case .egOne: "EG-1"  // #1271: fixed name, like Apple Intelligence above
    default: llmLabel
    }
  }

  var llmLabel: String {
    guard settings.llmProvider != .none else { return "LLM Deactivated" }
    let model = settings.effectiveLLMModel  // #1173: single source of truth
    if model.isEmpty { return settings.llmProvider.displayName }
    if let info = llmDiscovery.discoveredModels.first(where: { $0.id == model }) {
      return info.displayName
    }
    return model
  }

  func statusText(for state: PipelineState) -> String {
    if asrManager.activeBackendType == .whisperKit {
      switch state {
      case .loadingModel: return DictationNarrator.loadingModelSidebar
      case .recording: return DictationNarrator.recordingStatus
      case .transcribing: return DictationNarrator.shortCopy(for: .transcribing)
      case .polishing: return DictationNarrator.shortCopy(for: .polishing)
      case .error: return DictationNarrator.errorStatus
      default: break
      }
    } else {
      if state == .recording { return DictationNarrator.recordingStatus }
      if state == .transcribing { return DictationNarrator.shortCopy(for: .transcribing) }
      if state == .polishing { return DictationNarrator.shortCopy(for: .polishing) }
      if case .error = state { return DictationNarrator.errorStatus }
    }
    return activeModelLoaded() ? "Loaded" : "Unloaded"
  }
}
