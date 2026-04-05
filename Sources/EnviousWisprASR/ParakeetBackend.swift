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
    private var streamingManager: SlidingWindowAsrManager?
    private var streamingStartTime: CFAbsoluteTime = 0

    public var supportsStreaming: Bool { true }

    public init() {}

    /// Progress callback type: (fractionCompleted, phaseString, detailString)
    public typealias ProgressCallback = @Sendable (Double, String, String) -> Void

    public func prepare() async throws {
        try await prepare(progressCallback: nil)
    }

    /// Prepare with optional progress reporting.
    /// The callback is called from FluidAudio's download thread — caller must marshal to MainActor.
    ///
    /// FluidAudio's progress system:
    /// - `downloadRepo()` downloads ALL model files in one pass with byte-weighted progress.
    /// - `fractionCompleted` range: [0.0, 0.5] = download, [0.5, 1.0] = CoreML compilation.
    /// - `downloadRepo()` only fires on the first `loadModels()` call — subsequent calls find
    ///   files cached and skip. We map directly from FluidAudio's fraction.
    ///
    /// Stall detection and checksum verification are handled by StallTracker (lock-based,
    /// zero overhead on the download thread) and ModelDownloadManager.verifyChecksum().
    public func prepare(progressCallback: ProgressCallback?) async throws {
        let stallTracker = StallTracker(timeout: 20)

        let handler: DownloadUtils.ProgressHandler? = progressCallback.map { callback -> DownloadUtils.ProgressHandler in
            { progress in
                // Update stall tracker — lock-based, zero overhead on download thread
                stallTracker.recordProgress(fraction: progress.fractionCompleted)

                let phase: String
                let detail: String

                switch progress.phase {
                case .listing:
                    phase = "Preparing download..."
                    detail = ""
                case .downloading:
                    phase = "Downloading model files..."
                    // Raw download is ~23MB (CoreML source files). The 460MB on disk
                    // is from CoreML compilation which happens in the .compiling phase.
                    let downloadPct = min(progress.fractionCompleted * 2.0, 1.0)
                    let downloadedMB = Int(downloadPct * 23)
                    detail = "\(downloadedMB) MB of 23 MB (\(Int(downloadPct * 100))%)"
                case .compiling(let modelName):
                    phase = "Installing model..."
                    detail = modelName
                }
                callback(progress.fractionCompleted, phase, detail)
            }
        }

        let loadedModels = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: handler)
        self.fluidModels = loadedModels

        // Verify checksum if configured
        ModelDownloadManager.verifyChecksum()

        let manager = AsrManager(config: .default)
        try await manager.initialize(models: loadedModels)
        self.fluidAsrManager = manager

        isReady = true
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

        let config = SlidingWindowAsrConfig.streaming
        let manager = SlidingWindowAsrManager(config: config)
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
        defer { streamingManager = nil }

        let finalizeStart = CFAbsoluteTimeGetCurrent()
        let text = try await manager.finish()
        let finalizeEnd = CFAbsoluteTimeGetCurrent()

        let totalElapsed = finalizeEnd - streamingStartTime
        let finalizeElapsed = finalizeEnd - finalizeStart

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
        await fluidAsrManager?.cleanup()
        fluidAsrManager = nil
        fluidModels = nil
        isReady = false
    }
}
