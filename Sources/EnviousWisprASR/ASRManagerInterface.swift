@preconcurrency import AVFoundation
import EnviousWisprCore

/// Abstraction over ASR management — enables swapping between in-process and XPC implementations.
///
/// `ASRManager` (in-process) and `ASRManagerProxy` (XPC) both conform to this protocol.
/// Pipelines and AppState interact through this interface only.
@MainActor
public protocol ASRManagerInterface: AnyObject {
    // Observable state
    var activeBackendType: ASRBackendType { get }
    var isModelLoaded: Bool { get }
    var isStreaming: Bool { get }

    // Model lifecycle
    func loadModel() async throws
    func unloadModel() async
    func switchBackend(to type: ASRBackendType) async
    func updateWhisperKitModel(_ variant: String) async

    // Capability
    var activeBackendSupportsStreaming: Bool { get async }

    // Batch transcription
    func transcribe(audioSamples: [Float], options: TranscriptionOptions) async throws -> ASRResult

    // Streaming transcription
    func startStreaming(options: TranscriptionOptions) async throws
    func feedAudio(_ buffer: AVAudioPCMBuffer) async throws
    func finalizeStreaming() async throws -> ASRResult
    func cancelStreaming() async

    // Pipeline lifecycle hooks
    func noteTranscriptionComplete(policy: ModelUnloadPolicy)
    func cancelIdleTimer()

    // Crash notification — fires when XPC ASR service dies during an active session.
    // Wired by AppState to route to the active pipeline (same pattern as AudioCaptureProxy.onEngineInterrupted).
    var onServiceInterrupted: (() -> Void)? { get set }
}
