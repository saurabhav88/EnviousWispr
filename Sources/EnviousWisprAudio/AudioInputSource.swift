@preconcurrency import AVFoundation

/// Internal abstraction over audio capture sources.
///
/// Two conformers:
/// - `AVAudioEngineSource`: existing AVAudioEngine tap path (supports voice processing)
/// - `AVCaptureSessionSource`: AVCaptureSession path (avoids BT A2DP→SCO switch)
///
/// `AudioCaptureManager` picks the source via `CaptureRouteResolver` and delegates
/// all hardware interaction to it. The manager owns app-facing state (capturedSamples,
/// audioLevel, isCapturing); sources own hardware/session/engine lifecycle.
@MainActor
protocol AudioInputSource: AnyObject {
    // Callbacks — set by AudioCaptureManager before start
    var onSamples: (@Sendable (_ samples: [Float], _ audioLevel: Float) -> Void)? { get set }
    var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
    var onInterrupted: (() -> Void)? { get set }

    // Lifecycle (mirrors AudioCaptureManager's two-phase start)
    func prepare() async throws
    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer>
    func stop() async -> [Float]

    /// Deactivate live capture but keep engine/session and tap warm.
    /// The forwarder returns to preRolling mode so the ring buffer continues
    /// capturing audio for instant first-word capture on next recording.
    /// Call stop() for full teardown.
    func deactivateCapture()

    // State
    var isCapturing: Bool { get } // periphery:ignore - used by conformers for internal guards
    var isRunning: Bool { get }

    // Engine-specific (no-op for AVCaptureSessionSource)
    func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool
    func abortPrepare()
    func rebuild()
}
