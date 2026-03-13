@preconcurrency import AVFoundation
import EnviousWisprCore
@preconcurrency import FluidAudio

// Disambiguate from FluidAudio.ASRResult — we always mean our own type.
public typealias ASRResult = EnviousWisprCore.ASRResult

/// Parakeet v3 ASR backend using FluidAudio/CoreML.
///
/// This is the primary (default) backend. Parakeet v3 provides:
/// - ~110x real-time factor on Apple Silicon
/// - Built-in punctuation and capitalization
/// - 25 European language support
public actor ParakeetBackend: ASRBackend {
    public private(set) var isReady = false

    private var fluidAsrManager: AsrManager?
    private var fluidModels: AsrModels?

    // Streaming ASR state
    private var streamingManager: StreamingAsrManager?
    private var streamingStartTime: CFAbsoluteTime = 0

    public var supportsStreaming: Bool { true }

    public func prepare() async throws {
        let loadedModels = try await AsrModels.downloadAndLoad(version: .v3)
        self.fluidModels = loadedModels

        let manager = AsrManager(config: .default)
        try await manager.initialize(models: loadedModels)
        self.fluidAsrManager = manager

        isReady = true
    }

    public func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady, let manager = fluidAsrManager else { throw ASRError.notReady }

        let startTime = CFAbsoluteTimeGetCurrent()
        // fluidResult type is inferred from AsrManager.transcribe() return type
        let fluidResult = try await manager.transcribe(audioURL, source: .system)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        // Unqualified ASRResult resolves to our module's type (has backendType parameter)
        return ASRResult(
            text: fluidResult.text,
            language: "en",
            duration: fluidResult.duration,
            processingTime: elapsed,
            backendType: .parakeet
        )
    }

    public func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult {
        guard isReady, let manager = fluidAsrManager else { throw ASRError.notReady }

        let startTime = CFAbsoluteTimeGetCurrent()
        let fluidResult = try await manager.transcribe(audioSamples, source: .microphone)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        return ASRResult(
            text: fluidResult.text,
            language: "en",
            duration: fluidResult.duration,
            processingTime: elapsed,
            backendType: .parakeet
        )
    }

    // MARK: - Streaming ASR

    public func startStreaming(options: TranscriptionOptions) async throws {
        guard isReady, let models = fluidModels else { throw ASRError.notReady }

        // Cancel any existing streaming session before starting a new one.
        // Prevents double-session state where the old manager is leaked.
        if let existing = streamingManager {
            await existing.cancel()
            streamingManager = nil
        }

        let config = StreamingAsrConfig.streaming
        let manager = StreamingAsrManager(config: config)
        try await manager.start(models: models, source: .microphone)
        self.streamingManager = manager
        self.streamingStartTime = CFAbsoluteTimeGetCurrent()
    }

    public func feedAudio(_ buffer: AVAudioPCMBuffer) async throws {
        guard let manager = streamingManager else { throw ASRError.streamingNotSupported }
        await manager.streamAudio(buffer)
    }

    public func finalizeStreaming() async throws -> ASRResult {
        guard let manager = streamingManager else { throw ASRError.streamingNotSupported }

        let finalizeStart = CFAbsoluteTimeGetCurrent()
        let text = try await manager.finish()
        let finalizeEnd = CFAbsoluteTimeGetCurrent()

        let totalElapsed = finalizeEnd - streamingStartTime
        let finalizeElapsed = finalizeEnd - finalizeStart

        self.streamingManager = nil

        return ASRResult(
            text: text,
            language: "en",
            duration: totalElapsed,
            processingTime: finalizeElapsed,
            backendType: .parakeet
        )
    }

    public func cancelStreaming() async {
        if let manager = streamingManager {
            await manager.cancel()
            streamingManager = nil
        }
    }

    public func unload() async {
        if let streaming = streamingManager {
            await streaming.cancel()
            streamingManager = nil
        }
        fluidAsrManager?.cleanup()
        fluidAsrManager = nil
        fluidModels = nil
        isReady = false
    }
}
