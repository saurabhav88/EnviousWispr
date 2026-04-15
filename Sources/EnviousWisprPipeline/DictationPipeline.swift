import EnviousWisprCore
import Foundation

/// Known interruption message strings used to route .error state to .interruption overlay intent.
public enum InterruptionMessages {
  public static let micDisconnected = "Microphone disconnected"
}

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
  /// Transient warning notice for degraded-but-delivered results (e.g. polish failed).
  /// Orange icon, auto-dismissed by the overlay panel after 2.5 seconds.
  case warning(message: String)
  /// Transient error notice shown when ASR fails despite speech evidence.
  /// Auto-dismissed by the overlay panel after 3 seconds.
  case error(message: String)
  /// Transient interruption notice shown when the recording device disconnects.
  /// Distress lips (red pulse) with reason text, auto-dismissed after 2 seconds.
  case interruption(message: String)
}

/// Abstraction over dictation pipelines (Parakeet streaming, WhisperKit batch, etc.).
/// Each pipeline owns its own state machine and emits `OverlayIntent` for UI.
@MainActor
public protocol DictationPipeline: AnyObject {
  var overlayIntent: OverlayIntent { get }
  func handle(event: PipelineEvent) async
}

/// Issue #285 — heart-path telemetry callbacks that AppState routes to
/// whichever pipeline is currently recording. The underlying `AudioCapture*`
/// callback properties are single-owner on the shared capture instance, so
/// per-pipeline wiring would let the second-initialized pipeline steal them.
@MainActor
public protocol HeartPathTelemetryTarget: AnyObject {
  func handleCaptureStall(_ ctx: CaptureStallContext)
  func handleXPCReplyFailed(_ ctx: XPCReplyFailureContext)
  func handleCaptureSessionInterruption(_ ctx: CaptureSessionInterruptionContext)
}
