@preconcurrency import AVFoundation
import CoreAudio
import EnviousWisprCore

/// Abstraction over audio capture — enables swapping between in-process and XPC implementations.
@MainActor
public protocol AudioCaptureInterface: AnyObject {
  // Observable state (read-only externally)
  // periphery:ignore - protocol requirement; prod reads concrete impls
  var isCapturing: Bool { get }
  var audioLevel: Float { get }
  var capturedSamples: [Float] { get }
  /// Low-cardinality audio route label for Sentry. Set after route resolution.
  var currentAudioRoute: String { get }

  // Callback properties (read-write)
  var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
  /// Fires when a live recording is lost to an audio-engine interruption. The
  /// `EngineInterruptionCause` lets the consumer route the lost-dictation
  /// capture for `.engineLost` only, suppressing the three already-owned causes
  /// (issue #1174 A3).
  var onEngineInterrupted: ((EngineInterruptionCause) -> Void)? { get set }
  var onVADAutoStop: (() -> Void)? { get set }

  // Telemetry callbacks (round-4 additions for #285 heart-path Sentry coverage).
  // Producers: source backends (`AVAudioEngineSource`, `AVCaptureSessionSource`,
  //            `AudioCaptureProxy`). Consumers: pipeline layer + the former root state.
  // All callbacks fire on the MainActor. Conformers that don't produce a given
  // signal leave the closure nil (e.g. direct sources leave XPC callbacks nil).

  /// Fires once per capture session when the liveness watchdog observes zero
  /// audio buffers within `Constants.audioCaptureStallWindowMs` of tap install.
  /// At most one call per `currentCaptureSessionID`. Never called after a
  /// subsequent `stopCapture` for that session. Telemetry-only: consumers
  /// must not treat this as a control-flow signal.
  var onCaptureStalled: ((CaptureStallContext) -> Void)? { get set }

  /// Fires on `AVCaptureSessionWasInterrupted` / `AVCaptureSessionRuntimeError`
  /// notifications from `AVCaptureSessionSource`. Carries the diagnostic
  /// payload (interruption reason, runtime NSError) that the notification
  /// userInfo would otherwise drop. Non-BT sources leave nil.
  var onCaptureSessionInterruption: ((CaptureSessionInterruptionContext) -> Void)? { get set }

  /// Fires from the proxy's XPC interruption / invalidation handlers.
  /// Direct sources have no XPC layer and leave nil. Consumer emits
  /// `captureError(.xpcServiceError)`. Idle interrupts do NOT invoke (silent
  /// end-to-end per §3.5 Channel 2 in the round-4 plan).
  var onXPCServiceError: ((XPCErrorContext) -> Void)? { get set }

  /// Fires when a non-throwing XPC call (`stopCapture`, `getSamplesSnapshot`,
  /// `getSpeechSegments`) swallowed a transport error in its internal catch
  /// block. The proxy invokes the callback BEFORE returning its empty default
  /// so the pipeline can emit the correct root cause instead of misrouting
  /// into "no_audio_captured".
  var onXPCReplyFailed: ((XPCReplyFailureContext) -> Void)? { get set }

  /// Fires on the first route resolution and on every subsequent resolution
  /// where sourceType or reason differs from the prior call. No-op on
  /// warm-reuse resolutions that produce the same decision.
  // periphery:ignore - planned route telemetry API (producers wired, consumer pending)
  var onRouteResolved: ((CaptureRouteDecision, _ sourceTypeChanged: Bool) -> Void)? { get set }

  /// Monotonic per-source identifier for the active capture session.
  /// Increments on every `startCapture` / `beginCapturePhase`. Zero if no
  /// session has started yet. Pipeline uses for correlation extras +
  /// dedup-claim keying. Never persisted; not meaningful across launches.
  var currentCaptureSessionID: UInt64 { get }

  /// Authoritative "is a capture session in-flight right now." Backed by
  /// source/proxy internal state (not pipeline UI state which lags at
  /// start/stop boundaries). Used as the telemetry gate for XPC interrupt
  /// classification.
  var isActivelyCapturing: Bool { get }

  /// Low-cardinality string identifying the concrete capture backend driving
  /// the current session. Values: `"av_audio_engine"`, `"av_capture_session"`,
  /// `"xpc_proxy"`. Used by pipeline-layer Sentry extras so BT-direct sessions
  /// (AVCaptureSession) are not mislabeled as AVAudioEngine. Delegates to the
  /// active source in direct mode; constant for the proxy.
  var captureSourceType: String { get }

  // Configuration properties (read-write)
  var noiseSuppressionEnabled: Bool { get set }
  var selectedInputDeviceUID: String { get set }
  var preferredInputDeviceIDOverride: String { get set }
  var warmEnginePolicy: WarmEnginePolicy { get set }

  // Core lifecycle
  func startEnginePhase() async throws
  /// `recoveryPayload` is an opaque encoded `RecoverySpoolDirective` the recording
  /// kernel forwards to arm the crash-recovery limb (#1063 PR1); nil ⇒ no spool.
  /// Every caller except the kernel uses the no-arg `beginCapturePhase()`
  /// convenience in the extension below.
  func beginCapturePhase(recoveryPayload: Data?) async throws -> AsyncStream<AVAudioPCMBuffer>
  func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer>  // periphery:ignore - convenience method combining engine + capture phases
  func stopCapture() async -> CaptureResult
  func rebuildEngine()
  func buildEngine(noiseSuppression: Bool)
  func preWarm() async throws
  func abortPreWarm()
  func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool

  // VAD (Step 5)
  func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool)
  // periphery:ignore - XPC capture contract (invoked via NSXPC proxy)
  func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int)
  // periphery:ignore - XPC capture contract (invoked via NSXPC proxy)
  func getVADSegments() async -> [SpeechSegment]
}

extension AudioCaptureInterface {
  /// Begin capture without arming crash recovery — the default for every caller
  /// except the recording kernel (which forwards the session's recovery
  /// directive). Keeps all existing no-arg call sites source-compatible after
  /// the `recoveryPayload:` requirement was added (#1063 PR1). Public so
  /// cross-module existential callers (kernel, app shell, tests) resolve it.
  public func beginCapturePhase() async throws -> AsyncStream<AVAudioPCMBuffer> {
    try await beginCapturePhase(recoveryPayload: nil)
  }
}
