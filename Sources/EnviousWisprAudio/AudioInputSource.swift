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

    // State
    var isCapturing: Bool { get }
    var isRunning: Bool { get }

    // Engine-specific (no-op for AVCaptureSessionSource)
    func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async -> Bool
    func abortPrepare()
    func rebuild()
}
