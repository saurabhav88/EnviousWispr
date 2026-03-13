@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation

/// Unified protocol for all ASR backends.
///
/// Both WhisperKit and Parakeet/FluidAudio conform to this protocol,
/// enabling seamless backend switching at runtime.
protocol ASRBackend: Actor {
    /// Whether the backend is initialized and ready to transcribe.
    var isReady: Bool { get }

    /// Load/initialize the model. Call once before transcription.
    func prepare() async throws

    /// Batch transcription from a file URL.
    func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> ASRResult

    /// Batch transcription from raw Float32 samples (16kHz mono).
    func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult

    /// Release model resources.
    func unload() async

    // MARK: - Streaming ASR (optional)

    /// Whether this backend supports streaming transcription during recording.
    var supportsStreaming: Bool { get }

    /// Start streaming ASR session. Audio buffers will be fed via `feedAudio(_:)`.
    func startStreaming(options: TranscriptionOptions) async throws

    /// Feed an audio buffer to the streaming ASR session.
    func feedAudio(_ buffer: AVAudioPCMBuffer) async throws

    /// Finalize the streaming session and return the complete transcript.
    func finalizeStreaming() async throws -> ASRResult

    /// Cancel an active streaming session, discarding partial results.
    func cancelStreaming() async
}

/// Default implementations for optional protocol members.
extension ASRBackend {
    var supportsStreaming: Bool { false }

    func startStreaming(options: TranscriptionOptions) async throws {
        throw ASRError.streamingNotSupported
    }

    func feedAudio(_ buffer: AVAudioPCMBuffer) async throws {
        throw ASRError.streamingNotSupported
    }

    func finalizeStreaming() async throws -> ASRResult {
        throw ASRError.streamingNotSupported
    }

    func cancelStreaming() async {}
}

/// Errors that can occur during ASR operations.
enum ASRError: LocalizedError, Sendable {
    case notReady
    case streamingNotSupported
    case streamingTimeout
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady: return "ASR backend is not ready. Call prepare() first."
        case .streamingNotSupported: return "This ASR backend does not support streaming transcription."
        case .streamingTimeout: return "Streaming ASR finalization timed out."
        case .transcriptionFailed(let message): return "Transcription failed: \(message)"
        }
    }
}
