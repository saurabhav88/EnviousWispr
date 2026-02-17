import AVFoundation
import FluidAudio

/// Parakeet v3 ASR backend using FluidAudio/CoreML.
///
/// This is the primary (default) backend. Parakeet v3 provides:
/// - ~110x real-time factor on Apple Silicon
/// - Built-in punctuation and capitalization
/// - 25 European language support
actor ParakeetBackend: ASRBackend {
    private(set) var isReady = false
    let supportsStreamingPartials = false // TODO: Add EOU streaming in M2

    func modelInfo() -> ASRModelInfo {
        ASRModelInfo(
            name: "Parakeet TDT v3",
            backendType: .parakeet,
            modelSize: "~600MB",
            supportedLanguages: ["en", "de", "fr", "es", "it", "pt", "nl", "pl", "sv", "da",
                                  "no", "fi", "cs", "sk", "ro", "hu", "bg", "hr", "sl", "uk",
                                  "el", "lt", "lv", "et", "ca"],
            supportsStreaming: false,
            hasBuiltInPunctuation: true
        )
    }

    func prepare() async throws {
        // TODO: M1 — Download and load CoreML model via FluidAudio
        // let models = try await AsrModels.downloadAndLoad(version: .v3)
        // asrManager = AsrManager(config: .default)
        // try await asrManager?.initialize(models: models)
        isReady = true
    }

    func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady else { throw ASRError.notReady }
        // TODO: M1 — Implement via FluidAudio asrManager.transcribe()
        return ASRResult(
            text: "[Parakeet transcription placeholder]",
            segments: [],
            language: "en",
            duration: 0,
            processingTime: 0,
            confidence: nil,
            backendType: .parakeet
        )
    }

    func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady else { throw ASRError.notReady }
        // TODO: M1 — Implement via FluidAudio asrManager.transcribe(samples)
        return ASRResult(
            text: "[Parakeet transcription placeholder]",
            segments: [],
            language: "en",
            duration: 0,
            processingTime: 0,
            confidence: nil,
            backendType: .parakeet
        )
    }

    func transcribeStream(
        audioBufferStream: AsyncStream<AVAudioPCMBuffer>,
        options: TranscriptionOptions
    ) -> AsyncStream<PartialTranscript> {
        // TODO: M2 — Implement via BatchEouAsrManager
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func unload() async {
        isReady = false
    }
}
