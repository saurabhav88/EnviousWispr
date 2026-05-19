import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// PR8 of #763 — App-level home composing the heart-path event routers.
/// Holds three private collaborators (`AudioEventRouter`, `ASREventRouter`,
/// `WedgeRecoveryRouter`) that install their callbacks on `audioCapture` /
/// `asrManager` at construction. Not environment-injected, not consumed by
/// AppDelegate or any view.
///
/// PR9 of #763 — gains `dictationLifecycleCoordinator` as a fourth private
/// collaborator. The lifecycle home owns pipeline state-change side effects,
/// the post-completion warning Task, and the backend-resolver state + helpers
/// that the routers' injected closures consume via the resolver closures
/// below. The closure signatures stay byte-for-byte from PR8 (`LastCapturingBackend?`,
/// `(any HeartPathTelemetryTarget)?`, `(UInt64) -> Bool`); only the closure
/// CAPTURES change — from `[weak appState]` to `[weak dictationLifecycleCoordinator]`.
///
/// PR10 expands this home with hotkey controller + recording starter/finalizer.
@MainActor
final class DictationRuntime {
  private let dictationLifecycleCoordinator: DictationLifecycleCoordinator
  private let audioEventRouter: AudioEventRouter
  private let asrEventRouter: ASREventRouter
  private let wedgeRecoveryRouter: WedgeRecoveryRouter

  init(
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface,
    pipeline: TranscriptionPipeline,
    whisperKitPipeline: WhisperKitPipeline,
    captureTelemetry: CaptureTelemetryState,
    dictationLifecycleCoordinator: DictationLifecycleCoordinator,
    resolveActiveCaptureBackend: @escaping @MainActor () -> DictationLifecycleCoordinator
      .LastCapturingBackend?,
    resolveActiveTelemetryTarget: @escaping @MainActor () -> (any HeartPathTelemetryTarget)?,
    isCurrentSession: @escaping @MainActor (UInt64) -> Bool
  ) {
    self.dictationLifecycleCoordinator = dictationLifecycleCoordinator
    self.audioEventRouter = AudioEventRouter(
      audioCapture: audioCapture,
      pipeline: pipeline,
      whisperKitPipeline: whisperKitPipeline,
      captureTelemetry: captureTelemetry,
      resolveActiveCaptureBackend: resolveActiveCaptureBackend
    )
    self.asrEventRouter = ASREventRouter(
      asrManager: asrManager,
      pipeline: pipeline,
      whisperKitPipeline: whisperKitPipeline
    )
    self.wedgeRecoveryRouter = WedgeRecoveryRouter(
      audioCapture: audioCapture,
      pipeline: pipeline,
      whisperKitPipeline: whisperKitPipeline,
      isCurrentSession: isCurrentSession,
      resolveActiveTelemetryTarget: resolveActiveTelemetryTarget
    )
  }
}
