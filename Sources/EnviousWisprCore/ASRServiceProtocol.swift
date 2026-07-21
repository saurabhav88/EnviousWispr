import Foundation

/// XPC protocol: commands from host app to ASR service.
///
/// All parameters are @objc-compatible types only: Data, NSError, Bool, String, Int.
/// ASRResult crosses the boundary as Codable-encoded Data via PropertyListEncoder.
///
/// Methods are split into two categories:
/// - **Model lifecycle** (loadModel, unloadModel, getModelState): state management, replayed after crash.
/// - **Transcription** (transcribeSamples, startStreaming, feedAudioBuffer, etc.): require loaded model.
@objc public protocol ASRServiceProtocol {
  // MARK: - Diagnostics

  /// Connection health check. Triggers launchd to spawn the service.
  func ping(reply: @escaping (String) -> Void)

  // MARK: - Model Lifecycle

  /// Load the specified ASR backend.
  /// - Parameters:
  ///   - backendType: "parakeet" or "whisperKit"
  ///   - cacheOnly: #1348 Phase 2 — when true (delivery-managed Parakeet),
  ///     the service loads the host-admitted cache with FluidAudio's offline
  ///     switch armed and can NEVER download; a cache miss throws typed.
  ///     False preserves the legacy in-service download path bit-for-bit.
  ///   - reply: nil on success, NSError on failure.
  func loadModel(backendType: String, cacheOnly: Bool, reply: @escaping (NSError?) -> Void)

  /// Unload the current model and free memory.
  func unloadModel(reply: @escaping () -> Void)

  /// Query current model state: (isLoaded, isStreaming).
  func getModelState(reply: @escaping (Bool, Bool) -> Void)

  // MARK: - Batch Transcription

  /// Transcribe audio samples in batch mode.
  /// - Parameters:
  ///   - data: Raw Float32 PCM bytes (16kHz mono).
  ///   - sampleCount: Number of Float32 samples in data.
  ///   - language: ISO 639-1 language code, or empty string for auto-detect.
  ///   - enableTimestamps: Whether to generate word-level timestamps.
  ///   - speechSegmentsData: JSON-encoded [SpeechSegment], or nil when no VAD segments exist.
  ///   - reply: (Codable-encoded ASRResult as Data, or nil) + (NSError or nil).
  func transcribeSamples(
    _ data: Data, sampleCount: Int, language: String, enableTimestamps: Bool,
    speechSegmentsData: Data?,
    reply: @escaping (Data?, NSError?) -> Void)

  // MARK: - Streaming Transcription (Parakeet)

  /// Start a streaming ASR session.
  func startStreaming(
    operationID: String, language: String, enableTimestamps: Bool,
    reply: @escaping (NSError?) -> Void)

  /// Feed an audio buffer to the streaming session. Fire-and-forget — no reply.
  /// Transport format: raw Float32 bytes, non-interleaved mono, 16kHz.
  func feedAudioBuffer(_ data: Data, frameCount: Int)

  /// Finalize the streaming session and return the transcription result.
  func finalizeStreaming(reply: @escaping (Data?, NSError?) -> Void)

  /// Cancel the streaming session without producing a result.
  func cancelStreaming()

  // MARK: - Backend Capability

  /// Check whether the specified backend supports streaming transcription.
  func checkStreamingSupport(backendType: String, reply: @escaping (Bool) -> Void)

  #if DEBUG
    // MARK: - #1707 Phase 2: batch-decode fault oracle (shared-backend
    // overlap Live UAT, §3.2a-i). Arm/release cross XPC; the pre-release
    // query does NOT — XPC replies serialize behind a pending request (this
    // is exactly why `XPCOperationSignalFile` exists for progress queries),
    // so `BatchDecodeFaultController` reads `BatchDecodeFaultSnapshotFile`
    // directly instead of asking the service while a `transcribeSamples`
    // reply is held pending. Additive, absent from release builds.

    /// Arms a one-shot hold for the NEXT `transcribeSamples` call's real
    /// `manager.transcribe(...)` decode (`ParakeetBackend`). Reply fires
    /// once the arm has landed service-side (the acknowledged-arm barrier)
    /// — not once a call is actually held.
    func armBatchDecodeHold(trialID: String, reply: @escaping () -> Void)

    /// Releases a previously-armed hold, letting the held decode proceed.
    /// No-op (still calls reply) if no call is currently held under
    /// `trialID`.
    func releaseBatchDecode(trialID: String, reply: @escaping () -> Void)

    /// Clears all armed/held state, so a forgotten trial from one Live UAT
    /// scenario cannot leak into the next.
    func clearBatchDecodeFault(reply: @escaping () -> Void)
  #endif
}

/// XPC protocol: callbacks from ASR service to host app.
///
/// The ASR service is primarily request/response — crash detection is handled
/// via NSXPCConnection's interruptionHandler/invalidationHandler, not callbacks.
///
/// Note: XPC connections serialize ALL replies, so push-based progress callbacks
/// cannot be delivered while a long-running call (loadModel) is pending.
/// Download progress uses a shared temp file instead (ProgressFile).
@objc public protocol ASRServiceClientProtocol {
  // Currently empty — crash detection via connection handlers.
  // Progress uses ProgressFile (shared temp file) to bypass XPC reply serialization.
}
