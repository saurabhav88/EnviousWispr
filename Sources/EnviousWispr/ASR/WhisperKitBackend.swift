@preconcurrency import AVFoundation
@preconcurrency import WhisperKit

/// WhisperKit ASR backend — broad language support with configurable quality.
///
/// Uses Argmax WhisperKit SPM for Whisper-based speech recognition.
/// Supports language auto-detection, temperature control, compression ratio
/// filtering, and configurable decoding thresholds for quality parity.
actor WhisperKitBackend: ASRBackend {
    private(set) var isReady = false

    private let modelVariant: String
    private var whisperKit: WhisperKit?

    init(modelVariant: String = "large-v3") {
        self.modelVariant = modelVariant
    }

    func prepare() async throws {
        let config = WhisperKitConfig(model: modelVariant)
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

        // Language: nil enables auto-detection
        decodeOptions.language = options.language

        // Timestamps
        decodeOptions.wordTimestamps = options.enableTimestamps

        // Quality parameters
        decodeOptions.temperature = options.temperature
        decodeOptions.compressionRatioThreshold = options.compressionRatioThreshold
        decodeOptions.logProbThreshold = options.logProbThreshold
        decodeOptions.noSpeechThreshold = options.noSpeechThreshold
        decodeOptions.skipSpecialTokens = options.skipSpecialTokens

        // Temperature fallback: retry with higher temperature if quality filters trigger
        if options.temperature < 0.5 {
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
