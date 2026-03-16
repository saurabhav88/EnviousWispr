import Foundation
@preconcurrency import AVFoundation
import EnviousWisprCore
import EnviousWisprAudio

/// XPC service handler — composes an AudioCaptureManager and bridges its lifecycle
/// to the XPC protocol. All capture logic runs in the service process; the host app
/// receives buffers and state changes via AudioServiceClientProtocol callbacks.
final class AudioServiceHandler: NSObject, AudioServiceProtocol, @unchecked Sendable {
    /// The XPC connection back to the host — set by AudioServiceDelegate.
    weak var connection: NSXPCConnection?

    /// Client proxy for sending callbacks to the host app.
    /// Resolved from connection.remoteObjectProxy — set by AudioServiceDelegate.
    var clientProxy: (any AudioServiceClientProtocol)?

    /// The in-process audio capture engine. Runs entirely within this XPC service process.
    /// @MainActor — the XPC service's main run loop serves as the MainActor executor.
    /// Created lazily on MainActor when first needed.
    private var _captureManager: AudioCaptureManager?

    /// Dedicated serial queue for XPC sends — keeps XPC messaging off the RT audio thread.
    private let xpcSendQueue = DispatchQueue(label: "com.enviouswispr.audioservice.xpc-send")

    // MARK: - Service-side VAD state (Step 5)

    /// Stored VAD configuration — applied when capture begins, replayed after crash.
    private var vadAutoStop: Bool = false
    private var vadSilenceTimeout: Double = 1.5
    private var vadSensitivity: Float = 0.5
    private var vadEnergyGate: Bool = false

    /// Service-owned SilenceDetector — runs VAD in the service process where samples live.
    private var silenceDetector: SilenceDetector?

    /// VAD monitoring task — started after beginCapture, cancelled on stopCapture/abortPreWarm.
    private var vadMonitorTask: Task<Void, Never>?

    /// Get or create the capture manager on MainActor, wiring callbacks on first creation.
    @MainActor
    private var captureManager: AudioCaptureManager {
        if let existing = _captureManager { return existing }
        let manager = AudioCaptureManager()
        wireCallbacks(on: manager)
        _captureManager = manager
        return manager
    }

    /// Wire AudioCaptureManager callbacks to XPC client proxy calls.
    @MainActor
    private func wireCallbacks(on manager: AudioCaptureManager) {
        // Buffer callback: fires on CoreAudio's real-time audio thread.
        // RT discipline: only arithmetic + bounded memcpy on the RT thread.
        // XPC send dispatched to xpcSendQueue.
        manager.onBufferCaptured = { [weak self] buffer in
            guard let floatData = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }

            // RMS: tight arithmetic loop — no heap allocation, RT-safe.
            // Matches AudioBufferProcessor.calculateRMS formula: -60dB..0dB → 0..1
            var sum: Float = 0
            for i in 0..<count { sum += floatData[i] * floatData[i] }
            let rms = sqrt(sum / Float(count))
            let dBFS = 20 * log10(max(rms, 1e-6))
            let level = max(0, min(1, (dBFS + 60) / 60))

            // Capture buffer to keep its memory alive across the queue hop.
            // Data(bytes:count:) does malloc — moved off RT thread to xpcSendQueue.
            nonisolated(unsafe) let safeBuffer = buffer
            self?.xpcSendQueue.async { [weak self] in
                guard let floats = safeBuffer.floatChannelData?[0] else { return }
                let data = Data(bytes: floats, count: count * MemoryLayout<Float>.size)
                self?.clientProxy?.audioBufferCaptured(data, frameCount: count, audioLevel: level)
            }
        }

        // Engine interruption callback: fires on @MainActor.
        manager.onEngineInterrupted = { [weak self] in
            self?.xpcSendQueue.async { [weak self] in
                self?.clientProxy?.engineInterrupted()
            }
        }
    }

    // MARK: - Diagnostics

    func ping(reply: @escaping (String) -> Void) {
        reply("pong")
    }

    func checkMicPermission(reply: @escaping (Int, String) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let name: String
        switch status {
        case .notDetermined: name = "notDetermined"
        case .restricted:    name = "restricted"
        case .denied:        name = "denied"
        case .authorized:    name = "authorized"
        @unknown default:    name = "unknown(\(status.rawValue))"
        }
        reply(status.rawValue, name)
    }

    // MARK: - Configuration

    func buildEngine(noiseSuppression: Bool) {
        Task { @MainActor in
            captureManager.buildEngine(noiseSuppression: noiseSuppression)
        }
    }

    func setNoiseSuppressionEnabled(_ enabled: Bool) {
        Task { @MainActor in
            captureManager.noiseSuppressionEnabled = enabled
        }
    }

    func setPreferredInputDeviceUID(_ uid: String) {
        Task { @MainActor in
            captureManager.preferredInputDeviceIDOverride = uid
        }
    }

    func setSelectedInputDeviceUID(_ uid: String) {
        Task { @MainActor in
            captureManager.selectedInputDeviceUID = uid
        }
    }

    // MARK: - Lifecycle

    func startEnginePhase(
        preferredDeviceUID: String,
        selectedDeviceUID: String,
        reply: @escaping (NSError?) -> Void
    ) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            captureManager.preferredInputDeviceIDOverride = preferredDeviceUID
            captureManager.selectedInputDeviceUID = selectedDeviceUID
            do {
                try await captureManager.startEnginePhase()
                safeReply(nil)
            } catch {
                safeReply(error as NSError)
            }
        }
    }

    func waitForFormatStabilization(
        maxWait: Double,
        pollInterval: Double,
        reply: @escaping (Bool) -> Void
    ) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            let result = await captureManager.waitForFormatStabilization(
                maxWait: maxWait,
                pollInterval: pollInterval
            )
            safeReply(result)
        }
    }

    func beginCapture(reply: @escaping (NSError?) -> Void) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            do {
                _ = try await self.captureManager.beginCapturePhase()
                self.startVADMonitoring()
                safeReply(nil)
            } catch {
                safeReply(error as NSError)
            }
        }
    }

    func stopCapture(reply: @escaping (Data) -> Void) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            self.cancelVADMonitoring()
            let samples = await self.captureManager.stopCapture()
            // Transport format: raw Float32 bytes, non-interleaved mono, 16kHz.
            let data = samples.withUnsafeBytes { Data($0) }
            safeReply(data)
        }
    }

    func abortPreWarm() {
        Task { @MainActor in
            self.cancelVADMonitoring()
            self.captureManager.abortPreWarm()
        }
    }

    func rebuildEngine() {
        Task { @MainActor in
            captureManager.rebuildEngine()
        }
    }

    // MARK: - VAD (Step 5)

    func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool) {
        self.vadAutoStop = autoStop
        self.vadSilenceTimeout = silenceTimeout
        self.vadSensitivity = sensitivity
        self.vadEnergyGate = energyGate

        // If VAD is already running mid-session, rebuild the detector with new config.
        if let detector = silenceDetector {
            var config = SmoothedVADConfig.fromSensitivity(sensitivity)
            if energyGate { config.energyGateThreshold = 0.005 }
            Task { await detector.updateConfig(config) }
        }
    }

    func getSamplesSnapshot(fromIndex: Int, reply: @escaping (Data, Int) -> Void) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            let (samples, totalCount) = await self.captureManager.getSamplesSnapshot(fromIndex: fromIndex)
            let data = samples.withUnsafeBytes { Data($0) }
            safeReply(data, totalCount)
        }
    }

    func getVADSegments(reply: @escaping (Data) -> Void) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor [weak self] in
            guard let self, let detector = self.silenceDetector else {
                safeReply(Data())
                return
            }
            // Finalize any open segment before returning.
            let totalCount = self.captureManager.capturedSamples.count
            await detector.finalizeSegments(totalSampleCount: totalCount)
            let segments = await detector.speechSegments

            // Encode as packed [Int32 start, Int32 end] pairs.
            var packed = Data(capacity: segments.count * MemoryLayout<Int32>.size * 2)
            for seg in segments {
                var start = Int32(seg.startSample)
                var end = Int32(seg.endSample)
                packed.append(Data(bytes: &start, count: MemoryLayout<Int32>.size))
                packed.append(Data(bytes: &end, count: MemoryLayout<Int32>.size))
            }
            safeReply(packed)
        }
    }

    // MARK: - Service-side VAD monitoring (Step 5)

    /// Start the VAD monitoring task. Called after beginCapture succeeds.
    @MainActor
    private func startVADMonitoring() {
        var config = SmoothedVADConfig.fromSensitivity(vadSensitivity)
        if vadEnergyGate { config.energyGateThreshold = 0.005 }

        let detector = SilenceDetector(silenceTimeout: vadSilenceTimeout, vadConfig: config)
        self.silenceDetector = detector

        vadMonitorTask = Task { @MainActor [weak self] in
            // Prepare the VAD model
            do {
                try await detector.prepare()
            } catch {
                return
            }

            await detector.reset()

            var processedSampleCount = 0
            let chunkSize = SilenceDetector.chunkSize

            while !Task.isCancelled {
                guard let self else { return }
                let manager = self.captureManager
                guard manager.isCapturing else { return }

                let currentCount = manager.capturedSamples.count

                while processedSampleCount + chunkSize <= currentCount && !Task.isCancelled {
                    let endIdx = processedSampleCount + chunkSize
                    let chunk = Array(manager.capturedSamples[processedSampleCount..<endIdx])

                    let shouldStop = await detector.processChunk(chunk)

                    if shouldStop && self.vadAutoStop {
                        // Fire vadAutoStopTriggered to the host app.
                        self.xpcSendQueue.async { [weak self] in
                            self?.clientProxy?.vadAutoStopTriggered()
                        }
                        return
                    }

                    processedSampleCount += chunkSize
                    await Task.yield()
                }

                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Cancel VAD monitoring. Called on stopCapture and abortPreWarm.
    @MainActor
    private func cancelVADMonitoring() {
        vadMonitorTask?.cancel()
        vadMonitorTask = nil
    }
}
