import Foundation

/// XPC protocol: commands from host app to audio service.
///
/// All parameters are @objc-compatible types only: Data, NSError, Bool, Float, Double, String, Int.
/// Audio samples cross as Data (raw Float32 bytes). The proxy converts Data↔[Float] at the boundary.
///
/// Methods are split into two categories:
/// - **Configuration** (buildEngine, set*): state setters, replayed by proxy after crash reinit.
/// - **Lifecycle** (start*, beginCapture, stopCapture, etc.): control flow, require config first.
@objc public protocol AudioServiceProtocol {
  // MARK: - Diagnostics (Steps 1-2)

  /// Connection health check.
  func ping(reply: @escaping (String) -> Void)

  /// Report current microphone authorization status as seen by the XPC service process.
  func checkMicPermission(reply: @escaping (Int, String) -> Void)

  // MARK: - Configuration (Step 3)

  /// Build/rebuild the audio engine with noise suppression configuration.
  /// Replayed by the proxy after service crash via resendConfigIfNeeded().
  func buildEngine(noiseSuppression: Bool)

  /// Update noise suppression setting on the existing engine.
  func setNoiseSuppressionEnabled(_ enabled: Bool)

  /// Set the preferred input device UID (user's explicit choice). Empty = auto.
  func setPreferredInputDeviceUID(_ uid: String)

  /// Set the selected input device UID (legacy path). Empty = system default.
  func setSelectedInputDeviceUID(_ uid: String)

  /// Set the warm engine policy. Raw value of WarmEnginePolicy enum.
  /// Replayed by the proxy after service crash via resendConfigIfNeeded().
  func setWarmEnginePolicy(_ rawValue: String)

  // MARK: - Lifecycle (Step 3)

  /// Phase 1: start the audio engine, trigger BT codec switch, register config-change observer.
  /// Device UIDs are passed inline so the proxy doesn't need separate setter replay before this call.
  func startEnginePhase(
    operationID: String, preferredDeviceUID: String, selectedDeviceUID: String,
    reply: @escaping (NSError?) -> Void)

  /// Poll engine format until stable after BT codec negotiation.
  func waitForFormatStabilization(
    maxWait: Double, pollInterval: Double, reply: @escaping (Bool) -> Void)

  /// Phase 2: install audio tap and begin capture. Buffers flow back via audioBufferCaptured callback.
  /// `recoveryPayload` is an opaque encoded `RecoverySpoolDirective` (Data only — this is an `@objc`
  /// protocol) the host hands the helper to arm the crash-recovery limb; nil ⇒ no spool, behaves as today.
  func beginCapture(
    operationID: String, recoveryPayload: Data?, reply: @escaping (NSError?) -> Void)

  /// Stop capture and return accumulated samples + finalized VAD segments atomically.
  /// First Data = raw Float32 sample bytes. Second Data = packed [Int32 start, Int32 end] VAD segment pairs.
  /// VAD segments are finalized BEFORE the sample buffer is cleared, preventing the call-order bug
  /// where separate stopCapture/getVADSegments calls produced endSample=0 on open segments.
  func stopCapture(operationID: String, reply: @escaping (Data, Data) -> Void)

  /// Cancel a pre-warmed engine that never began capture.
  func abortPreWarm()

  /// Replace the audio engine with a fresh instance (lighter than buildEngine).
  func rebuildEngine()

  // MARK: - VAD (Step 5)

  /// Configure service-side VAD. Replayed by the proxy after service crash via resendConfigIfNeeded().
  func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool)

  /// Return a snapshot of captured samples starting at `fromIndex`.
  /// Reply carries raw Float32 Data slice + totalCount at snapshot moment.
  func getSamplesSnapshot(fromIndex: Int, reply: @escaping (Data, Int) -> Void)

  /// Return speech segments detected by service-side VAD.
  /// Reply carries Data of packed [Int32 startIndex, Int32 endIndex] pairs.
  func getVADSegments(reply: @escaping (Data) -> Void)
}

/// XPC protocol: callbacks from audio service to host app.
///
/// These callbacks arrive on an XPC dispatch queue (not the RT audio thread, not the main thread).
/// The proxy hops to @MainActor via Task before updating observable state.
@objc public protocol AudioServiceClientProtocol {
  /// Audio buffer captured — carries converted 16kHz mono Float32 PCM data.
  /// Transport format: raw Float32 bytes, non-interleaved mono, 16kHz sample rate.
  /// No header or metadata — just the raw sample bytes.
  func audioBufferCaptured(_ data: Data, frameCount: Int, audioLevel: Float)

  /// The audio engine was interrupted (device disconnect, emergency teardown, max-duration cap).
  /// The proxy should transition pipelines to error state.
  func engineInterrupted()

  /// Service-side VAD detected sustained silence after speech — auto-stop should trigger.
  func vadAutoStopTriggered()
}
