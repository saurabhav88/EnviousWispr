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
    public var onVADAutoStop: (() -> Void)?

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
    /// Clears needsReinit after the XPC call is dispatched. Note: buildEngine is fire-and-forget
    /// (no reply handler), so we cannot detect if the service actually processed the config.
    /// If the service crashes during replay, the next interruptionHandler will re-set needsReinit.
    /// This is acceptable because buildEngine is idempotent — replay on next attempt is safe.
    private func resendConfigIfNeeded() {
        guard needsReinit else { return }
        serviceProxy { [self] proxy in
            proxy.buildEngine(noiseSuppression: noiseSuppressionEnabled)
            // Replay VAD config so service rebuilds its SilenceDetector after crash.
            if let vad = vadConfig {
                proxy.configureVAD(autoStop: vad.autoStop, silenceTimeout: vad.silenceTimeout,
                                   sensitivity: vad.sensitivity, energyGate: vad.energyGate)
            }
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
        // CRITICAL: interruptionHandler and invalidationHandler run on XPC dispatch queues,
        // NOT MainActor. Closures defined inside @MainActor methods inherit that isolation in
        // Swift 6, causing dispatch_assert_queue_fail when XPC calls them. Extract to
        // nonisolated static to break the isolation inheritance.
        conn.interruptionHandler = Self.makeInterruptionHandler(proxy: self)
        conn.invalidationHandler = Self.makeInvalidationHandler(proxy: self)

        conn.resume()
        connection = conn

        // Verify service is alive — this ping triggers launchd to spawn the service.
        serviceProxy { proxy in proxy.ping { _ in } }
    }

    /// Gets the remote proxy with error handling.
    /// `onProxyError` is called if the proxy can't be obtained (connection nil or cast fails)
    /// AND if the XPC framework delivers a per-call error (service crashed mid-call).
    /// This is critical: when the service dies after a call is dispatched but before it replies,
    /// the XPC error handler fires but the reply handler does NOT. Without routing the error
    /// to `onProxyError`, any pending continuation hangs forever.
    private func serviceProxy(
        _ work: (any AudioServiceProtocol) -> Void,
        onProxyError: (() -> Void)? = nil
    ) {
        guard let conn = connection else { onProxyError?(); return }
        let proxy = conn.remoteObjectProxyWithErrorHandler(Self.makeXPCErrorHandler(onProxyError: onProxyError))
        guard let service = proxy as? AudioServiceProtocol else { onProxyError?(); return }
        work(service)
    }

    /// Build the XPC error handler in a nonisolated context.
    /// Critical: closures defined inside @MainActor methods inherit that isolation.
    /// When XPC calls the error handler on its dispatch queue, Swift 6 asserts
    /// dispatch_assert_queue(main) and traps with EXC_BREAKPOINT. By constructing
    /// the handler in a nonisolated static method, the closure is free of @MainActor.
    /// Build the XPC per-call error handler in a nonisolated context.
    /// This handler fires when the service crashes after a call is dispatched but before it replies.
    /// It MUST call onProxyError to resume any pending continuation — otherwise the caller hangs forever.
    /// The error handler is the primary recovery signal; interruption/invalidation are secondary cleanup.
    nonisolated private static func makeXPCErrorHandler(onProxyError: (() -> Void)? = nil) -> @Sendable (any Error) -> Void {
        // Capture onProxyError as nonisolated(unsafe) — it may reference @MainActor closures
        // but we dispatch it via Task { @MainActor } so the actual call is safe.
        nonisolated(unsafe) let proxyError = onProxyError
        return { error in
            Task { @MainActor in
                await AppLogger.shared.log(
                    "[AudioCaptureProxy] XPC error: \(error.localizedDescription)",
                    level: .info, category: "XPC"
                )
                proxyError?()
            }
        }
    }

    /// Build the XPC interruptionHandler in a nonisolated context.
    /// Same isolation-escape pattern as makeXPCErrorHandler.
    nonisolated private static func makeInterruptionHandler(proxy: AudioCaptureProxy) -> @Sendable () -> Void {
        return { [weak proxy] in

            Task { @MainActor [weak proxy] in
                guard let proxy else { return }
                if proxy.isCapturing {
                    proxy.isCapturing = false
                    proxy.audioLevel = 0
                    proxy.captureGeneration &+= 1
                    proxy.bufferContinuation?.finish()
                    proxy.bufferContinuation = nil
                    proxy.onEngineInterrupted?()

                }
                proxy.needsReinit = true
            }
        }
    }

    /// Build the XPC invalidationHandler in a nonisolated context.
    nonisolated private static func makeInvalidationHandler(proxy: AudioCaptureProxy) -> @Sendable () -> Void {
        return { [weak proxy] in

            Task { @MainActor [weak proxy] in
                guard let proxy else { return }

                proxy.connection = nil
                if proxy.isCapturing {
                    proxy.isCapturing = false
                    proxy.audioLevel = 0
                    proxy.captureGeneration &+= 1
                    proxy.bufferContinuation?.finish()
                    proxy.bufferContinuation = nil
                    proxy.onEngineInterrupted?()
                }
                proxy.needsReinit = true
            }
        }
    }

    // MARK: - VAD Interface (Step 5)

    /// Stored VAD config — forwarded to service, replayed after crash via resendConfigIfNeeded().
    private var vadConfig: (autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool)?

    public func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool) {
        vadConfig = (autoStop, silenceTimeout, sensitivity, energyGate)
        serviceProxy { proxy in
            proxy.configureVAD(autoStop: autoStop, silenceTimeout: silenceTimeout, sensitivity: sensitivity, energyGate: energyGate)
        }
    }

    public func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) {
        // Use OneShotContinuation to guarantee exactly one resume — XPC error handler and
        // reply handler can race, and double-resume is undefined behavior.
        do {
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(samples: [Float], totalCount: Int), any Error>) in
                let guard_ = OneShotContinuation(cont)
                serviceProxy { proxy in
                    proxy.getSamplesSnapshot(fromIndex: fromIndex) { data, totalCount in
                        let floats = Self.dataToFloats(data)
                        guard_.resume(returning: (samples: floats, totalCount: totalCount))
                    }
                } onProxyError: {
                    guard_.resume(returning: (samples: [], totalCount: 0))
                }
            }
        } catch {
            return (samples: [], totalCount: 0)
        }
    }

    public func getVADSegments() async -> [SpeechSegment] {
        // Use OneShotContinuation to guarantee exactly one resume.
        do {
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[SpeechSegment], any Error>) in
                let guard_ = OneShotContinuation(cont)
                serviceProxy { proxy in
                    proxy.getVADSegments { data in
                        guard_.resume(returning: Self.decodeVADSegments(data))
                    }
                } onProxyError: {
                    guard_.resume(returning: [])
                }
            }
        } catch {
            return []
        }
    }

    // MARK: - Data conversion

    /// Convert raw Data to [Float]. Transport format: Float32 PCM, non-interleaved mono, 16kHz.
    /// Data is raw bytes — no header, no metadata.
    /// nonisolated: called from XPC reply callbacks which run on XPC dispatch queues, not MainActor.
    nonisolated private static func dataToFloats(_ data: Data) -> [Float] {
        guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Decode packed [Int32 start, Int32 end] pairs into SpeechSegment array.
    nonisolated private static func decodeVADSegments(_ data: Data) -> [SpeechSegment] {
        let pairSize = MemoryLayout<Int32>.size * 2
        guard !data.isEmpty, data.count.isMultiple(of: pairSize) else { return [] }
        return data.withUnsafeBytes { raw in
            let int32s = raw.bindMemory(to: Int32.self)
            var segments: [SpeechSegment] = []
            segments.reserveCapacity(int32s.count / 2)
            for i in stride(from: 0, to: int32s.count, by: 2) {
                segments.append(SpeechSegment(
                    startSample: Int(int32s[i]),
                    endSample: Int(int32s[i + 1])
                ))
            }
            return segments
        }
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
    /// Matches interruptionHandler contract: only fires onEngineInterrupted during active capture.
    /// Idle interruptions are transient — just set needsReinit.
    nonisolated public func engineInterrupted() {
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

    /// Service-side VAD detected sustained silence after speech — auto-stop should trigger.
    /// Stale-fire protection: generation check + pipeline state guard (in AppState handler).
    nonisolated public func vadAutoStopTriggered() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isCapturing,
                  self.captureGeneration == self.activeCaptureGeneration else { return }
            self.onVADAutoStop?()
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
