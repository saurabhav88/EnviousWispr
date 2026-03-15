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

            // RMS: tight arithmetic loop — no allocation, RT-safe.
            // Matches AudioBufferProcessor.calculateRMS formula: -60dB..0dB → 0..1
            var sum: Float = 0
            for i in 0..<count { sum += floatData[i] * floatData[i] }
            let rms = sqrt(sum / Float(count))
            let dBFS = 20 * log10(max(rms, 1e-6))
            let level = max(0, min(1, (dBFS + 60) / 60))

            // Data(bytes:count:) = single malloc + memcpy. Bounded at ~16KB per buffer.
            // Tolerable on the RT thread per Apple guidance (fixed-size, no realloc).
            let data = Data(bytes: floatData, count: count * MemoryLayout<Float>.size)

            self?.xpcSendQueue.async { [weak self] in
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
                _ = try await captureManager.beginCapturePhase()
                safeReply(nil)
            } catch {
                safeReply(error as NSError)
            }
        }
    }

    func stopCapture(reply: @escaping (Data) -> Void) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            let samples = await captureManager.stopCapture()
            // Transport format: raw Float32 bytes, non-interleaved mono, 16kHz.
            let data = samples.withUnsafeBytes { Data($0) }
            safeReply(data)
        }
    }

    func abortPreWarm() {
        Task { @MainActor in
            captureManager.abortPreWarm()
        }
    }

    func rebuildEngine() {
        Task { @MainActor in
            captureManager.rebuildEngine()
        }
    }
}
