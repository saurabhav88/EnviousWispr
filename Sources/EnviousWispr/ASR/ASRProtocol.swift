import AVFoundation

/// Information about an ASR model and its capabilities.
struct ASRModelInfo: Sendable {
    let name: String
    let backendType: ASRBackendType
    let modelSize: String
    let supportedLanguages: [String]
    let supportsStreaming: Bool
    let hasBuiltInPunctuation: Bool
}

/// Unified protocol for all ASR backends.
///
/// Both WhisperKit and Parakeet/FluidAudio conform to this protocol,
/// enabling seamless backend switching at runtime.
protocol ASRBackend: Actor {
    /// Whether the backend is initialized and ready to transcribe.
    var isReady: Bool { get }

    /// Metadata about the loaded model.
    func modelInfo() -> ASRModelInfo

    /// Load/initialize the model. Call once before transcription.
    func prepare() async throws

    /// Batch transcription from a file URL.
    func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> ASRResult

    /// Batch transcription from raw Float32 samples (16kHz mono).
    func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult

    /// Whether this backend supports streaming partial results.
    var supportsStreamingPartials: Bool { get }

    /// Stream partial transcripts from a continuous audio feed.
    func transcribeStream(
        audioBufferStream: AsyncStream<AVAudioPCMBuffer>,
        options: TranscriptionOptions
    ) -> AsyncStream<PartialTranscript>

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
