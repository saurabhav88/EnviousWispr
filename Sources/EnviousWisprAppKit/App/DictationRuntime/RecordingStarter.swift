import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// PR10 of #763 — owns the start path lifted out of the former root state. `start()` is
/// the hotkey-onStartRecording path (refresh permissions, show overlay
/// immediately, prewarm the pipeline, dispatch `.toggleRecording`, run
/// the post-condition wedge guard, log cold-start telemetry).
/// `toggle(source:)` is the lighter UI/menu path that skips prewarm and
/// threads the call site's `TriggerSource` into the session config.
/// `isProcessing` is the read-only callback target for the hotkey gate.
///
/// Does NOT own `HotkeyService` (that lives on the App-owned `@State`
/// and is shared with `PipelineSettingsSync` + `DictationLifecycleCoordinator`).
/// Does NOT own or receive `TranscriptPolishService` (PR11 of #763 owns
/// polish-service rehoming — explicit constraint from epic comment
/// 4483335497).
@MainActor
final class RecordingStarter {
  let audioCapture: any AudioCaptureInterface
  let asrManager: any ASRManagerInterface
  let kernelDriver: KernelDictationDriver
  let whisperKitKernelDriver: KernelDictationDriver
  let settings: SettingsManager
  let permissions: PermissionsService
  let recordingOverlay: RecordingOverlayPanel

  var heartControlRecovery: HeartControlRecovery
  var recordingLockedAccess: DictationLifecycleCoordinator.RecordingLockedAccess
  var lastUserStopAccess: RecordingFinalizer.LastUserStopAccess
  weak var lastRecordingResult: LastRecordingResult?
  weak var dictationLifecycleCoordinator: DictationLifecycleCoordinator?

  /// Read by `HotkeyController`'s `onIsProcessing` callback. True when
  /// either backend is still finishing the previous session (transcribing
  /// or polishing) — blocks a new start so the user does not stack
  /// recordings on top of in-flight post-processing.
  var isProcessing: Bool {
    if asrManager.activeBackendType == .whisperKit {
      let state = whisperKitKernelDriver.state
      return state == .transcribing || state == .polishing
    } else {
      let state = kernelDriver.state
      return state == .transcribing || state == .polishing
    }
  }

  init(
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface,
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver,
    settings: SettingsManager,
    permissions: PermissionsService,
    recordingOverlay: RecordingOverlayPanel,
    heartControlRecovery: HeartControlRecovery,
    recordingLockedAccess: DictationLifecycleCoordinator.RecordingLockedAccess,
    lastUserStopAccess: RecordingFinalizer.LastUserStopAccess,
    lastRecordingResult: LastRecordingResult,
    dictationLifecycleCoordinator: DictationLifecycleCoordinator?
  ) {
    self.audioCapture = audioCapture
    self.asrManager = asrManager
    self.kernelDriver = kernelDriver
    self.whisperKitKernelDriver = whisperKitKernelDriver
    self.settings = settings
    self.permissions = permissions
    self.recordingOverlay = recordingOverlay
    self.heartControlRecovery = heartControlRecovery
    self.recordingLockedAccess = recordingLockedAccess
    self.lastUserStopAccess = lastUserStopAccess
    self.lastRecordingResult = lastRecordingResult
    self.dictationLifecycleCoordinator = dictationLifecycleCoordinator
  }

  /// Hotkey PTT start path. Mirrors the former root-state file (pre-PR10):
  /// overlay shows immediately for visual feedback, then prewarm, then
  /// dispatch `.toggleRecording`, then the issue #445 post-condition
  /// guard.
  func start() async {
    dictationLifecycleCoordinator?.cancelPendingWarning()
    let isWhisperKit = asrManager.activeBackendType == .whisperKit
    let active: KernelDictationDriver = isWhisperKit ? whisperKitKernelDriver : kernelDriver
    // PR-7 (#827): snapshot engine readiness BEFORE prewarm so the cold-start
    // log cohorts warm/cold/mid-flight; snapshot-at-entry avoids retro-labeling.
    let readinessAtEntry = (isWhisperKit ? whisperKitKernelDriver : kernelDriver).engineReadiness
    if isWhisperKit {
      guard !whisperKitKernelDriver.state.isActive else { return }
    } else {
      guard !kernelDriver.state.isActive else { return }
    }
    lastRecordingResult?.polishError = nil
    // #879 — cold-boot press safety. A press on a not-ready engine must NOT mint
    // a recording session (no audio captured → none discarded). Hand off to the
    // cold-press policy (pill + warm-up + READY announce) and bail; the user
    // re-presses after "Ready" and that re-press runs the full warm path below.
    // Placed after the polish-error reset (cleared on every entry), before the
    // AX-refresh / overlay / prewarm block.
    if readinessAtEntry != .ready {
      ColdPressGuard.handle(
        overlay: recordingOverlay, active: active,
        backendTag: isWhisperKit ? "whisperkit" : "parakeet",
        readiness: readinessAtEntry)
      return
    }
    permissions.refreshAccessibilityStatus()
    if !permissions.hasAccessibilityPermission {
      permissions.restartMonitoringIfNeeded()
    }
    recordingOverlay.show(
      intent: .recording(audioLevel: 0),
      audioLevelProvider: { [audioCapture] in audioCapture.audioLevel },
      isRecordingLocked: false
    )
    let pttStart = ContinuousClock.now
    do {
      try await active.handle(event: .preWarm)
    } catch is CancellationError {
      audioCapture.abortPreWarm()
      recordingOverlay.show(intent: .hidden)
      recordingLockedAccess.set(false)
      return
    } catch {
      audioCapture.abortPreWarm()
      recordingOverlay.show(intent: .hidden)
      recordingLockedAccess.set(false)
      SentryBreadcrumb.add(
        stage: "recording", message: "preWarm failed — start aborted",
        level: .warning, data: ["error": String(describing: error)]
      )
      active.setExternalError("Microphone unavailable — try again.")
      return
    }
    guard !Task.isCancelled else {
      audioCapture.abortPreWarm()
      recordingOverlay.show(intent: .hidden)
      recordingLockedAccess.set(false)
      return
    }
    // PTT key-up that fired while `preWarm()` was awaiting did not reach
    // the kernel via `requestStop` — `RecordingSessionKernel.requestStop`
    // ignores `.idle` (sessionless pre-warm leaves the kernel idle), so
    // dispatching `.toggleRecording` here would start a recording even
    // though the user had already released. Mirror the post-toggle
    // `userStoppedDuringStart` guard at lines 162-165 so the start path
    // bails out cleanly. (Codex final-review P1 on the cutover.)
    let userStoppedDuringPreWarm: Bool = {
      guard let lastStop = lastUserStopAccess.read() else { return false }
      return lastStop > pttStart
    }()
    if userStoppedDuringPreWarm {
      audioCapture.abortPreWarm()
      recordingOverlay.show(intent: .hidden)
      recordingLockedAccess.set(false)
      return
    }
    let preWarmMs = Self.elapsedMs(since: pttStart)
    do {
      try await active.handle(
        event: .toggleRecording(
          DictationSessionConfigFactory.make(
            asrManager: asrManager,
            kernelDriver: kernelDriver,
            whisperKitKernelDriver: whisperKitKernelDriver,
            settings: settings,
            triggerSource: .pttHotkey
          )))
    } catch {
      heartControlRecovery.recover(
        error: error, op: "toggle-from-prewarm",
        message: ModelLoadWatchdog.userMessage,
        setExternalError: active.setExternalError)
      return
    }
    let totalMs = Self.elapsedMs(since: pttStart)
    let pipelineActive: Bool
    let pipelineInError: Bool
    if isWhisperKit {
      pipelineActive = whisperKitKernelDriver.state.isActive
      if case .error = whisperKitKernelDriver.state {
        pipelineInError = true
      } else {
        pipelineInError = false
      }
    } else {
      pipelineActive = kernelDriver.state.isActive
      if case .error = kernelDriver.state {
        pipelineInError = true
      } else {
        pipelineInError = false
      }
    }
    let userStoppedDuringStart: Bool = {
      guard let lastStop = lastUserStopAccess.read() else { return false }
      return lastStop > pttStart
    }()
    if !pipelineActive && !pipelineInError && !userStoppedDuringStart {
      SentryBreadcrumb.captureError(
        ModelLoadWatchdog.WedgeError(stage: "post_condition"),
        category: .pipelinePostConditionFailed, stage: "recording",
        extra: ["backend": isWhisperKit ? "whisperkit" : "parakeet"]
      )
      recordingOverlay.show(intent: .hidden)
      recordingLockedAccess.set(false)
      active.setExternalError(ModelLoadWatchdog.userMessage)
      return
    }
    if !pipelineActive && !pipelineInError && userStoppedDuringStart {
      recordingOverlay.show(intent: .hidden)
      recordingLockedAccess.set(false)
      return
    }
    Task {
      await AppLogger.shared.log(
        "COLD-START [RecordingStarter] PTT-to-recording: total=\(totalMs)ms preWarm=\(preWarmMs)ms startRecording=\(totalMs - preWarmMs)ms backend=\(isWhisperKit ? "whisperkit" : "parakeet") engineReadinessAtPTT=\(readinessAtEntry.coldStartCohortToken)",
        level: .info, category: "Pipeline"
      )
    }
  }

  /// UI/menu toggle path (no prewarm). Mirrors the former root-state file
  /// (pre-PR10). When this toggle initiates a START (active idle), clear
  /// the prior polish error and refresh AX status so the session config
  /// snapshot picks up the right paste capability.
  func toggle(source: TriggerSource) async {
    dictationLifecycleCoordinator?.cancelPendingWarning()
    let active: KernelDictationDriver =
      asrManager.activeBackendType == .whisperKit ? whisperKitKernelDriver : kernelDriver
    let isWK = asrManager.activeBackendType == .whisperKit
    let isStartingFromIdle =
      !(isWK ? whisperKitKernelDriver.state.isActive : kernelDriver.state.isActive)
    if isStartingFromIdle {
      lastRecordingResult?.polishError = nil
      // #879 — same cold-boot press safety as the PTT path. A toggle press that
      // would START on a not-ready engine shows the pill + warms instead of
      // minting a session (the toggle-hotkey is a user press too). A toggle that
      // STOPS an active session is unaffected (guarded by `isStartingFromIdle`).
      if active.engineReadiness != .ready {
        ColdPressGuard.handle(
          overlay: recordingOverlay, active: active,
          backendTag: isWK ? "whisperkit" : "parakeet",
          readiness: active.engineReadiness)
        return
      }
    }
    permissions.refreshAccessibilityStatus()
    if !permissions.hasAccessibilityPermission {
      permissions.restartMonitoringIfNeeded()
    }
    do {
      try await active.handle(
        event: .toggleRecording(
          DictationSessionConfigFactory.make(
            asrManager: asrManager,
            kernelDriver: kernelDriver,
            whisperKitKernelDriver: whisperKitKernelDriver,
            settings: settings,
            triggerSource: source
          )))
    } catch {
      heartControlRecovery.recover(
        error: error, op: "toggle",
        message: ModelLoadWatchdog.userMessage,
        setExternalError: active.setExternalError)
    }
  }

  private static func elapsedMs(since instant: ContinuousClock.Instant) -> Int {
    let (s, a) = (ContinuousClock.now - instant).components
    return Int(s) * 1000 + Int(a / 1_000_000_000_000_000)
  }
}
