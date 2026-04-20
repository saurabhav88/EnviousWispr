import EnviousWisprCore
import Foundation

/// Known interruption message strings used to route .error state to .interruption overlay intent.
public enum InterruptionMessages {
  public static let micDisconnected = "Microphone disconnected"
}

/// Events that any dictation pipeline must handle.
public enum PipelineEvent: Sendable {
  case preWarm
  /// Toggle recording. Carries the per-recording configuration snapshot; pipelines
  /// consume the config on start transitions and ignore it on stop transitions.
  /// Settings mutated mid-recording apply to the next recording's snapshot.
  case toggleRecording(DictationSessionConfig)
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
  /// Issue #289: `.preWarm` may now throw if the audio input fails to
  /// start (XPC transport error, AVAudioEngine start refusal, etc.). Other
  /// events never throw today but the unified signature lets callers observe
  /// failures without a second protocol method.
  func handle(event: PipelineEvent) async throws
  /// Surface an error to the pipeline from outside (e.g. `AppState` after
  /// `handle(.preWarm)` threw). Intentionally dumb: sets `state = .error(msg)`
  /// and clears transient state. No retry scheduling, no transition logic.
  func setExternalError(_ message: String)

  /// Issue #289: invalidate any pending stall-recovery cleanup token so a
  /// deferred `finishStallRecovery` won't call `stopCapture()` on a session
  /// this pipeline no longer owns. Called by `PipelineSettingsSync` on
  /// backend switch — the deactivating pipeline may still hold a token for a
  /// pre-switch stall, and the shared `AudioCaptureInterface.currentCaptureSessionID`
  /// doesn't advance until the other pipeline reaches `beginCapturePhase()`.
  func clearPendingStallRecovery()
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
