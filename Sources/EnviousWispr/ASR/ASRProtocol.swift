import AVFoundation

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
}

/// Errors that can occur during ASR operations.
enum ASRError: LocalizedError, Sendable {
    case notReady
    case modelLoadFailed(String)
    case transcriptionFailed(String)
    case emptyResult
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .notReady: return "ASR backend is not ready. Call prepare() first."
        case .modelLoadFailed(let msg): return "Model loading failed: \(msg)"
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        case .emptyResult: return "Transcription returned an empty result."
        case .unsupportedFormat: return "Unsupported audio format."
        }
    }
}
