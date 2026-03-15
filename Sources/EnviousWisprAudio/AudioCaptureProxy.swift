@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation

/// XPC-backed implementation of `AudioCaptureInterface`.
///
/// Bridges the in-process `AudioCaptureInterface` contract to XPC calls against the
/// embedded `EnviousWisprAudioService`. Real audio capture runs in the service process;
/// the proxy handles connection lifecycle, buffer reconstruction, and state management.
///
/// **Connection lifecycle (Step 1.5 design rules):**
/// - `interruptionHandler`: if capturing → user-visible failure (reset state, fire onEngineInterrupted).
///   If idle → transient (set needsReinit only). Always keep the same connection.
/// - `invalidationHandler`: terminal — nil connection, recreate on next use.
@MainActor
@Observable
public final class AudioCaptureProxy: AudioCaptureInterface {

    // MARK: - Observable state

    public private(set) var isCapturing = false
    public private(set) var audioLevel: Float = 0.0

    /// Step 3: returns [] — samples accumulate in the service process.
    /// Step 5 will add getSamplesSnapshot XPC method for incremental access.
    public private(set) var capturedSamples: [Float] = []

    // MARK: - Callbacks

    public var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
    public var onEngineInterrupted: (() -> Void)?

    // MARK: - Configuration (stored locally, forwarded to service)

    public var noiseSuppressionEnabled = false
    public var selectedInputDeviceUID: String = ""
    public var preferredInputDeviceIDOverride: String = ""

    // MARK: - XPC connection state

    private var connection: NSXPCConnection?
    private var needsReinit = false

    /// AsyncStream continuation for buffer delivery from service → pipeline.
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// Generation counter to reject stale callbacks from previous capture sessions.
    /// Incremented on beginCapturePhase, stopCapture, and interruption.
    /// Checked in audioBufferCaptured (inside @MainActor Task) before yielding.
    private var captureGeneration: UInt64 = 0

    /// The generation that was active when the current capture session began.
    /// Set in beginCapturePhase, compared in audioBufferCaptured.
    private var activeCaptureGeneration: UInt64 = 0

    /// 16kHz mono Float32 format used for buffer reconstruction.
    /// Matches AudioCaptureManager.targetSampleRate / targetChannels.
    nonisolated(unsafe) private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    public init() {}

    // MARK: - Core lifecycle

    public func startEnginePhase() async throws {
        ensureConnection()
        resendConfigIfNeeded()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let guard_ = OneShotContinuation(cont)
            serviceProxy { proxy in
                proxy.startEnginePhase(
                    preferredDeviceUID: self.preferredInputDeviceIDOverride,
                    selectedDeviceUID: self.selectedInputDeviceUID
                ) { nsError in
                    if let error = nsError { guard_.resume(throwing: error) }
                    else { guard_.resume() }
                }
            } onProxyError: {
                guard_.resume(throwing: XPCTransportError.serviceUnreachable)
            }
        }
    }

    public func beginCapturePhase() async throws -> AsyncStream<AVAudioPCMBuffer> {
        ensureConnection()

        // Finish any stale continuation from a previous session.
        bufferContinuation?.finish()
        bufferContinuation = nil

        captureGeneration &+= 1
        activeCaptureGeneration = captureGeneration

        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self.bufferContinuation = continuation
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let guard_ = OneShotContinuation(cont)
            serviceProxy { proxy in
                proxy.beginCapture { nsError in
                    if let error = nsError { guard_.resume(throwing: error) }
                    else { guard_.resume() }
                }
            } onProxyError: {
                guard_.resume(throwing: XPCTransportError.serviceUnreachable)
            }
        }

        isCapturing = true
        return stream
    }

    public func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard !isCapturing else { return AsyncStream { $0.finish() } }
        try await startEnginePhase()
        return try await beginCapturePhase()
    }

    public func stopCapture() async -> [Float] {
        // Bump generation so stale callbacks from this session don't leak into the next.
        captureGeneration &+= 1

        var result: [Float] = []
        do {
            result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[Float], any Error>) in
                let guard_ = OneShotContinuation(cont)
                serviceProxy { proxy in
                    proxy.stopCapture { data in
                        guard_.resume(returning: Self.dataToFloats(data))
                    }
                } onProxyError: {
                    guard_.resume(returning: [])
                }
            }
        } catch {
            // XPC error — service crashed during stopCapture. Samples are lost.
            // The interruptionHandler fires independently and handles pipeline notification.
            // Do NOT call onEngineInterrupted here to avoid double-firing.
            Task { await AppLogger.shared.log(
                "[AudioCaptureProxy] stopCapture failed — service unreachable, samples lost: \(error)",
                level: .info, category: "XPC"
            ) }
        }

        isCapturing = false
        audioLevel = 0
        bufferContinuation?.finish()
        bufferContinuation = nil
        return result
    }

    public func rebuildEngine() {
        serviceProxy { proxy in proxy.rebuildEngine() }
    }

    public func buildEngine(noiseSuppression: Bool) {
        noiseSuppressionEnabled = noiseSuppression
        ensureConnection()
        resendConfigIfNeeded()
        serviceProxy { proxy in proxy.buildEngine(noiseSuppression: noiseSuppression) }
    }

    public func preWarm() async {
        ensureConnection()
        resendConfigIfNeeded()
        // Phase 1: start engine
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                let guard_ = OneShotContinuation(cont)
                serviceProxy { proxy in
                    proxy.startEnginePhase(
                        preferredDeviceUID: self.preferredInputDeviceIDOverride,
                        selectedDeviceUID: self.selectedInputDeviceUID
                    ) { nsError in
                        if let error = nsError { guard_.resume(throwing: error) }
                        else { guard_.resume() }
                    }
                } onProxyError: {
                    guard_.resume(throwing: XPCTransportError.serviceUnreachable)
                }
            }
        } catch {
            Task { await AppLogger.shared.log(
                "[AudioCaptureProxy] preWarm failed: \(error)",
                level: .info, category: "XPC"
            ) }
            return
        }
        // Phase 2: wait for format stabilization
        _ = await waitForFormatStabilization(maxWait: 1.5, pollInterval: 0.2)
    }

    public func abortPreWarm() {
        serviceProxy { proxy in proxy.abortPreWarm() }
    }

    public func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            serviceProxy { proxy in
                proxy.waitForFormatStabilization(maxWait: maxWait, pollInterval: pollInterval) { result in
                    cont.resume(returning: result)
                }
            } onProxyError: {
                cont.resume(returning: false)
            }
        }
    }

    // MARK: - Config re-send after crash

    /// Replays configuration to the service after a crash/relaunch.
    /// Only clears needsReinit after successful replay. If the replay fails
    /// (e.g., service crashes during replay), needsReinit stays true so the
    /// next attempt retries.
    private func resendConfigIfNeeded() {
        guard needsReinit else { return }
        serviceProxy { [self] proxy in
            proxy.buildEngine(noiseSuppression: noiseSuppressionEnabled)
            // Device UIDs are passed inline to startEnginePhase — no separate replay needed.
            needsReinit = false
        }
    }

    // MARK: - XPC connection management

    private func ensureConnection() {
        guard connection == nil else { return }

        let conn = NSXPCConnection(serviceName: XPCServiceName.audioService)
        conn.remoteObjectInterface = NSXPCInterface(with: AudioServiceProtocol.self)
        conn.exportedInterface = NSXPCInterface(with: AudioServiceClientProtocol.self)
        conn.exportedObject = self

        // DESIGN RULE: Interruption while isCapturing == true is a user-visible capture failure.
        // Interruption while idle is transient — just set needsReinit.
        //
        // IMPORTANT(Step 3+): Step 1.5 proved kill -9 fires interruptionHandler for embedded
        // XPC services. During active capture, this IS the crash signal. The connection stays
        // valid — the next XPC call auto-relaunches the service via launchd.
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isCapturing {
                    self.isCapturing = false
                    self.audioLevel = 0
                    self.captureGeneration &+= 1
                    self.bufferContinuation?.finish()
                    self.bufferContinuation = nil
                    self.onEngineInterrupted?()
                }
                self.needsReinit = true
            }
        }

        // Terminal — only fires if we call invalidate() or service binary is missing.
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connection = nil
                if self.isCapturing {
                    self.isCapturing = false
                    self.audioLevel = 0
                    self.captureGeneration &+= 1
                    self.bufferContinuation?.finish()
                    self.bufferContinuation = nil
                    self.onEngineInterrupted?()
                }
                self.needsReinit = true
            }
        }

        conn.resume()
        connection = conn

        // Verify service is alive — this ping triggers launchd to spawn the service.
        serviceProxy { proxy in proxy.ping { _ in } }
    }

    /// Gets the remote proxy with error handling.
    /// `onProxyError` is called if the proxy can't be obtained (connection nil or cast fails).
    private func serviceProxy(
        _ work: (any AudioServiceProtocol) -> Void,
        onProxyError: (() -> Void)? = nil
    ) {
        guard let conn = connection else { onProxyError?(); return }
        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            Task { await AppLogger.shared.log(
                "[AudioCaptureProxy] XPC error: \(error.localizedDescription)",
                level: .info, category: "XPC"
            ) }
        }
        guard let service = proxy as? AudioServiceProtocol else { onProxyError?(); return }
        work(service)
    }

    // MARK: - Data conversion

    /// Convert [Float] to raw Data. Transport format: Float32 PCM, non-interleaved mono, 16kHz.
    /// Data is raw bytes — no header, no metadata.
    private static func dataToFloats(_ data: Data) -> [Float] {
        guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

// MARK: - AudioServiceClientProtocol (service → host callbacks)

/// These callbacks arrive on an XPC dispatch queue (not RT, not main).
/// Each hops to @MainActor via Task before updating observable state.
extension AudioCaptureProxy: AudioServiceClientProtocol {

    /// Received audio buffer from service — reconstruct AVAudioPCMBuffer and deliver.
    nonisolated public func audioBufferCaptured(_ data: Data, frameCount: Int, audioLevel: Float) {
        // Validation guards before memcpy.
        guard frameCount > 0, frameCount <= 65536 else { return }
        guard data.count == frameCount * MemoryLayout<Float>.size else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            guard let src = raw.baseAddress, let dst = buffer.floatChannelData?[0] else { return }
            memcpy(dst, src, data.count)
        }

        nonisolated(unsafe) let safeBuffer = buffer
        // Snapshot frameCount for generation check inside the MainActor Task.
        // captureGeneration is read inside the Task (MainActor-isolated), not here.

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Reject stale callbacks from previous capture sessions.
            guard self.isCapturing,
                  self.captureGeneration == self.activeCaptureGeneration else { return }
            self.audioLevel = audioLevel
            self.bufferContinuation?.yield(safeBuffer)
            self.onBufferCaptured?(safeBuffer)
        }
    }

    /// Service's audio engine was interrupted (device disconnect, emergency teardown).
    nonisolated public func engineInterrupted() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.isCapturing {
                self.isCapturing = false
                self.audioLevel = 0
                self.captureGeneration &+= 1
                self.bufferContinuation?.finish()
                self.bufferContinuation = nil
            }
            self.onEngineInterrupted?()
            self.needsReinit = true
        }
    }
}

// MARK: - Helpers

/// Thread-safe one-shot continuation guard. Ensures exactly one resume,
/// preventing crashes from double-resume when XPC reply and error handler race.
private final class OneShotContinuation<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, any Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
}

/// Convenience overload for Void continuations.
extension OneShotContinuation where T == Void {
    func resume() {
        resume(returning: ())
    }
}

/// XPC transport errors surfaced by the proxy.
enum XPCTransportError: LocalizedError {
    case serviceUnreachable

    var errorDescription: String? {
        switch self {
        case .serviceUnreachable: return "XPC audio service is unreachable."
        }
    }
}
