@preconcurrency import AVFoundation
@preconcurrency import WhisperKit

/// WhisperKit-specific decoding configuration, separate from shared TranscriptionOptions.
/// Lives here so deleting WhisperKit files removes all WhisperKit-specific types cleanly.
struct WhisperKitDecodingConfig: Sendable, Equatable {
    var temperature: Float = 0.0
    var compressionRatioThreshold: Float = 2.4
    var logProbThreshold: Float = -1.0
    var noSpeechThreshold: Float = 0.6
    var skipSpecialTokens: Bool = true

    static let `default` = WhisperKitDecodingConfig()
}

/// WhisperKit ASR backend — broad language support with configurable quality.
///
/// Uses Argmax WhisperKit SPM for Whisper-based speech recognition.
/// Supports language auto-detection, temperature control, compression ratio
/// filtering, and configurable decoding thresholds for quality parity.
///
/// The model must be downloaded via WhisperKitSetupService before calling prepare().
actor WhisperKitBackend: ASRBackend {
    private(set) var isReady = false

    private let modelVariant: String
    private var whisperKit: WhisperKit?
    private(set) var decodingConfig: WhisperKitDecodingConfig = .default

    init(modelVariant: String = "large-v3") {
        self.modelVariant = modelVariant
    }

    /// Update decoding configuration. Safe to call while model is loaded.
    func updateDecodingConfig(_ config: WhisperKitDecodingConfig) {
        self.decodingConfig = config
    }

    func prepare() async throws {
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
        var decodeOptions = DecodingOptions()

        // Shared options (from TranscriptionOptions)
        decodeOptions.language = options.language
        decodeOptions.wordTimestamps = options.enableTimestamps

        // WhisperKit-specific quality parameters (from actor-local config)
        decodeOptions.temperature = decodingConfig.temperature
        decodeOptions.compressionRatioThreshold = decodingConfig.compressionRatioThreshold
        decodeOptions.logProbThreshold = decodingConfig.logProbThreshold
        decodeOptions.noSpeechThreshold = decodingConfig.noSpeechThreshold
        decodeOptions.skipSpecialTokens = decodingConfig.skipSpecialTokens

        // Temperature fallback: retry with higher temperature if quality filters trigger
        if decodingConfig.temperature < 0.5 {
            decodeOptions.temperatureFallbackCount = 3
            decodeOptions.temperatureIncrementOnFallback = 0.2
        }

        return decodeOptions
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
