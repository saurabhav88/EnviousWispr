import AVFoundation

/// Manages audio capture from the microphone via AVAudioEngine.
///
/// Captures audio, converts to 16kHz mono Float32 (required by both ASR backends),
/// and provides real-time audio level metering for UI visualization.
@MainActor
@Observable
final class AudioCaptureManager {
    /// Current recording state.
    private(set) var isCapturing = false

    /// Current audio level (0.0 - 1.0) for waveform visualization.
    private(set) var audioLevel: Float = 0.0

    /// Accumulated audio samples from the current recording.
    private(set) var capturedSamples: [Float] = []

    private let engine = AVAudioEngine()
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// Target format: 16kHz, mono, Float32 — required by both Parakeet and WhisperKit.
    nonisolated static let targetSampleRate: Double = 16000
    nonisolated static let targetChannels: AVAudioChannelCount = 1

    /// Start capturing audio from the microphone.
    func startCapture() throws -> AsyncStream<AVAudioPCMBuffer> {
        guard !isCapturing else {
            return AsyncStream { $0.finish() }
        }

        capturedSamples = []

        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self.bufferContinuation = continuation
        }

        // TODO: M1 — Install tap on inputNode, convert to 16kHz mono, accumulate samples
        isCapturing = true
        return stream
    }

    /// Stop capturing and return the accumulated samples.
    func stopCapture() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        bufferContinuation?.finish()
        bufferContinuation = nil
        audioLevel = 0.0
        return capturedSamples
    }
}
