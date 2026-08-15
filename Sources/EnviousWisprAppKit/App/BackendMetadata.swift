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
  let llmDiscovery: LLMModelDiscoveryCoordinator
  /// Whether the ACTIVE engine's model is resident — the EngineCoordinator's
  /// published truth, injected as a closure. The manager's own flag stopped
  /// covering WhisperKit when #1386 made it Parakeet-only (cloud review P2:
  /// a warmed multilingual model rendered "Unloaded").
  let activeModelLoaded: @MainActor () -> Bool

  /// #2065 dropped the `asrManager` collaborator: its only reader was the
  /// per-engine branch in `statusText(for:)`, so collapsing that left it
  /// assigned and never read.
  init(
    settings: SettingsManager,
    llmDiscovery: LLMModelDiscoveryCoordinator,
    activeModelLoaded: @escaping @MainActor () -> Bool
  ) {
    self.settings = settings
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

  /// #2065: ONE table, not one per engine. This branched on `activeBackendType`
  /// and the arms were identical apart from `.loadingModel`, which only the
  /// WhisperKit arm handled — so the sidebar called the fast engine "Unloaded"
  /// mid-load. Collapsed, not copied across: two hand-synchronised tables is
  /// what produced the bug. Exhaustive, so a new `PipelineState` fails to
  /// compile here rather than silently landing on the health label.
  func statusText(for state: PipelineState) -> String {
    switch state {
    case .loadingModel: return DictationNarrator.loadingModelSidebar
    case .recording: return DictationNarrator.recordingStatus
    case .transcribing: return DictationNarrator.shortCopy(for: .transcribing)
    case .polishing: return DictationNarrator.shortCopy(for: .polishing)
    case .error: return DictationNarrator.errorStatus
    // #1891: `.advisory` deliberately falls through to the engine-health label
    // ("Loaded" / "Unloaded") rather than showing "Error" in the sidebar. The
    // microphone sent nothing; the engine is fine. Kept distinct from `.error`
    // on purpose — do not collapse them.
    case .advisory, .idle, .complete:
      return activeModelLoaded() ? "Loaded" : "Unloaded"
    }
  }
}
