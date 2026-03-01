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

    /// Called before emergency teardown discards captured samples.
    /// Allows the pipeline to salvage a partial transcript from an interrupted recording.
    var onPartialSamples: (([Float]) -> Void)?

    /// Called when an audio device operation fails (e.g., input device switch).
    /// The pipeline should surface this to the user as a visible error banner.
    var onDeviceError: ((String) -> Void)?

    /// Whether noise suppression via Apple Voice Processing is enabled.
    var noiseSuppressionEnabled = false

    /// Persistent UID of the selected input device. Empty string means system default.
    var selectedInputDeviceUID: String = ""

    /// User override for input device. Empty string means "Auto" (smart selection enabled).
    var preferredInputDeviceIDOverride: String = ""

    /// The CoreAudio device ID currently in use. Set at recording start, used by
    /// the config-change handler to check `kAudioDevicePropertyDeviceIsAlive`.
    private(set) var currentInputDeviceID: AudioDeviceID?

    /// Guard against re-entrant codec switch recovery. Multiple
    /// `AVAudioEngineConfigurationChange` notifications can fire during a single
    /// Bluetooth negotiation — only the first should trigger recovery.
    private var isRecovering = false

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
            onDeviceError?("Audio device switch failed for device \(deviceID)")
        }
    }

    // MARK: - Two-Phase Recording Start

    /// Phase 1: Start the engine to trigger any Bluetooth codec switch.
    /// Sets the input device, enables voice processing, registers the config-change
    /// observer, and starts the engine. Does NOT install a tap or begin capture.
    /// Safe to call multiple times — no-op if the engine is already running.
    func startEnginePhase() throws {
        guard !engine.isRunning else { return }

        // Pre-allocate for ~30 seconds of audio at 16kHz to reduce reallocations
        capturedSamples = []
        capturedSamples.reserveCapacity(16000 * 30)
        activeTasks.removeAll()
        audioLevel = 0.0

        // Step 1: Resolve input device — smart selection when in Auto mode
        let resolvedDeviceID: AudioDeviceID?
        if !preferredInputDeviceIDOverride.isEmpty {
            // User explicitly chose a device — respect it
            resolvedDeviceID = AudioDeviceEnumerator.deviceID(forUID: preferredInputDeviceIDOverride)
        } else if !selectedInputDeviceUID.isEmpty {
            // Legacy path — explicit device UID set
            resolvedDeviceID = AudioDeviceEnumerator.deviceID(forUID: selectedInputDeviceUID)
        } else if let recommended = AudioDeviceEnumerator.recommendedInputDevice() {
            // Auto mode: smart selection — BT output active with media playing, use built-in mic
            resolvedDeviceID = recommended
            Task { await AppLogger.shared.log(
                "Smart device selection: using built-in mic (BT output detected with active media)",
                level: .info, category: "Audio"
            ) }
        } else {
            resolvedDeviceID = nil
        }
        try setInputDevice(resolvedDeviceID)
        currentInputDeviceID = resolvedDeviceID ?? AudioDeviceEnumerator.defaultInputDeviceID()

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

        // Register for engine configuration changes (e.g., device disconnect, BT codec switch).
        if configChangeObserver == nil {
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.handleEngineConfigurationChange()
                }
            }
        }

        try engine.start()
    }

    /// Phase 2: Install the tap and begin capture.
    /// Call only after `startEnginePhase()` and `waitForFormatStabilization()`.
    /// Returns an `AsyncStream` of converted audio buffers.
    func beginCapturePhase() throws -> AsyncStream<AVAudioPCMBuffer> {
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
        let stoppedFlag = TapStoppedFlag()
        self.tapStoppedFlag = stoppedFlag

        // Create a @Sendable callback for dispatching audio data to the main actor.
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

        // Install tap on input node
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

        // If the engine isn't running (e.g., pre-warm failed), start it now
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
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
        }

        isCapturing = true
        return stream
    }

    /// Backward-compatible wrapper: runs both phases sequentially.
    /// Resolves `selectedInputDeviceUID` to a device ID if set.
    func startCapture() throws -> AsyncStream<AVAudioPCMBuffer> {
        guard !isCapturing else {
            return AsyncStream { $0.finish() }
        }
        try startEnginePhase()
        return try beginCapturePhase()
    }

    /// Replace the AVAudioEngine with a fresh instance.
    /// Call when format stabilization fails and a full rebuild is needed.
    func rebuildEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        engine = AVAudioEngine()
        // Re-register config change observer for the new engine
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    /// Build (or rebuild) the AVAudioEngine with the correct voice-processing configuration.
    /// Must be called before `startEnginePhase()`. Any existing engine is torn down first.
    /// Configures anti-ducking when voice processing is enabled to prevent the engine
    /// from lowering other apps' audio volume during recording.
    func buildEngine(noiseSuppression: Bool) {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        engine = AVAudioEngine()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        if noiseSuppression {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                // Disable ducking — we do NOT want the engine lowering other apps' volume
                if #available(macOS 14.0, *) {
                    let duckingConfig = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false,
                        duckingLevel: .min
                    )
                    engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = duckingConfig
                }
            } catch {
                Task { await AppLogger.shared.log(
                    "Voice processing unavailable during engine build: \(error.localizedDescription)",
                    level: .info, category: "Audio"
                ) }
            }
        }
        noiseSuppressionEnabled = noiseSuppression
    }

    /// Open the audio input to trigger any Bluetooth codec switch, then wait for
    /// format stabilization. Safe to call multiple times — no-op if engine is already running.
    /// Does NOT install a tap or begin capture.
    func preWarm() async {
        guard !engine.isRunning else { return }
        do {
            try startEnginePhase()
        } catch {
            Task { await AppLogger.shared.log(
                "Audio pre-warm failed: \(error.localizedDescription)",
                level: .info, category: "Audio"
            ) }
            return
        }
        // Allow the codec switch and format stabilization to complete
        _ = await waitForFormatStabilization(maxWait: 1.5, pollInterval: 0.2)
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
        currentInputDeviceID = nil
        isRecovering = false
        bufferContinuation?.finish()
        bufferContinuation = nil
        converter = nil
        audioLevel = 0.0
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        // Move samples out and clear to release memory between sessions.
        // Without this, ~38MB (10min at 16kHz) lingers until the next startCapture().
        let samples = capturedSamples
        capturedSamples = []
        return samples
    }

    // MARK: - Bluetooth Codec Switch Recovery

    /// Determine whether an engine configuration change is a Bluetooth codec switch
    /// (device still alive) or a true disconnect (device dead), and react accordingly.
    private func handleEngineConfigurationChange() async {
        guard isCapturing, !isRecovering else { return }

        guard let deviceID = currentInputDeviceID else {
            await AppLogger.shared.log(
                "Audio engine config changed — no device ID, performing emergency teardown",
                level: .info, category: "Audio"
            )
            emergencyTeardown()
            onEngineInterrupted?()
            return
        }

        // Check kAudioDevicePropertyDeviceIsAlive via CoreAudio
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &isAlive)

        if isAlive == 0 {
            // True disconnect — tear down as before
            await AppLogger.shared.log(
                "Audio device \(deviceID) is dead — performing emergency teardown",
                level: .info, category: "Audio"
            )
            emergencyTeardown()
            onEngineInterrupted?()
            return
        }

        // Codec switch — attempt graceful recovery
        await AppLogger.shared.log(
            "Audio engine config changed — device \(deviceID) still alive (Bluetooth codec switch), attempting graceful recovery",
            level: .info, category: "Audio"
        )
        await recoverFromCodecSwitch()
    }

    /// Graceful recovery from a Bluetooth A2DP→SCO codec switch.
    /// Removes the tap, stops the engine, waits for the format to stabilize,
    /// then reinstalls the tap and restarts the engine. `capturedSamples` is preserved.
    private func recoverFromCodecSwitch() async {
        isRecovering = true
        defer { isRecovering = false }

        // 1. Signal the tap handler to stop before removing the tap
        tapStoppedFlag?.set()

        // 2. Remove the existing tap so the engine can be stopped cleanly
        engine.inputNode.removeTap(onBus: 0)

        // 3. Stop the engine (it may already be stopped after the config change)
        engine.stop()

        // 4. Poll for format stabilization — the SCO format settles within 200ms–1s
        let stabilized = await waitForFormatStabilization(
            maxWait: 1.5,
            pollInterval: 0.2
        )
        guard stabilized else {
            // Format never settled — treat as unrecoverable
            await AppLogger.shared.log(
                "Format stabilization timed out during codec switch recovery — performing emergency teardown",
                level: .info, category: "Audio"
            )
            emergencyTeardown()
            onEngineInterrupted?()
            return
        }

        // 5. Rebuild converter and reinstall tap with the new format, then restart engine
        do {
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

            guard let audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw AudioError.formatCreationFailed
            }
            self.converter = audioConverter

            // Create a new stopped flag for the recovery tap
            let stoppedFlag = TapStoppedFlag()
            self.tapStoppedFlag = stoppedFlag

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
                // Clean up the orphaned tap on engine start failure
                stoppedFlag.set()
                tapStoppedFlag = nil
                inputNode.removeTap(onBus: 0)
                throw error
            }

            await AppLogger.shared.log(
                "Graceful recovery from codec switch succeeded — recording continues",
                level: .info, category: "Audio"
            )
        } catch {
            await AppLogger.shared.log(
                "Codec switch recovery failed: \(error.localizedDescription) — performing emergency teardown",
                level: .info, category: "Audio"
            )
            emergencyTeardown()
            onEngineInterrupted?()
        }
    }

    /// Poll the input node's output format until it stabilizes (two consecutive equal formats).
    func waitForFormatStabilization(
        maxWait: TimeInterval = 1.5,
        pollInterval: TimeInterval = 0.2
    ) async -> Bool {
        var lastFormat: AVAudioFormat? = nil
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            let format = engine.inputNode.outputFormat(forBus: 0)
            if format == lastFormat { return true }
            lastFormat = format
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        return false
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
        currentInputDeviceID = nil
        isRecovering = false
        bufferContinuation?.finish()
        bufferContinuation = nil
        converter = nil
        audioLevel = 0.0

        // Salvage partial samples before discarding — a 10-minute recording
        // should not be silently lost on device disconnect.
        if !capturedSamples.isEmpty {
            let partialSamples = capturedSamples
            onPartialSamples?(partialSamples)
        }
        capturedSamples = []

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    /// Track a spawned Task so it can be cancelled during teardown.
    /// Prunes already-completed tasks on each call to prevent unbounded growth.
    func trackTask(_ task: Task<Void, Never>) {
        activeTasks.removeAll { $0.isCancelled }
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
