import Foundation
import EnviousWisprCore

/// Events that any dictation pipeline must handle.
public enum PipelineEvent: Sendable {
    case preWarm
    case toggleRecording
    case requestStop
    case cancelRecording
    case reset
}

/// What the overlay should display — decoupled from internal pipeline state.
public enum OverlayIntent: Equatable, Sendable {
    case hidden
    case recording(audioLevel: Float)
    case processing(label: String)
    /// Transient notice shown when paste fell back to clipboard-only (Tier 3).
    /// Auto-dismissed by the overlay panel after a short delay.
    case clipboardFallback
    /// Transient error notice shown when ASR fails despite speech evidence.
    /// Auto-dismissed by the overlay panel after 3 seconds.
    case error(message: String)
}

/// Abstraction over dictation pipelines (Parakeet streaming, WhisperKit batch, etc.).
/// Each pipeline owns its own state machine and emits `OverlayIntent` for UI.
@MainActor
public protocol DictationPipeline: AnyObject {
    var overlayIntent: OverlayIntent { get }
    func handle(event: PipelineEvent) async
}
