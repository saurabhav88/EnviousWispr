@preconcurrency import AVFoundation
import CoreAudio

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

    /// Optional callback to forward converted audio buffers (e.g., to streaming ASR).
    /// Called on the audio thread — must be @Sendable.
    var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Whether noise suppression via Apple Voice Processing is enabled.
    var noiseSuppressionEnabled = false

    /// Persistent UID of the selected input device. Empty string means system default.
    var selectedInputDeviceUID: String = ""

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var configChangeObserver: (any NSObjectProtocol)?

    /// Target format: 16kHz, mono, Float32 — required by both Parakeet and WhisperKit.
    nonisolated static let targetSampleRate: Double = 16000
    nonisolated static let targetChannels: AVAudioChannelCount = 1

    /// Set the input device for the audio engine.
    /// Must be called BEFORE startCapture().
    /// Pass nil or 0 to use the system default device.
    func setInputDevice(_ deviceID: AudioDeviceID?) throws {
        guard let deviceID, deviceID != 0 else { return }

        let audioUnit = engine.inputNode.audioUnit
        guard let au = audioUnit else { return }

        var devID = deviceID
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Task { await AppLogger.shared.log(
                "Failed to set input device \(deviceID): OSStatus \(status)",
                level: .info, category: "Audio"
            ) }
        }
    }

    /// Start capturing audio from the microphone.
    /// Resolves `selectedInputDeviceUID` to a device ID if set.
    func startCapture() throws -> AsyncStream<AVAudioPCMBuffer> {
        guard !isCapturing else {
            return AsyncStream { $0.finish() }
        }

        // Pre-allocate for ~30 seconds of audio at 16kHz to reduce reallocations
        capturedSamples = []
        capturedSamples.reserveCapacity(16000 * 30)
        audioLevel = 0.0

        // Step 1: Set input device (if selected) — must be before inputNode access for format
        let resolvedDeviceID: AudioDeviceID? = selectedInputDeviceUID.isEmpty
            ? nil
            : AudioDeviceEnumerator.deviceID(forUID: selectedInputDeviceUID)
        try setInputDevice(resolvedDeviceID)

        // Step 2: Enable voice processing (if enabled) — must be before installTap and engine.start()
        if noiseSuppressionEnabled {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
            } catch {
                // VP may fail with err=-10876 on some configs — continue without it
                Task { await AppLogger.shared.log(
                    "Voice processing unavailable: \(error.localizedDescription). Continuing without noise suppression.",
                    level: .info, category: "Audio"
                ) }
            }
        } else {
            // Ensure VP is off if previously enabled
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }

        // Register for engine configuration changes (e.g., device disconnect)
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCapturing else { return }
                await AppLogger.shared.log(
                    "Audio engine configuration changed (device disconnect/reconnect)",
                    level: .info, category: "Audio"
                )
            }
        }

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
        let bufferCallback = self.onBufferCaptured

        // Install tap on input node — the handler is built in a nonisolated static
        // context so closures inside it do NOT inherit @MainActor isolation.
        let bufferSize: AVAudioFrameCount = 4096
        let tapHandler = Self.makeTapHandler(
            audioConverter: audioConverter,
            targetFormat: targetFormat,
            inputFormat: inputFormat,
            continuation: tapContinuation,
            onSamples: onSamples,
            onBuffer: bufferCallback
        )
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat, block: tapHandler)

        try engine.start()
        isCapturing = true
        return stream
    }

    /// Inject pre-recorded samples directly into the capture buffer for benchmark/testing.
    /// Sets `capturedSamples` without starting the audio engine.
    func injectSamples(_ samples: [Float]) {
        capturedSamples = samples
    }

    /// Stop capturing and return the accumulated samples.
    func stopCapture() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Disable voice processing after stopping to leave engine in clean state
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        isCapturing = false
        bufferContinuation?.finish()
        bufferContinuation = nil
        converter = nil
        audioLevel = 0.0
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
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
        onSamples: @escaping @Sendable (Float, [Float]) -> Void,
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
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
            nonisolated(unsafe) var inputConsumed = false
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

            // Forward converted buffer to streaming ASR (if active)
            onBuffer?(convertedBuffer)

            // Send buffer to stream consumers
            continuation?.yield(convertedBuffer)
        }
    }
}
