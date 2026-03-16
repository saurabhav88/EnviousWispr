@preconcurrency import AVFoundation
import CoreAudio

/// Abstraction over audio capture — enables swapping between in-process and XPC implementations.
@MainActor
public protocol AudioCaptureInterface: AnyObject {
    // Observable state (read-only externally)
    var isCapturing: Bool { get }
    var audioLevel: Float { get }
    var capturedSamples: [Float] { get }

    // Callback properties (read-write)
    var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
    var onEngineInterrupted: (() -> Void)? { get set }
    var onVADAutoStop: (() -> Void)? { get set }

    // Configuration properties (read-write)
    var noiseSuppressionEnabled: Bool { get set }
    var selectedInputDeviceUID: String { get set }
    var preferredInputDeviceIDOverride: String { get set }

    // Core lifecycle
    func startEnginePhase() async throws
    func beginCapturePhase() async throws -> AsyncStream<AVAudioPCMBuffer>
    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer>
    func stopCapture() async -> [Float]
    func rebuildEngine()
    func buildEngine(noiseSuppression: Bool)
    func preWarm() async
    func abortPreWarm()
    func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool

    // VAD (Step 5)
    func configureVAD(autoStop: Bool, silenceTimeout: Double, sensitivity: Float, energyGate: Bool)
    func getSamplesSnapshot(fromIndex: Int) async -> (samples: [Float], totalCount: Int)
    func getVADSegments() async -> [SpeechSegment]
}
