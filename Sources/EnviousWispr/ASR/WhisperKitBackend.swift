import AVFoundation
@preconcurrency import WhisperKit

/// WhisperKit ASR backend — fallback for non-European languages.
///
/// Uses Argmax WhisperKit SPM for Whisper-based speech recognition.
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
        let results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: decodeOptions)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        return mapResults(results, processingTime: elapsed)
    }

    func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady, let kit = whisperKit else { throw ASRError.notReady }

        let decodeOptions = makeDecodeOptions(from: options)
        let startTime = CFAbsoluteTimeGetCurrent()
        let results = try await kit.transcribe(audioArray: audioSamples, decodeOptions: decodeOptions)
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
        decodeOptions.language = options.language ?? "en"
        decodeOptions.wordTimestamps = options.enableTimestamps
        return decodeOptions
    }

    private func mapResults(_ results: [TranscriptionResult], processingTime: TimeInterval) -> ASRResult {
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let language = results.first?.language

        let segments: [TranscriptSegment] = results.flatMap { result in
            result.segments.map { seg in
                TranscriptSegment(
                    text: seg.text,
                    startTime: seg.start,
                    endTime: seg.end
                )
            }
        }

        let duration: TimeInterval = if let lastSeg = results.last?.segments.last {
            TimeInterval(lastSeg.end)
        } else {
            0
        }

        return ASRResult(
            text: text,
            segments: segments,
            language: language,
            duration: duration,
            processingTime: processingTime,
            confidence: nil,
            backendType: .whisperKit
        )
    }
}
