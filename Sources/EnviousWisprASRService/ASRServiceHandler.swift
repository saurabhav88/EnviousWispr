@preconcurrency import AVFoundation
import Foundation
import EnviousWisprCore
import EnviousWisprASR

/// XPC service handler for ASR transcription.
///
/// Owns ParakeetBackend (and WhisperKitBackend in Stage D). All inference runs in this
/// XPC service process — model memory is isolated from the main app.
final class ASRServiceHandler: NSObject, ASRServiceProtocol, @unchecked Sendable {
    weak var connection: NSXPCConnection?

    /// The active ASR backend — only one loaded at a time.
    private var parakeetBackend: ParakeetBackend?
    private var whisperKitBackend: WhisperKitBackend?
    private var activeBackendType: String?

    /// Streaming state flag — only Parakeet supports streaming.
    private var isStreamingActive = false

    /// Reusable audio format for buffer reconstruction in feedAudioBuffer.
    private let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!

    // MARK: - Diagnostics

    func ping(reply: @escaping (String) -> Void) {
        let fluidAudioPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models")
        let whisperKitPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
        let fluidAccess = FileManager.default.isReadableFile(atPath: fluidAudioPath.path)
        let whisperAccess = FileManager.default.isReadableFile(atPath: whisperKitPath.path)
        reply("pong — modelAccess: FluidAudio=\(fluidAccess), WhisperKit=\(whisperAccess)")
    }

    // MARK: - Model Lifecycle

    /// Get the client proxy for sending progress callbacks to the host app.
    private var clientProxy: ASRServiceClientProtocol? {
        connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? ASRServiceClientProtocol
    }

    func loadModel(backendType: String, modelVariant: String, reply: @escaping (NSError?) -> Void) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            do {
                // Unload previous backend before loading new one
                self.parakeetBackend = nil
                self.whisperKitBackend = nil

                switch backendType {
                case "parakeet":
                    let backend = ParakeetBackend()

                    // Decoupled push model for progress reporting:
                    // The URLSession delegate callback (from FluidAudio) must NEVER call XPC directly —
                    // Mach port queue exhaustion blocks the delegate thread, stalling the download.
                    // Instead: callback writes to a thread-safe snapshot, a DispatchSource timer
                    // samples it at 4 Hz and sends XPC messages from its own thread.
                    // Progress via shared file — bypasses XPC entirely.
                    // XPC serializes replies, so getDownloadProgress replies are blocked
                    // behind the pending loadModel reply. Writing to a file that the app
                    // reads on a timer is the only reliable cross-process progress path.
                    let progressFile = ProgressFile.shared
                    progressFile.clear()

                    try await backend.prepare { fraction, phase, detail in
                        // Hot path — runs on URLSession delegate thread. File write is fast.
                        progressFile.write(fraction: fraction, phase: phase, detail: detail)
                    }

                    progressFile.write(fraction: 1.0, phase: "", detail: "")

                    self.parakeetBackend = backend
                case "whisperKit":
                    let variant = modelVariant.isEmpty ? "openai_whisper-large-v3_turbo" : modelVariant
                    let backend = WhisperKitBackend(modelVariant: variant)
                    try await backend.prepare()
                    self.whisperKitBackend = backend
                default:
                    safeReply(NSError(domain: "ASRService", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown backend: \(backendType)"]))
                    return
                }
                self.activeBackendType = backendType
                safeReply(nil)
            } catch {
                safeReply(error as NSError)
            }
        }
    }

    func unloadModel(reply: @escaping () -> Void) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            if let wk = self.whisperKitBackend {
                await wk.unload()
            }
            self.parakeetBackend = nil
            self.whisperKitBackend = nil
            self.activeBackendType = nil
            safeReply()
        }
    }

    func getModelState(reply: @escaping (Bool, Bool) -> Void) {
        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            let isLoaded = self.parakeetBackend != nil || self.whisperKitBackend != nil
            safeReply(isLoaded, self.isStreamingActive)
        }
    }

    // MARK: - Batch Transcription

    func transcribeSamples(_ data: Data, sampleCount: Int, language: String, enableTimestamps: Bool, reply: @escaping (Data?, NSError?) -> Void) {
        nonisolated(unsafe) let safeReply = reply

        // Validate input
        guard data.count == sampleCount * MemoryLayout<Float>.size else {
            safeReply(nil, NSError(domain: "ASRService", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Data size mismatch: expected \(sampleCount * MemoryLayout<Float>.size), got \(data.count)"]))
            return
        }

        Task { @MainActor in
            do {
                // Convert Data → [Float]
                let samples = data.withUnsafeBytes { raw -> [Float] in
                    guard raw.count > 0 else { return [] }
                    return Array(raw.bindMemory(to: Float.self))
                }

                var options = TranscriptionOptions()
                options.language = language.isEmpty ? nil : language
                options.enableTimestamps = enableTimestamps

                // Route to the active backend
                let result: EnviousWisprCore.ASRResult
                if let parakeet = self.parakeetBackend {
                    result = try await parakeet.transcribe(audioSamples: samples, options: options)
                } else if let whisperKit = self.whisperKitBackend {
                    result = try await whisperKit.transcribe(audioSamples: samples, options: options)
                } else {
                    safeReply(nil, NSError(domain: "ASRService", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "No model loaded"]))
                    return
                }

                // Encode ASRResult → Data via PropertyListEncoder
                let encoded = try PropertyListEncoder().encode(result)
                safeReply(encoded, nil)
            } catch {
                safeReply(nil, error as NSError)
            }
        }
    }

    // MARK: - Streaming

    func startStreaming(language: String, enableTimestamps: Bool, reply: @escaping (NSError?) -> Void) {
        guard let parakeet = parakeetBackend else {
            reply(NSError(domain: "ASRService", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "No Parakeet model loaded for streaming"]))
            return
        }

        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            do {
                var options = TranscriptionOptions()
                options.language = language.isEmpty ? nil : language
                options.enableTimestamps = enableTimestamps
                try await parakeet.startStreaming(options: options)
                self.isStreamingActive = true
                safeReply(nil)
            } catch {
                safeReply(error as NSError)
            }
        }
    }

    func feedAudioBuffer(_ data: Data, frameCount: Int) {
        guard isStreamingActive, let parakeet = parakeetBackend else { return }
        guard data.count == frameCount * MemoryLayout<Float>.size else { return }

        // Reconstruct AVAudioPCMBuffer from raw Float32 data
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            buffer.floatChannelData![0].update(from: src, count: frameCount)
        }

        nonisolated(unsafe) let unsafeBuffer = buffer
        Task { try? await parakeet.feedAudio(unsafeBuffer) }
    }

    func finalizeStreaming(reply: @escaping (Data?, NSError?) -> Void) {
        guard isStreamingActive, let parakeet = parakeetBackend else {
            reply(nil, NSError(domain: "ASRService", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "No active streaming session"]))
            return
        }

        nonisolated(unsafe) let safeReply = reply
        Task { @MainActor in
            do {
                let result = try await parakeet.finalizeStreaming()
                self.isStreamingActive = false
                let encoded = try PropertyListEncoder().encode(result)
                safeReply(encoded, nil)
            } catch {
                self.isStreamingActive = false
                safeReply(nil, error as NSError)
            }
        }
    }

    func cancelStreaming() {
        guard isStreamingActive, let parakeet = parakeetBackend else { return }
        isStreamingActive = false
        Task { await parakeet.cancelStreaming() }
    }

    // MARK: - Download Progress Polling

    /// Thread-safe snapshot of current download progress, written by the download callback,
    /// read by the host app via getDownloadProgress polling.
    private let pollableProgress = ProgressSnapshot()

    func getDownloadProgress(reply: @escaping (Double, String, String) -> Void) {
        if let state = pollableProgress.peek() {
            reply(state.fraction, state.phase, state.detail)
        } else {
            reply(0, "", "")
        }
    }

    // MARK: - Capability

    func checkStreamingSupport(backendType: String, reply: @escaping (Bool) -> Void) {
        reply(backendType == "parakeet")
    }
}

// MARK: - Decoupled Progress Publisher

/// Thread-safe progress snapshot. Written by FluidAudio's URLSession delegate thread,
/// read by the ProgressPublisher timer. Lock-based — zero overhead on the hot path.
private final class ProgressSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var _fraction: Double = 0
    private var _phase: String = ""
    private var _detail: String = ""
    private var _changed = false

    func update(fraction: Double, phase: String, detail: String) {
        lock.lock()
        _fraction = fraction
        _phase = phase
        _detail = detail
        _changed = true
        lock.unlock()
    }

    /// Read latest snapshot and clear the changed flag.
    /// Returns nil if nothing changed since last read.
    func consume() -> (fraction: Double, phase: String, detail: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard _changed else { return nil }
        _changed = false
        return (_fraction, _phase, _detail)
    }

    /// Read latest snapshot WITHOUT clearing the changed flag.
    /// Used by the polling path (getDownloadProgress) to return current state.
    func peek() -> (fraction: Double, phase: String, detail: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard _fraction > 0 || !_phase.isEmpty else { return nil }
        return (_fraction, _phase, _detail)
    }
}

/// Samples ProgressSnapshot at 4 Hz and sends XPC messages to the host app.
/// Runs on its own DispatchSource timer — completely decoupled from the download thread.
/// The URLSession delegate thread never pays XPC Mach port backpressure costs.
private final class ProgressPublisher: @unchecked Sendable {
    private let snapshot: ProgressSnapshot
    private let client: ASRServiceClientProtocol?
    private let timer: DispatchSourceTimer
    private let queue = DispatchQueue(label: "com.enviouswispr.asr.progress-publisher", qos: .userInteractive)

    init(snapshot: ProgressSnapshot, client: ASRServiceClientProtocol?) {
        self.snapshot = snapshot
        self.client = client
        self.timer = DispatchSource.makeTimerSource(queue: queue)
    }

    func start() {
        timer.schedule(deadline: .now(), repeating: 0.25) // 4 Hz
        timer.setEventHandler { [weak self] in
            guard let self, let state = self.snapshot.consume() else { return }
            self.client?.reportDownloadProgress(state.fraction, phase: state.phase, detail: state.detail)
        }
        timer.resume()
    }

    func stop() {
        timer.cancel()
        // Flush any remaining state
        if let state = snapshot.consume() {
            client?.reportDownloadProgress(state.fraction, phase: state.phase, detail: state.detail)
        }
    }
}
