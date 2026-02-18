@preconcurrency import AVFoundation

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
    private var converter: AVAudioConverter?
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
        audioLevel = 0.0

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannels,
            interleaved: false
        ) else {
            throw AudioError.formatCreationFailed
        }

        // Create converter for resampling to 16kHz mono
        guard let audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioError.formatCreationFailed
        }
        self.converter = audioConverter

        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self.bufferContinuation = continuation
        }

        // Create a @Sendable callback for dispatching audio data to the main actor.
        // This captures [weak self] safely — the weak reference is only dereferenced
        // inside Task { @MainActor }, never on the audio thread.
        let onSamples: @Sendable (Float, [Float]) -> Void = { [weak self] level, samples in
            Task { @MainActor in
                self?.audioLevel = level
                self?.capturedSamples.append(contentsOf: samples)
            }
        }

        let tapContinuation = self.bufferContinuation

        // Install tap on input node — the handler is built in a nonisolated static
        // context so closures inside it do NOT inherit @MainActor isolation.
        let bufferSize: AVAudioFrameCount = 4096
        let tapHandler = Self.makeTapHandler(
            audioConverter: audioConverter,
            targetFormat: targetFormat,
            inputFormat: inputFormat,
            continuation: tapContinuation,
            onSamples: onSamples
        )
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat, block: tapHandler)

        try engine.start()
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
        converter = nil
        audioLevel = 0.0
        return capturedSamples
    }

    /// Build the audio tap handler in a nonisolated context.
    ///
    /// This is critical: closures defined inside a @MainActor method inherit that
    /// isolation, causing runtime crashes when the audio tap runs on the real-time
    /// audio thread. By constructing the handler here (nonisolated static), all
    /// closures within it are free of @MainActor isolation.
    nonisolated private static func makeTapHandler(
        audioConverter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        inputFormat: AVAudioFormat,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?,
        onSamples: @escaping @Sendable (Float, [Float]) -> Void
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { buffer, _ in
            // Convert to target format (16kHz mono)
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCount
            ) else { return }

            var error: NSError?
            var inputConsumed = false
            audioConverter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            guard error == nil, convertedBuffer.frameLength > 0 else { return }

            // Calculate audio level for UI
            let level = AudioBufferProcessor.calculateRMS(convertedBuffer)

            // Extract float samples and dispatch to main actor
            if let channelData = convertedBuffer.floatChannelData {
                let frameCount = Int(convertedBuffer.frameLength)
                let samples = Array(UnsafeBufferPointer(
                    start: channelData[0],
                    count: frameCount
                ))
                onSamples(level, samples)
            }

            // Send buffer to stream consumers
            continuation?.yield(convertedBuffer)
        }
    }
}
