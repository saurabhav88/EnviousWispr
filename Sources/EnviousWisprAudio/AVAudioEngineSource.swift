@preconcurrency import AVFoundation
import EnviousWisprCore
import CoreAudio
import os

/// Diagnostic logger for BT crash investigation — safe from any thread including RT audio.
/// Uses os_log under the hood (lock-free, no heap allocation on the log path).
private let btCrashLogger = Logger(subsystem: "com.enviouswispr", category: "BTCrashDiag")

/// Thread-safe stop token shared between the audio tap handler and the
/// `AVAudioEngineConfigurationChange` observer.
///
/// The config-change observer flips this IMMEDIATELY on CoreAudio's thread
/// (via `setFromConfigChange`), before any MainActor dispatch. The tap handler
/// checks `isSet()` at the top of every invocation and bails out instantly,
/// closing the race window between the BT event and main-thread recovery.
///
/// Uses `os_unfair_lock` to guarantee visibility across the real-time audio
/// thread and the main thread without priority inversion.
private final class TapStoppedFlag: Sendable {
    private struct State: Sendable {
        var stopped = false
        var configChangeTime: CFAbsoluteTime = 0
    }

    private let _lock = OSAllocatedUnfairLock(initialState: State())

    /// Mark as stopped (from main thread teardown paths).
    func set() {
        _lock.withLock { $0.stopped = true }
    }

    /// Mark as stopped from a config-change notification — records monotonic
    /// timestamp for race-window measurement.
    func setFromConfigChange() {
        _lock.withLock {
            $0.stopped = true
            $0.configChangeTime = CFAbsoluteTimeGetCurrent()
        }
    }

    func isSet() -> Bool {
        _lock.withLock { $0.stopped }
    }

    /// Reset for reuse after codec-switch recovery rebuilds the tap.
    func reset() {
        _lock.withLock { $0 = State() }
    }

    /// Timestamp of the last config-change stop, or 0 if none.
    func lastConfigChangeTime() -> CFAbsoluteTime {
        _lock.withLock { $0.configChangeTime }
    }
}

/// AVAudioEngine-based audio capture source. Supports voice processing (noise suppression)
/// and Bluetooth codec switch recovery.
///
/// This is a pure extraction from AudioCaptureManager — all logic moved as-is.
/// Owns the engine, tap, converter, config-change observer, and codec switch recovery.
@MainActor
final class AVAudioEngineSource: AudioInputSource {

    // MARK: - AudioInputSource callbacks

    var onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)?
    var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onInterrupted: (() -> Void)?

    // MARK: - State

    private(set) var isCapturing = false
    var isRunning: Bool { engine.isRunning }

    /// Whether noise suppression via Apple Voice Processing is enabled.
    var noiseSuppressionEnabled = false

    /// Persistent UID of the selected input device. Empty string means system default.
    var selectedInputDeviceUID: String = ""

    /// User override for input device. Empty string means "Auto" (smart selection enabled).
    var preferredInputDeviceIDOverride: String = ""

    /// The CoreAudio device ID currently in use.
    private(set) var currentInputDeviceID: AudioDeviceID?

    // MARK: - Private state

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var configChangeObserver: (any NSObjectProtocol)?
    private var activeTasks: [Task<Void, Never>] = []
    private var tapStoppedFlag: TapStoppedFlag?
    private var isRecovering = false

    /// Called when an audio device operation fails.
    var onDeviceError: ((String) -> Void)?

    // NOTE: onPartialSamples removed — manager owns capturedSamples and handles partial recovery.

    // MARK: - Constants

    nonisolated static let targetSampleRate: Double = 16000
    nonisolated static let targetChannels: AVAudioChannelCount = 1
    nonisolated static let maxRecordingDurationSeconds: Double = 600
    nonisolated static let maxRecordingSamples: Int = Int(maxRecordingDurationSeconds * targetSampleRate)

    // MARK: - Lifecycle

    func prepare() async throws {
        guard !engine.isRunning else { return }

        activeTasks.removeAll()

        // Step 1: Voice Processing FIRST — creates the final AudioUnit type (AUVPIO vs AUHAL).
        // CRITICAL: Must happen before setInputDevice(). If setInputDevice() runs first, it
        // instantiates an AUHAL. Then setVoiceProcessingEnabled(true) DESTROYS that AUHAL and
        // creates an AUVPIO. CoreAudio's BT I/O thread still holds a reference to the destroyed
        // AUHAL → use-after-free → heap corruption → EXC_BAD_ACCESS.
        //
        // Split-route check: when input != output device (e.g., built-in mic + BT headphones),
        // CoreAudio's AEC can't sync different hardware clocks. Disable VP in this case.
        let inputDeviceID = AudioDeviceEnumerator.defaultInputDeviceID()
        let outputDeviceID = AudioDeviceEnumerator.defaultOutputDeviceID()
        let isSplitRoute = inputDeviceID != nil && outputDeviceID != nil && inputDeviceID != outputDeviceID
        let effectiveNoiseSuppression = noiseSuppressionEnabled && !isSplitRoute

        if isSplitRoute && noiseSuppressionEnabled {
            btCrashLogger.info("Split route detected (input=\(inputDeviceID ?? 0) output=\(outputDeviceID ?? 0)) — disabling VP (AEC can't sync different clocks)")
        }

        if effectiveNoiseSuppression {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
            } catch {
                Task { await AppLogger.shared.log(
                    "Voice processing unavailable: \(error.localizedDescription). Continuing without noise suppression.",
                    level: .info, category: "Audio"
                ) }
            }
        } else {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }

        // Step 2: Resolve input device — smart selection when in Auto mode.
        // SAFETY: Skip setInputDevice() entirely when BT output is active.
        let btOutputActive: Bool
        if let outID = AudioDeviceEnumerator.defaultOutputDeviceID() {
            btOutputActive = AudioDeviceEnumerator.isBluetoothDevice(outID)
        } else {
            btOutputActive = false
        }

        let resolvedDeviceID: AudioDeviceID?
        if btOutputActive {
            // BT output active — skip device switch.
            // Forcing built-in mic via setInputDevice crashes the XPC service.
            // Root cause: CoreAudio creates corrupted CADefaultDeviceAggregate.
            // Path forward: AVCaptureSessionSource handles BT case.
            resolvedDeviceID = nil
            btCrashLogger.info("BT output active — skipping setInputDevice (aggregate device crash prevention)")
        } else if !preferredInputDeviceIDOverride.isEmpty {
            resolvedDeviceID = AudioDeviceEnumerator.deviceID(forUID: preferredInputDeviceIDOverride)
        } else if !selectedInputDeviceUID.isEmpty {
            resolvedDeviceID = AudioDeviceEnumerator.deviceID(forUID: selectedInputDeviceUID)
        } else if let recommended = AudioDeviceEnumerator.recommendedInputDevice() {
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

        // Create the capture stop token for this session
        let stopToken = TapStoppedFlag()
        self.tapStoppedFlag = stopToken

        // Register for engine configuration changes
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            stopToken.setFromConfigChange()
            btCrashLogger.info("Config change notification — stop token flipped immediately")

            Task { @MainActor in
                await self?.handleEngineConfigurationChange()
            }
        }

        btCrashLogger.info("Engine starting — stop token created, observer registered (queue: nil)")
        try engine.start()
        btCrashLogger.info("Engine started successfully")
    }

    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
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

        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self.bufferContinuation = continuation
        }

        guard let stoppedFlag = self.tapStoppedFlag else {
            throw AudioError.formatCreationFailed
        }
        stoppedFlag.reset()
        btCrashLogger.info("startCapture: stop token reset, installing tap")

        // Forward samples to the manager via callback. The manager owns capturedSamples accumulation.
        // The source does NOT accumulate samples — avoids double-storage.
        let onSamplesCallback = self.onSamples
        let onSamples: @Sendable (Float, [Float]) -> Void = { level, samples in
            onSamplesCallback?(samples, level)
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

    func stop() async -> [Float] {
        for task in activeTasks { task.cancel() }
        activeTasks.removeAll()

        tapStoppedFlag?.set()
        tapStoppedFlag = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        isCapturing = false
        currentInputDeviceID = nil
        isRecovering = false
        bufferContinuation?.finish()
        bufferContinuation = nil
        converter = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        // Source does not own samples — manager accumulates via onSamples callback.
        return []
    }

    func waitForFormatStabilization(
        maxWait: TimeInterval = 1.5,
        pollInterval: TimeInterval = 0.2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(maxWait)
        var lastFormat = engine.inputNode.outputFormat(forBus: 0)
        try? await Task.sleep(for: .milliseconds(10))
        let recheck = engine.inputNode.outputFormat(forBus: 0)
        if recheck == lastFormat { return true }
        lastFormat = recheck
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(pollInterval))
            let format = engine.inputNode.outputFormat(forBus: 0)
            if format == lastFormat { return true }
            lastFormat = format
        }
        return false
    }

    func abortPrepare() {
        guard engine.isRunning, !isCapturing else { return }
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    func rebuild() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        engine = AVAudioEngine()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    /// Build (or rebuild) the AVAudioEngine with voice-processing configuration.
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

    /// Track a spawned Task so it can be cancelled during teardown.
    func trackTask(_ task: Task<Void, Never>) {
        activeTasks.append(task)
    }

    // MARK: - Private: Input Device

    private func setInputDevice(_ deviceID: AudioDeviceID?) throws {
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

    // MARK: - Private: Bluetooth Codec Switch Recovery

    private func handleEngineConfigurationChange() async {
        btCrashLogger.info("handleEngineConfigurationChange on MainActor — isCapturing=\(self.isCapturing), isRecovering=\(self.isRecovering)")
        guard isCapturing, !isRecovering else { return }

        guard let deviceID = currentInputDeviceID else {
            await AppLogger.shared.log(
                "Audio engine config changed — no device ID, performing emergency teardown",
                level: .info, category: "Audio"
            )
            emergencyTeardown()
            onInterrupted?()
            return
        }

        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &isAlive)

        if isAlive == 0 {
            await AppLogger.shared.log(
                "Audio device \(deviceID) is dead — performing emergency teardown",
                level: .info, category: "Audio"
            )
            emergencyTeardown()
            onInterrupted?()
            return
        }

        await AppLogger.shared.log(
            "Audio engine config changed — device \(deviceID) still alive (Bluetooth codec switch), attempting graceful recovery",
            level: .info, category: "Audio"
        )
        await recoverFromCodecSwitch()
    }

    private func recoverFromCodecSwitch() async {
        isRecovering = true
        defer { isRecovering = false }

        let configTime = tapStoppedFlag?.lastConfigChangeTime() ?? 0
        let recoveryStart = CFAbsoluteTimeGetCurrent()
        let gapMs = configTime > 0 ? (recoveryStart - configTime) * 1000 : -1
        btCrashLogger.info("Recovery started — config→recovery gap: \(gapMs, format: .fixed(precision: 1))ms")

        tapStoppedFlag?.set()

        engine.inputNode.removeTap(onBus: 0)
        btCrashLogger.info("Recovery: tap removed")

        engine.stop()
        btCrashLogger.info("Recovery: engine stopped")

        let stabilized = await waitForFormatStabilization(
            maxWait: 1.5,
            pollInterval: 0.2
        )
        guard stabilized else {
            btCrashLogger.error("Recovery: format stabilization timed out — emergency teardown")
            emergencyTeardown()
            onInterrupted?()
            return
        }

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

            guard let stoppedFlag = tapStoppedFlag else {
                throw AudioError.formatCreationFailed
            }
            stoppedFlag.reset()
            btCrashLogger.info("Recovery: stop token reset for new tap")

            let onSamplesCallback = self.onSamples
            let onSamples: @Sendable (Float, [Float]) -> Void = { level, samples in
                onSamplesCallback?(samples, level)
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
                stoppedFlag.set()
                tapStoppedFlag = nil
                inputNode.removeTap(onBus: 0)
                throw error
            }

            let totalMs = (CFAbsoluteTimeGetCurrent() - recoveryStart) * 1000
            btCrashLogger.info("Recovery succeeded — total: \(totalMs, format: .fixed(precision: 1))ms, recording continues")
        } catch {
            btCrashLogger.error("Recovery failed: \(error.localizedDescription) — emergency teardown")
            emergencyTeardown()
            onInterrupted?()
        }
    }

    private func emergencyTeardown() {
        guard isCapturing else { return }

        for task in activeTasks { task.cancel() }
        activeTasks.removeAll()

        tapStoppedFlag?.set()
        tapStoppedFlag = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        isCapturing = false
        currentInputDeviceID = nil
        isRecovering = false
        bufferContinuation?.finish()
        bufferContinuation = nil
        converter = nil

        // Source does not own samples — manager handles partial sample recovery.

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    // MARK: - Private: Tap Handler (nonisolated)

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
            guard !stoppedFlag.isSet() else {
                btCrashLogger.debug("Tap: bailing — stop flag set")
                return
            }

            let bufferFormat = buffer.format
            guard bufferFormat.sampleRate == inputFormat.sampleRate,
                  bufferFormat.channelCount == inputFormat.channelCount else {
                btCrashLogger.info("Tap: format mismatch — \(bufferFormat.sampleRate)Hz/\(bufferFormat.channelCount)ch vs expected \(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch")
                return
            }

            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard outputFrameCount > 0, outputFrameCount <= 65536 else { return }
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

            guard !stoppedFlag.isSet() else {
                btCrashLogger.debug("Tap: bailing post-convert — stop flag set during conversion")
                return
            }

            let level = AudioBufferProcessor.calculateRMS(convertedBuffer)

            if let channelData = convertedBuffer.floatChannelData {
                let frameCount = Int(convertedBuffer.frameLength)
                let samples = Array(UnsafeBufferPointer(
                    start: channelData[0],
                    count: frameCount
                ))
                onSamples(level, samples)
            }

            onBuffer?(convertedBuffer)
            continuation?.yield(convertedBuffer)
        }
    }
}
