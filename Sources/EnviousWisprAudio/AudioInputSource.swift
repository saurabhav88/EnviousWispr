@preconcurrency import AVFoundation
import EnviousWisprCore

/// Internal abstraction over audio capture sources.
///
/// One conformer:
/// - `HALDeviceInputSource`: low-level HAL AUHAL device input, the sole backend.
///
/// `AudioCaptureManager` picks the source via `CaptureRouteResolver` and delegates
/// all hardware interaction to it. The manager owns app-facing state (capturedSamples,
/// audioLevel, isCapturing); sources own hardware/session/engine lifecycle.
@MainActor
protocol AudioInputSource: AnyObject {
  // Callbacks — set by AudioCaptureManager before start
  var onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)? { get set }
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
  /// #1408: the source names WHY capture stopped. It is the only layer that can:
  /// only the source knows whether it ran the `kAudioDevicePropertyDeviceIsAlive`
  /// check and saw the device gone, versus whether its engine simply failed to
  /// recover with the device still attached. The manager used to infer this from
  /// the source's CLASS, which cannot tell those two apart.
  var onInterrupted: ((EngineInterruptionCause) -> Void)? { get set }
  var onLifecycleSignal: (@Sendable (String) -> Void)? { get set }

  /// Liveness-watchdog callback — fires once per capture session if zero
  /// buffers are delivered within `Constants.audioCaptureStallWindowMs` of
  /// tap install. Set by `AudioCaptureManager` on every `resolveSource()`.
  /// Source must cancel any pending watchdog on `stop()` / `deactivateCapture()`.
  var onCaptureStalled: ((CaptureStallContext) -> Void)? { get set }

  /// Monotonic capture-session id. Increments inside `startCapture`.
  /// Zero if no session has started. Used for watchdog generation check +
  /// dedup correlation at the pipeline layer.
  var captureGeneration: UInt64 { get }

  /// Low-cardinality tag naming the concrete capture backend
  /// (`"hal_device_input"`). Surfaced via `AudioCaptureManager.captureSourceType`
  /// for pipeline Sentry extras.
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

  // Engine-specific (no-op for HALDeviceInputSource)
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool
  func abortPrepare()
  func rebuild()

  #if DEBUG
    /// #1317 proof-bench: DEBUG-only all-zero injector, assigned by
    /// `AudioCaptureManager` on every new-source installation before `prepare()`
    /// can construct a forwarder. Each conformer stores it and passes it into every
    /// `PreRollForwarder` it creates. Declared as a REQUIREMENT (no default) so the
    /// compiler forces every conformer to participate — a newly-added source cannot
    /// silently bypass the injector. Compiled out of release.
    var debugZeroFillController: DebugZeroFillController? { get set }
  #endif

  /// #1434: stop-time capture-health facts (native rate, drop/error counters,
  /// divergence flag) the manager attaches to `CaptureResult.metadata`.
  /// Declared as a REQUIREMENT (not extension-only) so existential calls
  /// dispatch to the conformer, with a nil default below for sources that
  /// don't track capture health. Synchronous computed property with identical
  /// sync witnesses — not the async-default trap (`swift-patterns.md` RULE:
  /// no-sync-witness-with-defaulted-async-protocol-method).
  var captureStopMetadata: CaptureStopMetadata? { get }
}

extension AudioInputSource {
  var captureStopMetadata: CaptureStopMetadata? { nil }
}
