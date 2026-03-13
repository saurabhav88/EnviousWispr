import Foundation
import EnviousWisprCore

/// Events that any dictation pipeline must handle.
enum PipelineEvent: Sendable {
    case preWarm
    case toggleRecording
    case requestStop
    case cancelRecording
    case reset
}

/// What the overlay should display — decoupled from internal pipeline state.
enum OverlayIntent: Equatable, Sendable {
    case hidden
    case recording(audioLevel: Float)
    case processing(label: String)
}

/// Abstraction over dictation pipelines (Parakeet streaming, WhisperKit batch, etc.).
/// Each pipeline owns its own state machine and emits `OverlayIntent` for UI.
@MainActor
protocol DictationPipeline: AnyObject {
    var overlayIntent: OverlayIntent { get }
    func handle(event: PipelineEvent) async
}
