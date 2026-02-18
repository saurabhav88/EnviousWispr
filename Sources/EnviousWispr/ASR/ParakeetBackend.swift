import AVFoundation
@preconcurrency import FluidAudio

/// Parakeet v3 ASR backend using FluidAudio/CoreML.
///
/// This is the primary (default) backend. Parakeet v3 provides:
/// - ~110x real-time factor on Apple Silicon
/// - Built-in punctuation and capitalization
/// - 25 European language support
actor ParakeetBackend: ASRBackend {
    private(set) var isReady = false

    private var fluidAsrManager: AsrManager?
    private var fluidModels: AsrModels?

    func prepare() async throws {
        let loadedModels = try await AsrModels.downloadAndLoad(version: .v3)
        self.fluidModels = loadedModels

        let manager = AsrManager(config: .default)
        try await manager.initialize(models: loadedModels)
        self.fluidAsrManager = manager

        isReady = true
    }

    func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady, let manager = fluidAsrManager else { throw ASRError.notReady }

        let startTime = CFAbsoluteTimeGetCurrent()
        // fluidResult type is inferred from AsrManager.transcribe() return type
        let fluidResult = try await manager.transcribe(audioURL, source: .system)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        let segments: [TranscriptSegment] = fluidResult.tokenTimings?.compactMap { timing in
            TranscriptSegment(
                text: timing.token,
                startTime: Float(timing.startTime),
                endTime: Float(timing.endTime)
            )
        } ?? []

        // Unqualified ASRResult resolves to our module's type (has backendType parameter)
        return ASRResult(
            text: fluidResult.text,
            segments: segments,
            language: "en",
            duration: fluidResult.duration,
            processingTime: elapsed,
            confidence: fluidResult.confidence,
            backendType: .parakeet
        )
    }

    func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady, let manager = fluidAsrManager else { throw ASRError.notReady }

        let startTime = CFAbsoluteTimeGetCurrent()
        let fluidResult = try await manager.transcribe(audioSamples, source: .microphone)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        let segments: [TranscriptSegment] = fluidResult.tokenTimings?.compactMap { timing in
            TranscriptSegment(
                text: timing.token,
                startTime: Float(timing.startTime),
                endTime: Float(timing.endTime)
            )
        } ?? []

        return ASRResult(
            text: fluidResult.text,
            segments: segments,
            language: "en",
            duration: fluidResult.duration,
            processingTime: elapsed,
            confidence: fluidResult.confidence,
            backendType: .parakeet
        )
    }

    func unload() async {
        fluidAsrManager?.cleanup()
        fluidAsrManager = nil
        fluidModels = nil
        isReady = false
    }
}
