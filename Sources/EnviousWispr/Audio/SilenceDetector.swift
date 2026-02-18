import Foundation
@preconcurrency import FluidAudio

/// Monitors audio for speech activity and detects silence after speech for auto-stop.
///
/// Uses FluidAudio's Silero VAD model for real-time voice activity detection.
/// Processes 4096-sample chunks (256ms at 16kHz) and tracks speech→silence transitions.
actor SilenceDetector {
    private var vadManager: VadManager?
    private var streamState: VadStreamState = .initial()
    private(set) var speechDetected = false
    private(set) var isReady = false

    let silenceTimeout: TimeInterval

    /// Chunk size expected by the Silero VAD model (256ms at 16kHz).
    nonisolated static let chunkSize = 4096

    init(silenceTimeout: TimeInterval = 1.5) {
        self.silenceTimeout = silenceTimeout
    }

    /// Load the Silero VAD model. Call once before processing.
    func prepare() async throws {
        guard !isReady else { return }
        let config = VadConfig(defaultThreshold: 0.5)
        vadManager = try await VadManager(config: config)
        isReady = true
    }

    /// Reset streaming state for a new recording session.
    func reset() {
        streamState = .initial()
        speechDetected = false
    }

    /// Process a chunk of 4096 audio samples (16kHz mono).
    /// Returns `true` if silence after speech is detected (auto-stop should trigger).
    func processChunk(_ samples: [Float]) async -> Bool {
        guard let vad = vadManager else { return false }

        let segConfig = VadSegmentationConfig(
            minSpeechDuration: 0.3,
            minSilenceDuration: silenceTimeout,
            speechPadding: 0.1
        )

        guard let result = try? await vad.processStreamingChunk(
            samples,
            state: streamState,
            config: segConfig
        ) else { return false }

        streamState = result.state

        if let event = result.event {
            if event.isStart { speechDetected = true }
            if event.isEnd && speechDetected { return true }
        }

        return false
    }

    /// Release the VAD model from memory.
    func unload() {
        vadManager = nil
        isReady = false
        reset()
    }
}
