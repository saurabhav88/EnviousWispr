import Foundation
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
actor WhisperKitBackend: ASRBackend {
    private(set) var isReady = false

    private let modelVariant: String
    private var whisperKit: WhisperKit?

    init(modelVariant: String = "openai_whisper-large-v3_turbo") {
        self.modelVariant = modelVariant
    }

    func prepare() async throws {
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

    func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady, let kit = whisperKit else { throw ASRError.notReady }

        let decodeOptions = makeDecodeOptions(from: options)
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

    func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady, let kit = whisperKit else { throw ASRError.notReady }

        let decodeOptions = makeDecodeOptions(from: options)
        let startTime = CFAbsoluteTimeGetCurrent()
        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(audioArray: audioSamples, decodeOptions: decodeOptions)
        } catch {
            throw ASRError.transcriptionFailed(error.localizedDescription)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        return mapResults(results, processingTime: elapsed)
    }

    func unload() async {
        whisperKit = nil
        isReady = false
    }

    // MARK: - Private

    private func makeDecodeOptions(from options: TranscriptionOptions) -> DecodingOptions {
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

        return opts
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
