@preconcurrency import AVFoundation
import EnviousWisprCore

/// Internal abstraction over audio capture sources.
///
/// Two conformers:
/// - `AVAudioEngineSource`: existing AVAudioEngine tap path (supports voice processing)
/// - `AVCaptureSessionSource`: AVCaptureSession path (avoids BT A2DP→SCO switch)
///
/// `AudioCaptureManager` picks the source via `CaptureRouteResolver` and delegates
/// all hardware interaction to it. The manager owns app-facing state (capturedSamples,
/// audioLevel, isCapturing); sources own hardware/session/engine lifecycle.
@MainActor
protocol AudioInputSource: AnyObject {
  // Callbacks — set by AudioCaptureManager before start
  var onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)? { get set }
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
  var onInterrupted: (() -> Void)? { get set }
  var onLifecycleSignal: (@Sendable (String) -> Void)? { get set }

  /// Liveness-watchdog callback — fires once per capture session if zero
  /// buffers are delivered within `Constants.audioCaptureStallWindowMs` of
  /// tap install. Set by `AudioCaptureManager` on every `resolveSource()`.
  /// Source must cancel any pending watchdog on `stop()` / `deactivateCapture()`.
  var onCaptureStalled: ((CaptureStallContext) -> Void)? { get set }

  /// AVCaptureSession-specific: interruption / runtime-error telemetry.
  /// `AVAudioEngineSource` leaves nil (no AVCaptureSession layer).
  var onCaptureSessionInterruption: ((CaptureSessionInterruptionContext) -> Void)? { get set }

  /// Monotonic capture-session id. Increments inside `startCapture`.
  /// Zero if no session has started. Used for watchdog generation check +
  /// dedup correlation at the pipeline layer.
  var captureGeneration: UInt64 { get }

  /// Low-cardinality tag naming the concrete capture backend
  /// (`"av_audio_engine"` vs `"av_capture_session"`). Surfaced via
  /// `AudioCaptureManager.captureSourceType` so pipeline Sentry extras
  /// distinguish BT-direct (AVCaptureSession) from AVAudioEngine paths.
  var captureSourceType: String { get }

  // Lifecycle (mirrors AudioCaptureManager's two-phase start)
  func prepare() async throws
  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer>
  func stop() async -> [Float]

  /// Deactivate live capture but keep engine/session and tap warm.
  /// The forwarder returns to preRolling mode so the ring buffer continues
  /// capturing audio for instant first-word capture on next recording.
  /// Call stop() for full teardown.
  func deactivateCapture()

  // State
  var isCapturing: Bool { get }  // periphery:ignore - used by conformers for internal guards
  var isRunning: Bool { get }

  // Engine-specific (no-op for AVCaptureSessionSource)
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool
  func abortPrepare()
  func rebuild()
}
