import Foundation
import EnviousWisprCore
@preconcurrency import WhisperKit

/// Hardcoded compute options optimized for Apple Silicon dictation.
/// Audio encoder + text decoder → Neural Engine, mel spectrogram → GPU, prefill → CPU only.
private let dictationComputeOptions = ModelComputeOptions(
    melCompute: .cpuAndGPU,
    audioEncoderCompute: .cpuAndNeuralEngine,
    textDecoderCompute: .cpuAndNeuralEngine,
    prefillCompute: .cpuOnly
)

/// WhisperKit ASR backend — broad language support with hardcoded dictation-optimized quality.
///
/// Uses Argmax WhisperKit SPM for Whisper-based speech recognition.
/// Decoding options and compute hardware allocation are hardcoded for optimal
/// dictation accuracy on Apple Silicon (Neural Engine for encoder/decoder).
///
/// The model must be downloaded via WhisperKitSetupService before calling prepare().
public actor WhisperKitBackend: ASRBackend {
    public private(set) var isReady = false

    private let modelVariant: String
    private var whisperKit: WhisperKit?

    /// Exposes the WhisperKit instance for background incremental transcription.
    public var whisperKitInstance: WhisperKit? { whisperKit }

    /// Exposes the tokenizer for prompt token encoding (used by incremental worker tail decode).
    public var whisperKitTokenizer: (any WhisperTokenizer)? { whisperKit?.tokenizer }

    // BRAIN: gotcha id=default-model-turbo
    public init(modelVariant: String = "openai_whisper-large-v3_turbo") {
        self.modelVariant = modelVariant
    }

    public func prepare() async throws {
        guard !isReady else { return }  // Idempotent — skip if already loaded

        // Use cached model path from WhisperKitSetupService (no network call).
        // Falls back to WhisperKit.download() if path not found (handles edge cases).
        let modelPath: String
        if let cached = WhisperKitSetupService.getLocalModelPath(variant: modelVariant) {
            modelPath = cached
        } else {
            let folder = try await WhisperKit.download(variant: modelVariant, progressCallback: nil)
            modelPath = folder.path
        }

        let config = WhisperKitConfig(
            model: modelVariant,
            modelFolder: modelPath,
            computeOptions: dictationComputeOptions,
            download: false
        )
        let kit = try await WhisperKit(config)
        self.whisperKit = kit
        isReady = true
    }

    public func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady, let kit = whisperKit else { throw ASRError.notReady }

        let decodeOptions = makeDecodeOptions(from: options, sampleCount: 0)
        let startTime = CFAbsoluteTimeGetCurrent()
        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: decodeOptions)
        } catch {
            throw ASRError.transcriptionFailed(error.localizedDescription)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        return mapResults(results, processingTime: elapsed)
    }

    public func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady, let kit = whisperKit else { throw ASRError.notReady }

        let paddedSamples = Self.padAudioWithSilence(audioSamples)
        let decodeOptions = makeDecodeOptions(from: options, sampleCount: paddedSamples.count)
        let startTime = CFAbsoluteTimeGetCurrent()
        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(audioArray: paddedSamples, decodeOptions: decodeOptions)
        } catch {
            throw ASRError.transcriptionFailed(error.localizedDescription)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        return mapResults(results, processingTime: elapsed)
    }

    public func unload() async {
        whisperKit = nil
        isReady = false
    }

    // MARK: - Private

    public func makeDecodeOptions(from options: TranscriptionOptions, sampleCount: Int) -> DecodingOptions {
        var opts = DecodingOptions()

        // Shared options (from TranscriptionOptions)
        opts.language = options.language
        opts.wordTimestamps = options.enableTimestamps

        // Hardcoded dictation-optimized defaults
        opts.temperature = 0.0
        opts.temperatureFallbackCount = 3
        opts.temperatureIncrementOnFallback = 0.2
        opts.compressionRatioThreshold = 2.4
        opts.logProbThreshold = -1.0
        opts.noSpeechThreshold = 0.6
        opts.skipSpecialTokens = true
        opts.suppressBlank = true
        opts.usePrefillPrompt = true
        opts.usePrefillCache = true

        // Use VAD chunking for long recordings to prevent hallucinated repetitions
        let thirtySeconds = 16000 * 30  // 480_000 samples
        // BRAIN: gotcha id=vad-chunking-30s
        opts.chunkingStrategy = sampleCount > thirtySeconds ? .vad : ChunkingStrategy.none

        // Disable windowClipTime (default 1.0s) which skips the last 1s of audio.
        // We pad audio with silence instead, which provides the look-ahead context
        // the decoder needs without sacrificing real content.
        // BRAIN: gotcha id=window-clip-time-zero
        opts.windowClipTime = 0

        return opts
    }

    /// Pads audio with trailing silence so the Whisper decoder has look-ahead context
    /// at the end of speech. Without this, abruptly-ending audio loses the last 1-3 words.
    // BRAIN: gotcha id=silence-padding
    private static let silencePaddingSamples = Int(0.5 * 16000)  // 500ms at 16kHz

    public static func padAudioWithSilence(_ samples: [Float]) -> [Float] {
        var padded = samples
        padded.append(contentsOf: [Float](repeating: 0, count: silencePaddingSamples))
        return padded
    }

    private func mapResults(_ results: [TranscriptionResult], processingTime: TimeInterval) -> ASRResult {
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let language = results.first?.language

        let duration: TimeInterval = if let lastSeg = results.last?.segments.last {
            TimeInterval(lastSeg.end)
        } else {
            0
        }

        return ASRResult(
            text: text,
            language: language,
            duration: duration,
            processingTime: processingTime,
            backendType: .whisperKit
        )
    }
}
