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

    /// Load the specified ASR backend and model variant.
    /// - Parameters:
    ///   - backendType: "parakeet" or "whisperKit"
    ///   - modelVariant: WhisperKit model name (e.g., "openai_whisper-large-v3_turbo"). Ignored for Parakeet.
    ///   - reply: nil on success, NSError on failure.
    func loadModel(backendType: String, modelVariant: String, reply: @escaping (NSError?) -> Void)

    /// Unload the current model and free memory.
    func unloadModel(reply: @escaping () -> Void)

    /// Query current model state: (isLoaded, isStreaming).
    func getModelState(reply: @escaping (Bool, Bool) -> Void)

    /// Poll current download progress. Returns (fractionCompleted, phase, detail).
    /// Called by the host app on a timer during model download.
    func getDownloadProgress(reply: @escaping (Double, String, String) -> Void)

    // MARK: - Batch Transcription

    /// Transcribe audio samples in batch mode.
    /// - Parameters:
    ///   - data: Raw Float32 PCM bytes (16kHz mono).
    ///   - sampleCount: Number of Float32 samples in data.
    ///   - language: ISO 639-1 language code, or empty string for auto-detect.
    ///   - enableTimestamps: Whether to generate word-level timestamps.
    ///   - reply: (Codable-encoded ASRResult as Data, or nil) + (NSError or nil).
    func transcribeSamples(_ data: Data, sampleCount: Int, language: String, enableTimestamps: Bool, reply: @escaping (Data?, NSError?) -> Void)

    // MARK: - Streaming Transcription (Parakeet)

    /// Start a streaming ASR session.
    func startStreaming(language: String, enableTimestamps: Bool, reply: @escaping (NSError?) -> Void)

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
}

/// XPC protocol: callbacks from ASR service to host app.
///
/// The ASR service is primarily request/response — crash detection is handled
/// via NSXPCConnection's interruptionHandler/invalidationHandler, not callbacks.
/// Used for push notifications from service → app (e.g., model download progress).
@objc public protocol ASRServiceClientProtocol {
    /// Reports model download progress from the ASR service to the host app.
    /// - Parameters:
    ///   - fractionCompleted: Overall progress in [0, 1].
    ///   - phase: Human-readable phase string (e.g., "listing", "downloading", "compiling").
    ///   - detail: Optional detail string (e.g., "150 MB of 460 MB" during downloading phase).
    func reportDownloadProgress(_ fractionCompleted: Double, phase: String, detail: String)
}
