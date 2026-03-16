@preconcurrency import AVFoundation
import EnviousWisprCore
import CoreAudio
import os

/// Manages audio capture from the microphone — thin coordinator over AudioInputSource backends.
///
/// Owns app-facing state (capturedSamples, audioLevel, isCapturing) and the
/// `AudioCaptureInterface` contract. Delegates all hardware interaction to the
/// active `AudioInputSource` (currently `AVAudioEngineSource`; `AVCaptureSessionSource`
/// will be added in Step 6b.3).
///
/// **Ownership boundaries:**
/// - Sources own hardware/session/engine lifecycle, conversion, tap logic, recovery
/// - Manager owns capture state exposed to the rest of the app
/// - Manager does NOT contain conversion logic, tap logic, or route-specific recovery
@MainActor
@Observable
public final class AudioCaptureManager: AudioCaptureInterface {
    /// Current recording state.
    public private(set) var isCapturing = false

    /// Current audio level (0.0 - 1.0) for waveform visualization.
    public private(set) var audioLevel: Float = 0.0

    /// Accumulated audio samples from the current recording.
    public private(set) var capturedSamples: [Float] = []

    /// Optional callback to forward converted audio buffers (e.g., to streaming ASR).
    /// Called on the audio thread — must be @Sendable.
    public var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Called on the main actor when the audio engine is interrupted (e.g., device disconnect).
    /// The pipeline should transition to an error state when this fires.
    public var onEngineInterrupted: (() -> Void)?

    /// Called when service-side VAD detects sustained silence after speech.
    /// No-op for in-process capture — VAD runs in the pipeline's monitorVAD() loop instead.
    public var onVADAutoStop: (() -> Void)?

    /// Whether noise suppression via Apple Voice Processing is enabled.
    public var noiseSuppressionEnabled = false

    /// Persistent UID of the selected input device. Empty string means system default.
    public var selectedInputDeviceUID: String = ""

    /// User override for input device. Empty string means "Auto" (smart selection enabled).
    public var preferredInputDeviceIDOverride: String = ""

    /// Maximum recording duration in seconds. Prevents unbounded memory growth.
    public nonisolated static let maxRecordingDurationSeconds: Double = 600
    /// Maximum sample count derived from maxRecordingDurationSeconds at 16kHz.
    public nonisolated static let maxRecordingSamples: Int = Int(maxRecordingDurationSeconds * targetSampleRate)

    /// Target format: 16kHz, mono, Float32 — required by both Parakeet and WhisperKit.
    public nonisolated static let targetSampleRate: Double = 16000
    public nonisolated static let targetChannels: AVAudioChannelCount = 1

    /// The active capture source. Created on buildEngine/startEnginePhase.
    private var activeSource: AVAudioEngineSource?

    /// AsyncStream continuation for buffer delivery to pipelines.
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    public init() {}

    // MARK: - AudioCaptureInterface

    public func startEnginePhase() async throws {
        let source = ensureSource()
        try await source.prepare()
    }

    public func beginCapturePhase() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard let source = activeSource else {
            throw AudioError.formatCreationFailed
        }

        // Pre-allocate sample buffer
        capturedSamples = []
        capturedSamples.reserveCapacity(16000 * 30)
        audioLevel = 0.0

        // Wire source callbacks → manager state
        let maxSamples = Self.maxRecordingSamples
        source.onSamples = { [weak self] samples, level in
            Task { @MainActor in
                guard let self, self.isCapturing else { return }
                self.audioLevel = level
                self.capturedSamples.append(contentsOf: samples)
                if self.capturedSamples.count >= maxSamples {
                    await AppLogger.shared.log(
                        "Max recording duration reached (\(Self.maxRecordingDurationSeconds)s) — auto-stopping",
                        level: .info, category: "Audio"
                    )
                    self.isCapturing = false
                    self.audioLevel = 0.0
                    self.onEngineInterrupted?()
                }
            }
        }
        source.onBufferCaptured = onBufferCaptured
        source.onInterrupted = { [weak self] in
            guard let self else { return }
            self.isCapturing = false
            self.audioLevel = 0.0
            self.onEngineInterrupted?()
        }

        let stream = try await source.startCapture()
        isCapturing = true
        return stream
    }

    public func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard !isCapturing else {
            return AsyncStream { $0.finish() }
        }
        try await startEnginePhase()
        return try await beginCapturePhase()
    }

    public func stopCapture() async -> [Float] {
        guard let source = activeSource else {
            let samples = capturedSamples
            capturedSamples = []
            return samples
        }

        isCapturing = false
        audioLevel = 0.0
        let sourceSamples = await source.stop()

        // Source accumulated samples internally — merge with any manager-side samples
        // (in practice, samples come from the source's onSamples callback → manager.capturedSamples)
        let samples = capturedSamples
        capturedSamples = []
        return samples
    }

    public func rebuildEngine() {
        activeSource?.rebuild()
    }

    public func buildEngine(noiseSuppression: Bool) {
        let source = ensureSource()
        source.buildEngine(noiseSuppression: noiseSuppression)
        noiseSuppressionEnabled = noiseSuppression
    }

    public func preWarm() async {
        let source = ensureSource()
        guard !source.isRunning else { return }
        do {
            try await source.prepare()
        } catch {
            Task { await AppLogger.shared.log(
                "Audio pre-warm failed: \(error.localizedDescription)",
                level: .info, category: "Audio"
            ) }
            return
        }
        _ = await source.waitForFormatStabilization(maxWait: 1.5, pollInterval: 0.2)
    }

    public func abortPreWarm() {
        activeSource?.abortPrepare()
    }

    public func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool {
        guard let source = activeSource else { return true }
        return await source.waitForFormatStabilization(maxWait: maxWait, pollInterval: pollInterval)
    }

    /// Inject pre-recorded samples directly into the capture buffer for benchmark/testing.
    public func injectSamples(_ samples: [Float]) {
        capturedSamples = samples
    }

    /// Track a spawned Task so it can be cancelled during teardown.
    public func trackTask(_ task: Task<Void, Never>) {
        activeSource?.trackTask(task)
    }

    // MARK: - Source Management

    private func ensureSource() -> AVAudioEngineSource {
        if let source = activeSource { return source }
        let source = AVAudioEngineSource()
        source.noiseSuppressionEnabled = noiseSuppressionEnabled
        source.selectedInputDeviceUID = selectedInputDeviceUID
        source.preferredInputDeviceIDOverride = preferredInputDeviceIDOverride
        activeSource = source
        return source
    }

    // MARK: - BT Route Logging (Step 6 instrumentation)

    /// Direct file write for BT route diagnostics. os_log info level is suppressed on macOS 26 beta,
    /// and AppLogger.shared is process-local (XPC service has its own instance).
    nonisolated static func btRouteLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [BTRoute] \(message)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/EnviousWispr/bt-route.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    // MARK: - VAD Interface (Step 5)

    /// No-op for in-process capture. The in-process path manages VAD entirely through
    /// pipeline-owned properties (vadAutoStop, vadSensitivity, etc.) and the pipeline's
    /// monitorVAD() loop. The capture manager never runs VAD itself.
    /// Exists solely for AudioCaptureInterface protocol conformance.
    public func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool) {
        // Intentional no-op — see comment above.
    }

    /// Returns a slice of capturedSamples starting at fromIndex plus the current total count.
    /// Both values are from the same snapshot moment for consistency.
    public func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int) {
        let totalCount = capturedSamples.count
        let clampedIndex = max(0, min(fromIndex, totalCount))
        if clampedIndex >= totalCount {
            return (samples: [], totalCount: totalCount)
        }
        let slice = Array(capturedSamples[clampedIndex..<totalCount])
        return (samples: slice, totalCount: totalCount)
    }

    /// Returns empty — in-process VAD segments are owned by the pipeline's SilenceDetector,
    /// not by the capture manager. Only meaningful for the XPC path.
    public func getVADSegments() async -> [SpeechSegment] {
        return []
    }
}
