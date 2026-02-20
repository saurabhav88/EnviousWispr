import Foundation
@preconcurrency import FluidAudio

struct SmoothedVADConfig: Sendable {
    var emaAlpha: Float = 0.3
    var onsetThreshold: Float = 0.5
    var offsetThreshold: Float = 0.35
    var onsetConfirmationChunks: Int = 1
    var hangoverChunks: Int = 3
    var prebufferChunks: Int = 2
    var energyGateThreshold: Float = 0.0

    static func fromSensitivity(_ sensitivity: Float) -> SmoothedVADConfig {
        let onset = 0.7 - (sensitivity * 0.4)       // 0.3 at sens=1.0, 0.7 at sens=0.0
        let offset = max(0.1, onset - 0.15)
        let hangover = sensitivity > 0.7 ? 4 : 3
        let confirmation = sensitivity < 0.3 ? 2 : 1
        return SmoothedVADConfig(
            onsetThreshold: onset,
            offsetThreshold: offset,
            onsetConfirmationChunks: confirmation,
            hangoverChunks: hangover
        )
    }
}

enum SmoothedVADPhase: Sendable {
    case idle
    case speech
    case hangover(chunksRemaining: Int)
}

struct SpeechSegment: Sendable {
    let startSample: Int
    let endSample: Int
}

/// Monitors audio for speech activity and detects silence after speech for auto-stop.
///
/// Uses FluidAudio's Silero VAD model for raw probability, then applies EMA smoothing
/// and a three-phase state machine (idle/speech/hangover) for robust onset/offset detection.
/// Processes 4096-sample chunks (256ms at 16kHz).
actor SilenceDetector {
    private var vadManager: VadManager?
    private var streamState: VadStreamState = .initial()
    private(set) var speechDetected = false
    private(set) var isReady = false
    private(set) var speechSegments: [SpeechSegment] = []
    private var currentSpeechStart: Int? = nil
    private var processedSampleCount: Int = 0
    private(set) var voicedSamples: [Float] = []

    // SmoothedVAD state
    private var phase: SmoothedVADPhase = .idle
    private var emaSmoothedProbability: Float = 0.0
    private var consecutiveAboveOnset: Int = 0
    private(set) var vadConfig: SmoothedVADConfig

    // Prebuffer ring buffer
    private var prebuffer: [[Float]] = []
    private var prebufferWriteIndex: Int = 0
    private var prebufferFilled: Bool = false

    let silenceTimeout: TimeInterval

    /// Chunk size expected by the Silero VAD model (256ms at 16kHz).
    nonisolated static let chunkSize = 4096

    /// Hangover chunks derived from silenceTimeout so the detector waits
    /// the full user-configured duration before auto-stopping.
    private var effectiveHangoverChunks: Int {
        let chunkDurationSeconds = Double(Self.chunkSize) / 16000.0  // 0.256s
        return max(3, Int(ceil(silenceTimeout / chunkDurationSeconds)))
    }

    init(silenceTimeout: TimeInterval = 1.5, vadConfig: SmoothedVADConfig = SmoothedVADConfig()) {
        self.silenceTimeout = silenceTimeout
        self.vadConfig = vadConfig
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
        // Pre-allocate for ~30 seconds of voiced audio to reduce reallocations
        voicedSamples = []
        voicedSamples.reserveCapacity(16000 * 30)
        phase = .idle
        emaSmoothedProbability = 0.0
        consecutiveAboveOnset = 0
        prebuffer.removeAll(keepingCapacity: true)
        prebufferWriteIndex = 0
        prebufferFilled = false
    }

    /// Update the SmoothedVAD configuration.
    func updateConfig(_ config: SmoothedVADConfig) {
        vadConfig = config
    }

    /// Process a chunk of 4096 audio samples (16kHz mono).
    /// Returns `true` if silence after speech is detected (auto-stop should trigger).
    func processChunk(_ samples: [Float]) async -> Bool {
        guard let vad = vadManager else { return false }

        // 1. Write chunk to prebuffer (always)
        writeToPrebuffer(samples)

        // 2. Determine raw probability
        var rawProbability: Float = 0.0

        if vadConfig.energyGateThreshold > 0 && computeRMS(samples) < vadConfig.energyGateThreshold {
            // Energy pre-gate: chunk is too quiet, skip VAD inference
            rawProbability = 0.0
        } else {
            // Run Silero VAD to get raw probability
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
            rawProbability = result.probability
        }

        // 3. EMA smoothing
        let smoothed = vadConfig.emaAlpha * rawProbability + (1.0 - vadConfig.emaAlpha) * emaSmoothedProbability
        emaSmoothedProbability = smoothed

        // 4. State machine transitions
        var shouldAutoStop = false

        switch phase {
        case .idle:
            if smoothed >= vadConfig.onsetThreshold {
                consecutiveAboveOnset += 1
                if consecutiveAboveOnset >= vadConfig.onsetConfirmationChunks {
                    phase = .speech
                    speechDetected = true
                    currentSpeechStart = processedSampleCount

                    // Drain prebuffer into voicedSamples for context
                    let prebuffered = drainPrebuffer()
                    if !prebuffered.isEmpty {
                        voicedSamples.append(contentsOf: prebuffered)
                    }
                    // Append current chunk
                    voicedSamples.append(contentsOf: samples)
                }
            } else {
                consecutiveAboveOnset = 0
            }

        case .speech:
            voicedSamples.append(contentsOf: samples)
            if smoothed < vadConfig.offsetThreshold {
                phase = .hangover(chunksRemaining: effectiveHangoverChunks)
            }

        case .hangover(let remaining):
            voicedSamples.append(contentsOf: samples)
            if smoothed >= vadConfig.onsetThreshold {
                // Speech resumed, go back to speech phase
                phase = .speech
            } else {
                let next = remaining - 1
                if next <= 0 {
                    // Hangover expired: close segment and signal auto-stop
                    phase = .idle
                    consecutiveAboveOnset = 0
                    if let start = currentSpeechStart {
                        speechSegments.append(SpeechSegment(
                            startSample: start,
                            endSample: processedSampleCount + samples.count
                        ))
                        currentSpeechStart = nil
                    }
                    shouldAutoStop = true
                } else {
                    phase = .hangover(chunksRemaining: next)
                }
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

        // Build padded ranges and merge overlaps
        var merged: [(start: Int, end: Int)] = []
        for segment in speechSegments {
            let start = max(0, segment.startSample - padding)
            let end = min(allSamples.count, segment.endSample + padding)
            if let last = merged.last, start <= last.end {
                merged[merged.count - 1].end = max(last.end, end)
            } else {
                merged.append((start, end))
            }
        }

        var result: [Float] = []
        for range in merged {
            guard range.start < range.end else { continue }
            result.append(contentsOf: allSamples[range.start..<range.end])
        }
        return result.isEmpty ? allSamples : result
    }

    /// Release the VAD model from memory.
    func unload() {
        vadManager = nil
        isReady = false
        reset()
    }

    // MARK: - Private Helpers

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0.0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    private func writeToPrebuffer(_ chunk: [Float]) {
        let capacity = vadConfig.prebufferChunks
        guard capacity > 0 else { return }

        if prebuffer.count < capacity {
            // Still filling up the buffer
            prebuffer.append(chunk)
        } else {
            // Overwrite oldest entry in ring buffer fashion
            prebuffer[prebufferWriteIndex] = chunk
            prebufferFilled = true
        }
        prebufferWriteIndex = (prebufferWriteIndex + 1) % capacity
    }

    private func drainPrebuffer() -> [Float] {
        guard !prebuffer.isEmpty else { return [] }

        let count = prebuffer.count
        // Pre-allocate capacity to avoid repeated reallocations during append
        let estimatedSize = count * Self.chunkSize
        var result: [Float] = []
        result.reserveCapacity(estimatedSize)

        if prebufferFilled {
            // Read from writeIndex (oldest) through the buffer
            for i in 0..<count {
                let idx = (prebufferWriteIndex + i) % count
                result.append(contentsOf: prebuffer[idx])
            }
        } else {
            // Buffer not yet full, read in order
            for chunk in prebuffer {
                result.append(contentsOf: chunk)
            }
        }

        // Clear the prebuffer after draining (use removeAll to reuse capacity)
        prebuffer.removeAll(keepingCapacity: true)
        prebufferWriteIndex = 0
        prebufferFilled = false

        return result
    }
}
