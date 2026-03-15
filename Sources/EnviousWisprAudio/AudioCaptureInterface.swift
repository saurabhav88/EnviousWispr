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

    // Configuration properties (read-write)
    var noiseSuppressionEnabled: Bool { get set }
    var selectedInputDeviceUID: String { get set }
    var preferredInputDeviceIDOverride: String { get set }

    // Core lifecycle
    func startEnginePhase() throws
    func beginCapturePhase() throws -> AsyncStream<AVAudioPCMBuffer>
    func startCapture() throws -> AsyncStream<AVAudioPCMBuffer>
    func stopCapture() -> [Float]
    func rebuildEngine()
    func buildEngine(noiseSuppression: Bool)
    func preWarm() async
    func abortPreWarm()
    func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool
}
