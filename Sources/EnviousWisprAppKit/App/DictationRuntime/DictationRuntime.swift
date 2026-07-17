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
  // periphery:ignore - retain anchor: owns the lifecycle coordinator (installs weak-self driver callbacks)
  private let dictationLifecycleCoordinator: DictationLifecycleCoordinator
  // periphery:ignore - retain anchor: owns the audio event router (AVAudio observer + weak-self callbacks)
  private let audioEventRouter: AudioEventRouter
  // periphery:ignore - retain anchor: owns the ASR event router (asrManager.onServiceInterrupted weak-self callback)
  private let asrEventRouter: ASREventRouter
  // periphery:ignore - retain anchor: owns the wedge-recovery router (audioCapture weak-self callbacks)
  private let wedgeRecoveryRouter: WedgeRecoveryRouter
  private let hotkeyController: HotkeyController
  private let starter: RecordingStarter
  private let finalizer: RecordingFinalizer

  init(
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface,
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver,
    settings: SettingsManager,
    permissions: PermissionsService,
    recordingOverlay: RecordingOverlayPanel,
    hotkeyService: HotkeyService,
    lastRecordingResult: LastRecordingResult,
    languageSuggestionPresenter: LanguageSuggestionPresenter?,
    dictationLifecycleCoordinator: DictationLifecycleCoordinator,
    recoveryCoordinator: RecoveryCoordinator,
    recordingLockedAccess: DictationLifecycleCoordinator.RecordingLockedAccess,
    resolveActiveCaptureBackend: @escaping @MainActor () -> DictationLifecycleCoordinator
      .LastCapturingBackend?,
    resolveActiveTelemetryTarget: @escaping @MainActor () -> (any HeartPathTelemetryTarget)?,
    isCurrentSession: @escaping @MainActor (UInt64) -> Bool,
    // #1171 — start-of-recording engine reconciliation; bound to
    // `EngineCoordinator.ensureSelectedReadyForPress` + `.isSwitching`. Default
    // `.notReady` for legacy/tests.
    ensureSelectedReadyForPress: @escaping @MainActor () async -> EngineCoordinator.PressReadiness =
      {
        .notReady
      },
    isEngineSwitching: @escaping @MainActor () -> Bool = { false },
    beginMinting: @escaping @MainActor () -> Void = {},
    endMinting: @escaping @MainActor () -> Void = {}
  ) {
    self.dictationLifecycleCoordinator = dictationLifecycleCoordinator
    self.audioEventRouter = AudioEventRouter(
      audioCapture: audioCapture,
      kernelDriver: kernelDriver,
      whisperKitKernelDriver: whisperKitKernelDriver,
      resolveActiveCaptureBackend: resolveActiveCaptureBackend
    )
    self.asrEventRouter = ASREventRouter(
      asrManager: asrManager,
      kernelDriver: kernelDriver,
      whisperKitKernelDriver: whisperKitKernelDriver
    )
    self.wedgeRecoveryRouter = WedgeRecoveryRouter(
      audioCapture: audioCapture,
      kernelDriver: kernelDriver,
      whisperKitKernelDriver: whisperKitKernelDriver,
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
      backend: { [asrManager] in asrManager.activeBackendType.rawValue }
    )
    let finalizer = RecordingFinalizer(
      kernelDriver: kernelDriver,
      whisperKitKernelDriver: whisperKitKernelDriver,
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
      whisperKitKernelDriver: whisperKitKernelDriver,
      settings: settings,
      permissions: permissions,
      recordingOverlay: recordingOverlay,
      heartControlRecovery: heartControlRecovery,
      recordingLockedAccess: recordingLockedAccess,
      lastUserStopAccess: finalizer.lastUserStopAccess,
      lastRecordingResult: lastRecordingResult,
      dictationLifecycleCoordinator: dictationLifecycleCoordinator,
      // #1063 PR1: bind the recovery-arm closure to the coordinator (a bare
      // closure so the starter stays off its collaborator cap; the kernel never
      // sees the coordinator).
      makeRecoveryDirective: { settings, backend, lid in
        await recoveryCoordinator.makeDirective(
          settings: settings, backendType: backend, supportsLanguageDetection: lid)
      },
      // #1063 PR1 (Codex r3): a PTT release or concurrent-toggle stop landing in
      // the arm window mints no session, so the lifecycle coordinator sees no
      // terminal state — the starter cleans the armed spool/key directly. #1464:
      // a pre-start abort has no `RecordingOutcome`, so it routes to the dedicated
      // coordinator entry point (always a discard — nothing was captured).
      cleanupRecoveryArm: { id in
        recoveryCoordinator.handlePreStartAbort(recoverySessionID: id)
      },
      // #1063 PR2: the recording gate — a press while recovery holds the shared
      // engine mints no session (shows the "recovering" pill).
      isRecovering: { recoveryCoordinator.isRecovering },
      // #1171: drive the selected engine to ready before recording, gate a press
      // during an in-flight switch, and hold the start-window state-gate so the
      // coordinator can't switch the engine out mid-startup.
      ensureSelectedReadyForPress: ensureSelectedReadyForPress,
      isEngineSwitching: isEngineSwitching,
      beginMinting: beginMinting,
      endMinting: endMinting
    )
    self.starter = starter
    // #1063 PR1: on a durable transcript save, delete that session's spool + key.
    // Keeps the Pipeline recovery-unaware — the host observes the saved transcript.
    dictationLifecycleCoordinator.onDurableSave = { id in
      recoveryCoordinator.handleDurableSave(recoverySessionID: id)
    }
    // #1063 PR2 / #1464: a recording that ends at a non-saved terminal routes to
    // recovery cleanup — the coordinator's predicate deletes a discard/no-speech/
    // user-cancel ending now and RETAINS a fault ending for next-launch recovery.
    dictationLifecycleCoordinator.onRecordingEndedWithoutDurableSave = { id, ending in
      recoveryCoordinator.handleRecordingEndedWithoutDurableSave(
        recoverySessionID: id, ending: ending)
    }
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

  /// #879 Phase D — route onboarding's first-run model warm-up through the
  /// shared `ensureEngineWarm(reason: .onboarding)` on the active engine's
  /// driver, so the onboarding gate uses the same live-readiness check +
  /// single-flight + telemetry as every other warm-up site. Returns the outcome
  /// so the onboarding screen can drive its "download failed → Retry" UX.
  func ensureActiveEngineWarmForOnboarding() async -> EngineWarmupOutcome {
    await starter.activeDriver.ensureEngineWarm(reason: .onboarding)
  }

  /// #1388 step 3 — the onboarding install Cancel button's seam. Cancels the
  /// in-flight warm-up load; the awaiting `ensureEngineWarm` resolves as
  /// `.cancelled` (never a failure), and onboarding renders the calm
  /// "Try setup again" state. Safe against a just-completed load — the
  /// adapter's in-flight gate makes it a no-op then.
  func cancelActiveEngineWarmupForOnboarding() async {
    await starter.activeDriver.cancelSessionlessWarmup()
  }
}
