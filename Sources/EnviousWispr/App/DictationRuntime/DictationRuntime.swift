import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// PR8 of #763 — App-level home composing the heart-path event routers.
/// Holds three private collaborators (`AudioEventRouter`, `ASREventRouter`,
/// `WedgeRecoveryRouter`) that install their callbacks on `audioCapture` /
/// `asrManager` at construction.
///
/// PR9 of #763 — gains `dictationLifecycleCoordinator` as a fourth private
/// collaborator. The lifecycle home owns pipeline state-change side effects,
/// the post-completion warning Task, and the backend-resolver state + helpers
/// that the routers' injected closures consume via the resolver closures.
///
/// PR10 of #763 — promoted from a private composition node to the App-level
/// `@State` home that the UI / menus / hotkey OS callbacks talk to as the
/// only command surface for recording. Gains three private collaborators:
/// `hotkeyController` (callback wiring + suspend/resume), `starter`
/// (start / prewarm / toggle dispatch / post-condition guard), and
/// `finalizer` (user stop / cancel / lock cleanup / reset). DR.init builds
/// `HeartControlRecovery` locally and passes it by value to Starter +
/// Finalizer (HCR is a struct of closure fields — identity lives in the
/// captures, not the struct), then calls `hotkeyController.install()` as
/// the last init step. No external `dictationRuntime.install()` exists.
/// `@Observable` so PR10's environment injection works
/// (`SwiftUI.Environment(DictationRuntime.self)` requires `Observable`
/// conformance). All stored properties are `let`; the @Observable macro
/// adds tracking infrastructure but no facade state ever mutates.
@MainActor
@Observable
final class DictationRuntime {
  private let dictationLifecycleCoordinator: DictationLifecycleCoordinator
  private let audioEventRouter: AudioEventRouter
  private let asrEventRouter: ASREventRouter
  private let wedgeRecoveryRouter: WedgeRecoveryRouter
  private let hotkeyController: HotkeyController
  private let starter: RecordingStarter
  private let finalizer: RecordingFinalizer

  init(
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface,
    kernelDriver: KernelDictationDriver,
    whisperKitPipeline: WhisperKitPipeline,
    captureTelemetry: CaptureTelemetryState,
    settings: SettingsManager,
    permissions: PermissionsService,
    recordingOverlay: RecordingOverlayPanel,
    hotkeyService: HotkeyService,
    lastRecordingResult: LastRecordingResult,
    languageSuggestionPresenter: LanguageSuggestionPresenter?,
    dictationLifecycleCoordinator: DictationLifecycleCoordinator,
    recordingLockedAccess: DictationLifecycleCoordinator.RecordingLockedAccess,
    resolveActiveCaptureBackend: @escaping @MainActor () -> DictationLifecycleCoordinator
      .LastCapturingBackend?,
    resolveActiveTelemetryTarget: @escaping @MainActor () -> (any HeartPathTelemetryTarget)?,
    isCurrentSession: @escaping @MainActor (UInt64) -> Bool
  ) {
    self.dictationLifecycleCoordinator = dictationLifecycleCoordinator
    self.audioEventRouter = AudioEventRouter(
      audioCapture: audioCapture,
      kernelDriver: kernelDriver,
      whisperKitPipeline: whisperKitPipeline,
      captureTelemetry: captureTelemetry,
      resolveActiveCaptureBackend: resolveActiveCaptureBackend
    )
    self.asrEventRouter = ASREventRouter(
      asrManager: asrManager,
      kernelDriver: kernelDriver,
      whisperKitPipeline: whisperKitPipeline
    )
    self.wedgeRecoveryRouter = WedgeRecoveryRouter(
      audioCapture: audioCapture,
      kernelDriver: kernelDriver,
      whisperKitPipeline: whisperKitPipeline,
      isCurrentSession: isCurrentSession,
      resolveActiveTelemetryTarget: resolveActiveTelemetryTarget
    )

    // PR10 of #763 — build the recording subsystem locally. HeartControlRecovery
    // is a struct of closure fields (HeartControlRecovery.swift:19-22); identity
    // lives in the captured references (overlay, lock setter, backend reader),
    // not in the struct itself. Value-copy is safe; Finalizer + Starter each
    // receive their own copy.
    let heartControlRecovery = HeartControlRecovery(
      hideOverlay: { [recordingOverlay] in recordingOverlay.show(intent: .hidden) },
      setLocked: { locked in recordingLockedAccess.set(locked) },
      backend: { [asrManager] in
        asrManager.activeBackendType == .whisperKit ? "whisperkit" : "parakeet"
      }
    )
    let finalizer = RecordingFinalizer(
      kernelDriver: kernelDriver,
      whisperKitPipeline: whisperKitPipeline,
      asrManager: asrManager,
      recordingOverlay: recordingOverlay,
      heartControlRecovery: heartControlRecovery,
      recordingLockedAccess: recordingLockedAccess,
      languageSuggestionPresenter: languageSuggestionPresenter
    )
    self.finalizer = finalizer
    let starter = RecordingStarter(
      audioCapture: audioCapture,
      asrManager: asrManager,
      kernelDriver: kernelDriver,
      whisperKitPipeline: whisperKitPipeline,
      settings: settings,
      permissions: permissions,
      recordingOverlay: recordingOverlay,
      heartControlRecovery: heartControlRecovery,
      recordingLockedAccess: recordingLockedAccess,
      lastUserStopAccess: finalizer.lastUserStopAccess,
      lastRecordingResult: lastRecordingResult,
      dictationLifecycleCoordinator: dictationLifecycleCoordinator
    )
    self.starter = starter
    let hotkeyController = HotkeyController(
      hotkeyService: hotkeyService,
      starter: starter,
      finalizer: finalizer,
      settings: settings
    )
    self.hotkeyController = hotkeyController
    hotkeyController.install()
  }

  // MARK: - Facade (UI / menus / AppDelegate command surface)

  var hotkeyDescription: String { hotkeyController.hotkeyDescription }

  func startHotkeyServiceIfEnabled() { hotkeyController.startIfEnabled() }
  func suspendHotkeys() { hotkeyController.suspend() }
  func resumeHotkeys() { hotkeyController.resume() }

  func toggleRecording(source: TriggerSource) async {
    await starter.toggle(source: source)
  }

  func cancelRecording() async { await finalizer.cancel() }

  func resetActivePipeline() { finalizer.resetActive() }
}
