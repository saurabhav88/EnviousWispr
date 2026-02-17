import AVFoundation
@preconcurrency import WhisperKit

/// WhisperKit ASR backend — fallback for non-European languages.
///
/// Uses Argmax WhisperKit SPM for Whisper-based speech recognition.
/// Supports streaming via transcription callbacks.
actor WhisperKitBackend: ASRBackend {
    private(set) var isReady = false
    let supportsStreamingPartials = true

    private let modelVariant: String
    private var whisperKit: WhisperKit?

    init(modelVariant: String = "base") {
        self.modelVariant = modelVariant
    }

    func modelInfo() -> ASRModelInfo {
        ASRModelInfo(
            name: "WhisperKit (\(modelVariant))",
            backendType: .whisperKit,
            modelSize: modelVariant == "base" ? "~150MB" : "~1.5GB",
            supportedLanguages: ["en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr",
                                  "pl", "ca", "nl", "ar", "sv", "it", "id", "hi", "fi", "vi",
                                  "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no",
                                  "th", "ur", "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk"],
            supportsStreaming: true,
            hasBuiltInPunctuation: false
        )
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

    func transcribeStream(
        audioBufferStream: AsyncStream<AVAudioPCMBuffer>,
        options: TranscriptionOptions
    ) -> AsyncStream<PartialTranscript> {
        AsyncStream { continuation in
            Task {
                var accumulatedSamples: [Float] = []
                for await buffer in audioBufferStream {
                    guard let channelData = buffer.floatChannelData else { continue }
                    let frameCount = Int(buffer.frameLength)
                    let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
                    accumulatedSamples.append(contentsOf: samples)

                    // Transcribe accumulated audio periodically (every ~2 seconds)
                    let samplesPerChunk = Int(AudioCaptureManager.targetSampleRate) * 2
                    if accumulatedSamples.count >= samplesPerChunk {
                        if let kit = self.whisperKit {
                            let decodeOptions = self.makeDecodeOptions(from: options)
                            if let results = try? await kit.transcribe(
                                audioArray: accumulatedSamples,
                                decodeOptions: decodeOptions
                            ) {
                                let text = results.map(\.text).joined(separator: " ")
                                continuation.yield(PartialTranscript(text: text, isFinal: false))
                            }
                        }
                    }
                }

                // Final transcription
                if !accumulatedSamples.isEmpty, let kit = self.whisperKit {
                    let decodeOptions = self.makeDecodeOptions(from: options)
                    if let results = try? await kit.transcribe(
                        audioArray: accumulatedSamples,
                        decodeOptions: decodeOptions
                    ) {
                        let text = results.map(\.text).joined(separator: " ")
                        continuation.yield(PartialTranscript(text: text, isFinal: true))
                    }
                }
                continuation.finish()
            }
        }
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
