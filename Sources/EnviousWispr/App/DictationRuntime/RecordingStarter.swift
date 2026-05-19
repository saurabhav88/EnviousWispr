import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// PR10 of #763 — owns the start path lifted out of AppState. `start()` is
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
  let pipeline: TranscriptionPipeline
  let whisperKitPipeline: WhisperKitPipeline
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
      let state = whisperKitPipeline.state
      return state == .transcribing || state == .polishing
    } else {
      let state = pipeline.state
      return state == .transcribing || state == .polishing
    }
  }

  init(
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface,
    pipeline: TranscriptionPipeline,
    whisperKitPipeline: WhisperKitPipeline,
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
    self.pipeline = pipeline
    self.whisperKitPipeline = whisperKitPipeline
    self.settings = settings
    self.permissions = permissions
    self.recordingOverlay = recordingOverlay
    self.heartControlRecovery = heartControlRecovery
    self.recordingLockedAccess = recordingLockedAccess
    self.lastUserStopAccess = lastUserStopAccess
    self.lastRecordingResult = lastRecordingResult
    self.dictationLifecycleCoordinator = dictationLifecycleCoordinator
  }

  /// Hotkey PTT start path. Mirrors AppState.swift:340-493 (pre-PR10):
  /// overlay shows immediately for visual feedback, then prewarm, then
  /// dispatch `.toggleRecording`, then the issue #445 post-condition
  /// guard.
  func start() async {
    dictationLifecycleCoordinator?.cancelPendingWarning()
    let isWhisperKit = asrManager.activeBackendType == .whisperKit
    let active: any DictationPipeline = isWhisperKit ? whisperKitPipeline : pipeline
    if isWhisperKit {
      guard !whisperKitPipeline.state.isActive else { return }
    } else {
      guard !pipeline.state.isActive else { return }
    }
    lastRecordingResult?.polishError = nil
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
    let preWarmMs = Self.elapsedMs(since: pttStart)
    do {
      try await active.handle(
        event: .toggleRecording(
          DictationSessionConfigFactory.make(
            asrManager: asrManager,
            pipeline: pipeline,
            whisperKitPipeline: whisperKitPipeline,
            settings: settings,
            triggerSource: .pttHotkey
          )))
    } catch {
      heartControlRecovery.recover(
        error: error, pipeline: active, op: "toggle-from-prewarm",
        message: ModelLoadWatchdog.userMessage)
      return
    }
    let totalMs = Self.elapsedMs(since: pttStart)
    let pipelineActive: Bool
    let pipelineInError: Bool
    if isWhisperKit {
      pipelineActive = whisperKitPipeline.state.isActive
      if case .error = whisperKitPipeline.state {
        pipelineInError = true
      } else {
        pipelineInError = false
      }
    } else {
      pipelineActive = pipeline.state.isActive
      if case .error = pipeline.state {
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
        "COLD-START [RecordingStarter] PTT-to-recording: total=\(totalMs)ms preWarm=\(preWarmMs)ms startRecording=\(totalMs - preWarmMs)ms backend=\(isWhisperKit ? "whisperkit" : "parakeet")",
        level: .info, category: "Pipeline"
      )
    }
  }

  /// UI/menu toggle path (no prewarm). Mirrors AppState.swift:588-629
  /// (pre-PR10). When this toggle initiates a START (active idle), clear
  /// the prior polish error and refresh AX status so the session config
  /// snapshot picks up the right paste capability.
  func toggle(source: TriggerSource) async {
    dictationLifecycleCoordinator?.cancelPendingWarning()
    let active: any DictationPipeline =
      asrManager.activeBackendType == .whisperKit ? whisperKitPipeline : pipeline
    let isWK = asrManager.activeBackendType == .whisperKit
    if !(isWK ? whisperKitPipeline.state.isActive : pipeline.state.isActive) {
      lastRecordingResult?.polishError = nil
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
            pipeline: pipeline,
            whisperKitPipeline: whisperKitPipeline,
            settings: settings,
            triggerSource: source
          )))
    } catch {
      heartControlRecovery.recover(
        error: error, pipeline: active, op: "toggle",
        message: ModelLoadWatchdog.userMessage)
    }
  }

  private static func elapsedMs(since instant: ContinuousClock.Instant) -> Int {
    let (s, a) = (ContinuousClock.now - instant).components
    return Int(s) * 1000 + Int(a / 1_000_000_000_000_000)
  }
}
