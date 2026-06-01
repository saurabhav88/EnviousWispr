@preconcurrency import AVFoundation
import EnviousWisprCore

/// Abstraction over ASR management — enables swapping between in-process and XPC implementations.
///
/// `ASRManager` (in-process) and `ASRManagerProxy` (XPC) both conform to this protocol.
/// Pipelines and the former root state interact through this interface only.
@MainActor
public protocol ASRManagerInterface: AnyObject {
  // Observable state
  var activeBackendType: ASRBackendType { get }
  var isModelLoaded: Bool { get }
  var isStreaming: Bool { get }  // periphery:ignore - read via existential type (ASRManagerProxy)

  // Download progress (0.0–1.0), phase description, and detail string.
  // Updated during loadModel() when model download is in progress.
  // periphery:ignore:all - read via existential type in OnboardingV2View progress polling
  var downloadProgress: Double { get }
  var downloadPhase: String { get }
  var downloadDetail: String { get }

  // Model lifecycle
  func loadModel() async throws
  func unloadModel() async  // periphery:ignore - called via existential type (ASRManager idle timer)
  func setInitialBackendType(_ type: ASRBackendType)
  func switchBackend(to type: ASRBackendType) async

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

  /// Issue #445: cancel a wedged in-flight model load and trigger service-level
  /// reset. Called by pipeline watchdog when `loadModel()` exceeds the recovery
  /// deadline. For in-process `ASRManager` this just cancels the host task;
  /// for `ASRManagerProxy` (XPC, production) this invalidates the connection
  /// to terminate the service-side load. Equivalent to manual app restart.
  func cancelInFlightLoad()

  /// Issue #445: per-tick callback for the load-progress polling stream.
  /// Set by the dictation kernel for the duration of one `loadModel()`
  /// call so the pipeline-owned `LoadProgressWatcher` receives mtime + phase
  /// observations from the proxy's existing 8Hz timer. Cleared after the
  /// load resolves. Closure-callback shape matches `swift-patterns.md` hot-
  /// path guidance (closure beats `any Protocol` existential dispatch).
  var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)? { get set }

  // Crash notification — fires when XPC ASR service dies during an active session.
  // Wired by the former root state to route to the active pipeline (same pattern as AudioCaptureProxy.onEngineInterrupted).
  var onServiceInterrupted: (() -> Void)? { get set }
}
