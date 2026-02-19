import Foundation
@preconcurrency import FluidAudio

struct SpeechSegment: Sendable {
    let startSample: Int
    let endSample: Int
}

/// Monitors audio for speech activity and detects silence after speech for auto-stop.
///
/// Uses FluidAudio's Silero VAD model for real-time voice activity detection.
/// Processes 4096-sample chunks (256ms at 16kHz) and tracks speech→silence transitions.
actor SilenceDetector {
    private var vadManager: VadManager?
    private var streamState: VadStreamState = .initial()
    private(set) var speechDetected = false
    private(set) var isReady = false
    private(set) var speechSegments: [SpeechSegment] = []
    private var currentSpeechStart: Int? = nil
    private var processedSampleCount: Int = 0

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
        speechSegments = []
        currentSpeechStart = nil
        processedSampleCount = 0
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
        ) else {
            processedSampleCount += samples.count
            return false
        }

        streamState = result.state

        var shouldAutoStop = false

        if let event = result.event {
            if event.isStart {
                speechDetected = true
                currentSpeechStart = processedSampleCount
            }
            if event.isEnd && speechDetected {
                if let start = currentSpeechStart {
                    speechSegments.append(SpeechSegment(
                        startSample: start,
                        endSample: processedSampleCount + samples.count
                    ))
                    currentSpeechStart = nil
                }
                shouldAutoStop = true
            }
        }

        processedSampleCount += samples.count

        return shouldAutoStop
    }

    func finalizeSegments(totalSampleCount: Int) {
        if let start = currentSpeechStart {
            speechSegments.append(SpeechSegment(
                startSample: start,
                endSample: totalSampleCount
            ))
            currentSpeechStart = nil
        }
    }

    func filterSamples(from allSamples: [Float], padding: Int = 1600) -> [Float] {
        guard !speechSegments.isEmpty else { return allSamples }

        let totalVoiced = speechSegments.reduce(0) { $0 + ($1.endSample - $1.startSample) }
        guard totalVoiced >= 4800 else { return allSamples }

        var result: [Float] = []
        for segment in speechSegments {
            let start = max(0, segment.startSample - padding)
            let end = min(allSamples.count, segment.endSample + padding)
            guard start < end else { continue }
            result.append(contentsOf: allSamples[start..<end])
        }
        return result.isEmpty ? allSamples : result
    }

    /// Release the VAD model from memory.
    func unload() {
        vadManager = nil
        isReady = false
        reset()
    }
}
