@preconcurrency import AVFoundation
import EnviousWisprCore
import Foundation

/// XPC-backed implementation of `AudioCaptureInterface`.
///
/// **Step 2 scope:** This is a proxy shell with interface parity only.
/// All capture methods are stubs — they do not record audio. Real capture
/// transport is added in Step 3. The proxy proves:
/// - feature-flag implementation selection works
/// - XPC connection lifecycle is correct (interruption vs invalidation)
/// - the proxy can be injected wherever AudioCaptureManager was used
///
/// **Connection lifecycle (Step 1.5 design rules):**
/// - `interruptionHandler`: transient — keep the same connection, mark `needsReinit`,
///   fire `onEngineInterrupted`. Next XPC call auto-relaunches the service.
/// - `invalidationHandler`: terminal — nil the connection, recreate on next use.
/// - All XPC calls use `remoteObjectProxyWithErrorHandler` (error 4097 on in-flight crash).
@MainActor
@Observable
public final class AudioCaptureProxy: AudioCaptureInterface {

    // MARK: - Observable state (Step 2: always default values)

    /// Step 2 stub: always false. Step 3 will update from service-side capture state.
    public private(set) var isCapturing = false

    /// Step 2 stub: always 0. Step 3 will receive levels via `audioLevelUpdated` callback.
    public private(set) var audioLevel: Float = 0.0

    /// Step 2 stub: always empty. Step 3 will accumulate samples in the service process.
    /// Step 5 adds `getSamplesSnapshot(fromIndex:)` for incremental access.
    public private(set) var capturedSamples: [Float] = []

    // MARK: - Callbacks (stored for interface parity, not fired in Step 2)

    /// Step 2 stub: stored but never called. Step 3 will reconstruct AVAudioPCMBuffer
    /// from XPC Data payloads and invoke this callback.
    public var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Fired when the XPC service crashes (interruptionHandler). Pipelines should
    /// transition to error state. This IS wired in Step 2 — crash recovery is live.
    public var onEngineInterrupted: (() -> Void)?

    // MARK: - Configuration (forwarded to service in Step 3)

    /// Step 2 stub: stored locally. Step 3 will forward to service on next call.
    public var noiseSuppressionEnabled = false

    /// Step 2 stub: stored locally. Step 3 will forward to service on next call.
    public var selectedInputDeviceUID: String = ""

    /// Step 2 stub: stored locally. Step 3 will forward to service on next call.
    public var preferredInputDeviceIDOverride: String = ""

    // MARK: - XPC connection

    private var connection: NSXPCConnection?

    /// True after service crash — next XPC call should re-send configuration.
    /// Step 2 does not re-send config (nothing to send), but the flag is wired
    /// so Step 3 can use it immediately.
    private var needsReinit = false

    public init() {}

    // MARK: - Core lifecycle (Step 2 stubs)

    /// Step 2 stub: connects to XPC service and verifies it's alive via ping().
    /// Does NOT start an audio engine or update isCapturing.
    /// Step 3 will call service-side buildEngine + startEnginePhase and throw on failure.
    ///
    /// Note: ping reply is intentionally discarded. If the service is unreachable,
    /// the error is logged via serviceProxy's error handler but not propagated as
    /// a thrown error. This is acceptable for Step 2 (stub) — Step 3 must add real
    /// error propagation when this method starts actual engine work.
    public func startEnginePhase() throws {
        ensureConnection()
        serviceProxy { proxy in
            proxy.ping { _ in }
        }
    }

    /// Step 2 stub: returns an immediately-finished stream.
    /// Does NOT install an audio tap or begin capture.
    /// Step 3 will call service-side beginCapture and bridge buffers via XPC callbacks.
    public func beginCapturePhase() throws -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { $0.finish() }
    }

    /// Step 2 stub: returns an immediately-finished stream.
    /// Does NOT capture audio. Step 3 will implement full two-phase startup via XPC.
    public func startCapture() throws -> AsyncStream<AVAudioPCMBuffer> {
        ensureConnection()
        return AsyncStream { $0.finish() }
    }

    /// Step 2 stub: returns empty samples.
    /// Does NOT stop a real recording. Step 3 will call service-side stopCapture
    /// and return the accumulated Float32 samples from the service process.
    public func stopCapture() -> [Float] {
        return []
    }

    /// Step 2 stub: no-op. Step 3 will call service-side rebuildEngine.
    public func rebuildEngine() {}

    /// Step 2 stub: stores the setting locally and verifies service connectivity.
    /// Step 3 will forward this to the service-side buildEngine for real engine rebuild.
    public func buildEngine(noiseSuppression: Bool) {
        noiseSuppressionEnabled = noiseSuppression
        ensureConnection()
    }

    /// Step 2 stub: connects to XPC service only. Does NOT pre-warm an audio engine.
    /// Step 3 will call service-side preWarm (engine start + format stabilization, no tap).
    public func preWarm() async {
        ensureConnection()
    }

    /// Step 2 stub: no-op. Step 3 will call service-side abortPreWarm.
    public func abortPreWarm() {}

    /// Step 2 stub: returns true immediately. Does NOT wait for hardware format stabilization.
    /// Step 3 will call service-side waitForFormatStabilization with real BT codec timing.
    public func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
        return true
    }

    // MARK: - XPC connection management

    /// Lazily creates the XPC connection and verifies the service is alive.
    /// The service process is spawned by launchd on the first XPC message (the ping below).
    private func ensureConnection() {
        guard connection == nil else { return }

        let conn = NSXPCConnection(serviceName: XPCServiceName.audioService)
        conn.remoteObjectInterface = NSXPCInterface(with: AudioServiceProtocol.self)
        conn.exportedInterface = NSXPCInterface(with: AudioServiceClientProtocol.self)
        conn.exportedObject = self

        // Step 1.5 rule: interruptionHandler = transient. Keep the connection.
        // The next XPC call on the same connection auto-relaunches the service.
        // Do NOT fire onEngineInterrupted here — interruption is recoverable.
        // Do NOT reset isCapturing here — a transient interruption during capture
        // should not silently drop the recording indicator.
        //
        // IMPORTANT(Step 3): Re-evaluate this when real capture moves to the service.
        // Step 1.5 proved that kill -9 fires interruptionHandler (not invalidationHandler)
        // for embedded XPC services. During active recording, a service crash via
        // interruption WILL need to reset capture state and notify pipelines — the current
        // "just set needsReinit" behavior is only appropriate for Step 2 stubs.
        // Options for Step 3: detect "interrupted during active capture" (isCapturing == true)
        // and treat that as a crash, or add a heartbeat/watchdog to distinguish transient
        // interruption from hard death.
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.needsReinit = true
            }
        }

        // Step 1.5 rule: invalidationHandler = terminal. Nil the connection.
        // This only fires if we call invalidate() or the service binary is missing.
        // This IS the crash/death signal — reset state and notify pipelines.
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connection = nil
                self.needsReinit = true
                self.isCapturing = false
                self.audioLevel = 0
                self.onEngineInterrupted?()
            }
        }

        conn.resume()
        connection = conn

        // Verify the service is alive. This is the first XPC message — launchd
        // spawns the service process in response to this call.
        serviceProxy { proxy in
            proxy.ping { _ in }
        }
    }

    /// Gets the remote proxy with error handling. Calls the block with the proxy,
    /// or logs the error if the service is unreachable.
    private func serviceProxy(_ work: (any AudioServiceProtocol) -> Void) {
        guard let conn = connection else { return }
        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            Task { await AppLogger.shared.log(
                "[AudioCaptureProxy] XPC error: \(error.localizedDescription)",
                level: .info, category: "XPC"
            ) }
        }
        guard let service = proxy as? AudioServiceProtocol else { return }
        work(service)
    }
}

// MARK: - AudioServiceClientProtocol (service → host callbacks)

extension AudioCaptureProxy: AudioServiceClientProtocol {
    /// Called by the XPC service with audio level updates.
    /// Step 2: wired but service does not send levels yet (no real capture).
    /// Step 3 will receive real levels piggybacked on buffer callbacks.
    nonisolated public func audioLevelUpdated(_ level: Float) {
        Task { @MainActor [weak self] in
            self?.audioLevel = level
        }
    }
}
