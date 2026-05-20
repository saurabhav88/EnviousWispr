import EnviousWisprCore
import EnviousWisprPipeline

extension WhisperKitPipelineState {
  /// One authoritative mapping from WhisperKit's 9-state enum to unified PipelineState.
  var asPipelineState: PipelineState {
    switch self {
    case .idle, .ready: return .idle
    case .startingUp, .loadingModel: return .loadingModel
    case .recording: return .recording
    case .transcribing: return .transcribing
    case .polishing: return .polishing
    case .complete: return .complete
    case .error(let msg): return .error(msg)
    }
  }
}
