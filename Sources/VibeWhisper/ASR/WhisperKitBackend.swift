import AVFoundation
import WhisperKit

/// WhisperKit ASR backend (fallback).
///
/// Provides broader language support (99+) and multiple model sizes.
/// Used when Parakeet doesn't support the target language.
actor WhisperKitBackend: ASRBackend {
    private(set) var isReady = false
    let supportsStreamingPartials = true

    private let modelVariant: String

    init(modelVariant: String = "base") {
        self.modelVariant = modelVariant
    }

    func modelInfo() -> ASRModelInfo {
        ASRModelInfo(
            name: "WhisperKit \(modelVariant)",
            backendType: .whisperKit,
            modelSize: modelVariant == "base" ? "~140MB" : "varies",
            supportedLanguages: ["en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt"],
            supportsStreaming: true,
            hasBuiltInPunctuation: false
        )
    }

    func prepare() async throws {
        // TODO: M2 — Download and load WhisperKit model
        // let config = WhisperKitConfig(model: modelVariant)
        // whisperKit = try await WhisperKit(config)
        isReady = true
    }

    func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady else { throw ASRError.notReady }
        // TODO: M2 — Implement via WhisperKit
        return ASRResult(
            text: "[WhisperKit transcription placeholder]",
            segments: [],
            language: "en",
            duration: 0,
            processingTime: 0,
            confidence: nil,
            backendType: .whisperKit
        )
    }

    func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady else { throw ASRError.notReady }
        // TODO: M2 — Implement via WhisperKit
        return ASRResult(
            text: "[WhisperKit transcription placeholder]",
            segments: [],
            language: "en",
            duration: 0,
            processingTime: 0,
            confidence: nil,
            backendType: .whisperKit
        )
    }

    func transcribeStream(
        audioBufferStream: AsyncStream<AVAudioPCMBuffer>,
        options: TranscriptionOptions
    ) -> AsyncStream<PartialTranscript> {
        // TODO: M2 — Implement streaming via WhisperKit callback
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func unload() async {
        isReady = false
    }
}
