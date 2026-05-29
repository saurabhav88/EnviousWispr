import EnviousWisprCore
import Foundation

// Pipeline vocabulary shared across the recording driver and its consumers:
// the event input (`PipelineEvent`), the UI output (`OverlayIntent`), the
// interruption message constants, and the heart-path telemetry-target protocol.
// The `DictationPipeline` driver protocol that once lived here was deleted in
// PR-9 of #827 — `KernelDictationDriver` is the single concrete driver and the
// App consumes it directly. `KernelOwnershipFreezeTests` keeps it deleted.

/// Known interruption message strings used to route .error state to .interruption overlay intent.
public enum InterruptionMessages {
  public static let micDisconnected = "Microphone disconnected"
}

/// Events the recording driver handles.
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
  /// Educational notice shown once-per-session when paste cascade falls back
  /// to clipboard because Accessibility permission is denied. Includes an
  /// inline Grant button. Auto-dismissed after about 6 seconds.
  case accessibilityToast
  /// Transient warning notice for degraded-but-delivered results (e.g. polish failed).
  /// Orange icon, auto-dismissed by the overlay panel after 2.5 seconds.
  case warning(message: String)
  /// Transient error notice shown when ASR fails despite speech evidence.
  /// Auto-dismissed by the overlay panel after 3 seconds.
  case error(message: String)
  /// Transient interruption notice shown when the recording device disconnects.
  /// Distress lips (red pulse) with reason text, auto-dismissed after 2 seconds.
  case interruption(message: String)
  /// Passive language-lock discoverability chip surfaced post-dictation when the
  /// detector observed N consecutive high-confidence accepts of the same non-English
  /// language. Renders State A (strikes 1+2: Lock + Dismiss) or State B (strike 3:
  /// Dismiss only with Settings copy). Auto-dismissed after 6 seconds; pauses on hover.
  case passiveChip(payload: LanguageChipPayload)
}

/// Issue #285 — heart-path telemetry callbacks that the former root state routes to
/// whichever pipeline is currently recording. The underlying `AudioCapture*`
/// callback properties are single-owner on the shared capture instance, so
/// per-pipeline wiring would let the second-initialized pipeline steal them.
@MainActor
public protocol HeartPathTelemetryTarget: AnyObject {
  func handleCaptureStall(_ ctx: CaptureStallContext)
  func handleXPCReplyFailed(_ ctx: XPCReplyFailureContext)
  func handleCaptureSessionInterruption(_ ctx: CaptureSessionInterruptionContext)
}
