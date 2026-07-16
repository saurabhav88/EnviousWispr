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

  init(
    settings: SettingsManager,
    asrManager: any ASRManagerInterface,
    llmDiscovery: LLMModelDiscoveryCoordinator
  ) {
    self.settings = settings
    self.asrManager = asrManager
    self.llmDiscovery = llmDiscovery
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
      case .loadingModel: return "Loading Model"
      case .recording: return "Recording"
      case .transcribing: return DictationNarrator.shortCopy(for: .transcribing)
      case .polishing: return DictationNarrator.shortCopy(for: .polishing)
      case .error: return "Error"
      default: break
      }
    } else {
      if state == .recording { return "Recording" }
      if state == .transcribing { return DictationNarrator.shortCopy(for: .transcribing) }
      if state == .polishing { return DictationNarrator.shortCopy(for: .polishing) }
      if case .error = state { return "Error" }
    }
    return asrManager.isModelLoaded ? "Loaded" : "Unloaded"
  }
}
