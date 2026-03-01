@preconcurrency import AVFoundation
import CoreAudio
import os

/// Thread-safe stopped flag for the audio tap handler.
/// Uses `os_unfair_lock` to guarantee visibility across the real-time audio
/// thread and the main thread without priority inversion (unlike `NSLock`).
/// The flag is set on the main thread BEFORE `removeTap(onBus:)` is called,
/// so any in-flight or subsequent tap handler invocation sees `true` and
/// skips all heap-allocating work (Task creation, continuation yield).
private final class TapStoppedFlag: Sendable {
    private let _lock = OSAllocatedUnfairLock(initialState: false)

    func set() {
        _lock.withLock { $0 = true }
    }

    func isSet() -> Bool {
        _lock.withLock { $0 }
    }
}

/// Manages audio capture from the microphone via AVAudioEngine.
///
/// Captures audio, converts to 16kHz mono Float32 (required by both ASR backends),
/// and provides real-time audio level metering for UI visualization.
///
/// **Session lifecycle guarantee**: start, stop, and teardown are atomic.
/// Device disconnect, engine errors, and max-duration cap all trigger
/// full cleanup (tap removal, engine stop, continuation finish, state reset).
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

    /// Called on the main actor when the audio engine is interrupted (e.g., device disconnect).
    /// The pipeline should transition to an error state when this fires.
    var onEngineInterrupted: (() -> Void)?

    /// Whether noise suppression via Apple Voice Processing is enabled.
    var noiseSuppressionEnabled = false

    /// Persistent UID of the selected input device. Empty string means system default.
    var selectedInputDeviceUID: String = ""

    /// Maximum recording duration in seconds. Prevents unbounded memory growth.
    nonisolated static let maxRecordingDurationSeconds: Double = 600 // 10 minutes
    /// Maximum sample count derived from maxRecordingDurationSeconds at 16kHz.
    nonisolated static let maxRecordingSamples: Int = Int(maxRecordingDurationSeconds * targetSampleRate)

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var configChangeObserver: (any NSObjectProtocol)?
    /// Tracked tasks spawned during capture (buffer forwarding, etc.) — cancelled on teardown.
    private var activeTasks: [Task<Void, Never>] = []

    /// Atomic flag checked by the real-time audio tap handler.
    /// Set to `true` before `removeTap` / `engine.stop()` to prevent the tap
    /// handler from creating Tasks or yielding to the continuation after
    /// teardown has begun. Without this, in-flight tap callbacks can heap-allocate
    /// (`Task { @MainActor }`) concurrently with main-thread teardown, corrupting
    /// malloc's free lists (the "free block corruption" crash).
    private var tapStoppedFlag: TapStoppedFlag?

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

        // Register for engine configuration changes (e.g., device disconnect).
        // On device disconnect AVAudioEngine posts this notification and stops itself.
        // We must perform full teardown so the next recording starts clean.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCapturing else { return }
                await AppLogger.shared.log(
                    "Audio engine configuration changed (device disconnect/reconnect) — performing emergency teardown",
                    level: .info, category: "Audio"
                )
                self.emergencyTeardown()
                self.onEngineInterrupted?()
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

        // Create a stopped flag for this capture session.
        // The tap handler checks this atomically before doing any work.
        let stoppedFlag = TapStoppedFlag()
        self.tapStoppedFlag = stoppedFlag

        // Create a @Sendable callback for dispatching audio data to the main actor.
        // This captures [weak self] safely — the weak reference is only dereferenced
        // inside Task { @MainActor }, never on the audio thread.
        // Enforces the max recording duration cap to prevent unbounded memory growth.
        let maxSamples = Self.maxRecordingSamples
        let onSamples: @Sendable (Float, [Float]) -> Void = { [weak self] level, samples in
            Task { @MainActor in
                guard let self, self.isCapturing else { return }
                self.audioLevel = level
                self.capturedSamples.append(contentsOf: samples)
                if self.capturedSamples.count >= maxSamples {
                    await AppLogger.shared.log(
                        "Max recording duration reached (\(Self.maxRecordingDurationSeconds)s) — auto-stopping",
                        level: .info, category: "Audio"
                    )
                    self.emergencyTeardown()
                    self.onEngineInterrupted?()
                }
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
            onBuffer: bufferCallback,
            stoppedFlag: stoppedFlag
        )
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat, block: tapHandler)

        do {
            try engine.start()
        } catch {
            // Clean up the orphaned tap — without this, all future recordings fail
            // because installTap on a bus that already has a tap throws.
            stoppedFlag.set()
            tapStoppedFlag = nil
            inputNode.removeTap(onBus: 0)
            bufferContinuation?.finish()
            bufferContinuation = nil
            converter = nil
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }
            throw error
        }
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
        // Cancel all tracked tasks (buffer forwarding, etc.)
        for task in activeTasks { task.cancel() }
        activeTasks.removeAll()

        // Signal the tap handler to stop BEFORE removing the tap.
        // This prevents any in-flight or final tap callback from creating
        // Tasks or yielding to the continuation during teardown.
        tapStoppedFlag?.set()
        tapStoppedFlag = nil

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

    /// Emergency teardown after device disconnect or engine configuration change.
    /// Performs full cleanup and resets the engine so the next recording can start fresh.
    /// Does NOT call onEngineInterrupted — the caller is responsible for that.
    private func emergencyTeardown() {
        guard isCapturing else { return }

        // Cancel all tracked tasks
        for task in activeTasks { task.cancel() }
        activeTasks.removeAll()

        // Signal the tap handler to stop before teardown
        tapStoppedFlag?.set()
        tapStoppedFlag = nil

        // Remove tap and stop engine — may already be stopped after disconnect
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Reset the engine so the audio graph recovers for the next recording.
        // After a device disconnect, the engine's internal graph is invalidated;
        // reset() rebuilds it with default nodes.
        engine.reset()

        isCapturing = false
        bufferContinuation?.finish()
        bufferContinuation = nil
        converter = nil
        audioLevel = 0.0
        capturedSamples = []

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    /// Track a spawned Task so it can be cancelled during teardown.
    func trackTask(_ task: Task<Void, Never>) {
        activeTasks.append(task)
    }

    /// Build the audio tap handler in a nonisolated context.
    ///
    /// This is critical: closures defined inside a @MainActor method inherit that
    /// isolation, causing runtime crashes when the audio tap runs on the real-time
    /// audio thread. By constructing the handler here (nonisolated static), all
    /// closures within it are free of @MainActor isolation.
    ///
    /// The `stoppedFlag` is checked at the top of every invocation. When the main
    /// thread sets it (inside `stopCapture` / `emergencyTeardown`) BEFORE calling
    /// `removeTap`, any in-flight or final tap callback sees the flag and returns
    /// immediately — avoiding heap-allocating `Task { @MainActor }` creation and
    /// `continuation.yield` calls that race with main-thread teardown.
    nonisolated private static func makeTapHandler(
        audioConverter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        inputFormat: AVAudioFormat,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?,
        onSamples: @escaping @Sendable (Float, [Float]) -> Void,
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        stoppedFlag: TapStoppedFlag
    ) -> (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { buffer, _ in
            // Bail out immediately if stop/teardown has been initiated.
            // This is the critical guard that prevents heap corruption:
            // without it, the tap handler would create Task allocations
            // and yield to the continuation while the main thread is
            // tearing down those same structures.
            guard !stoppedFlag.isSet() else { return }

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

            // Re-check after potentially long convert() call
            guard !stoppedFlag.isSet() else { return }

            // Calculate audio level for UI
            let level = AudioBufferProcessor.calculateRMS(convertedBuffer)

            // Extract float samples into a plain [Float] (value type) and dispatch
            // only the value-type data to the main actor. This avoids sending the
            // non-Sendable AVAudioPCMBuffer across threads for sample accumulation.
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
