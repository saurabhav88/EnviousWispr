import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// PR10 of #763 — owns the stop / cancel / lock-on path lifted out of
/// AppState. User stop dispatches `.requestStop`. User cancel emits
/// telemetry first, then clears the chip, clears the hands-free lock,
/// hides the overlay, then dispatches `.cancelRecording` on the active
/// backend. Also owns the `lastUserStopRequest` timestamp (read by
/// `RecordingStarter.start()`'s post-condition wedge guard) and the
/// hands-free "lock on" toggle that the `onLocked` hotkey callback fires.
///
/// Timing invariant: `userStop()` and `cancel()` mark
/// `lastUserStopRequest` BEFORE any `await` that could suspend; Starter's
/// wedge guard reads it after dispatch/prewarm at the same logical point
/// as the old AppState code at `AppState.swift:466-470` (pre-PR10).
/// Clock source is `ContinuousClock`, NOT `Date`.
@MainActor
final class RecordingFinalizer {
  let pipeline: TranscriptionPipeline
  let whisperKitPipeline: WhisperKitPipeline
  let asrManager: any ASRManagerInterface
  let recordingOverlay: RecordingOverlayPanel

  var heartControlRecovery: HeartControlRecovery
  var recordingLockedAccess: DictationLifecycleCoordinator.RecordingLockedAccess
  weak var languageSuggestionPresenter: LanguageSuggestionPresenter?

  private var lastUserStopRequest: ContinuousClock.Instant?

  /// Read accessor exposed to `RecordingStarter` so the start path's
  /// post-condition wedge guard can detect "user stopped during start"
  /// without granting Starter write access to the underlying state.
  /// Mirrors PR9's `RecordingLockedAccess { get; set }` shape.
  struct LastUserStopAccess {
    let read: @MainActor () -> ContinuousClock.Instant?
  }

  var lastUserStopAccess: LastUserStopAccess {
    .init(read: { [weak self] in self?.lastUserStopRequest })
  }

  init(
    pipeline: TranscriptionPipeline,
    whisperKitPipeline: WhisperKitPipeline,
    asrManager: any ASRManagerInterface,
    recordingOverlay: RecordingOverlayPanel,
    heartControlRecovery: HeartControlRecovery,
    recordingLockedAccess: DictationLifecycleCoordinator.RecordingLockedAccess,
    languageSuggestionPresenter: LanguageSuggestionPresenter?
  ) {
    self.pipeline = pipeline
    self.whisperKitPipeline = whisperKitPipeline
    self.asrManager = asrManager
    self.recordingOverlay = recordingOverlay
    self.heartControlRecovery = heartControlRecovery
    self.recordingLockedAccess = recordingLockedAccess
    self.languageSuggestionPresenter = languageSuggestionPresenter
  }

  func userStop() async {
    recordingLockedAccess.set(false)
    lastUserStopRequest = ContinuousClock.now
    let active: any DictationPipeline =
      asrManager.activeBackendType == .whisperKit ? whisperKitPipeline : pipeline
    do {
      try await active.handle(event: .requestStop)
    } catch {
      heartControlRecovery.logDispatchFailure(error, op: "stop")
    }
  }

  func cancel() async {
    TelemetryService.shared.dictationCanceled(
      stage: "recording", reason: "user_cancel", durationSeconds: nil)
    languageSuggestionPresenter?.clearCurrentChip()
    languageSuggestionPresenter?.clearBuffer()
    recordingLockedAccess.set(false)
    lastUserStopRequest = ContinuousClock.now
    recordingOverlay.hide()
    let isWhisperKit = asrManager.activeBackendType == .whisperKit
    if isWhisperKit {
      let wkState = whisperKitPipeline.state
      guard wkState == .recording || wkState == .loadingModel || wkState == .startingUp
      else { return }
      do {
        try await whisperKitPipeline.handle(event: .cancelRecording)
      } catch {
        heartControlRecovery.logDispatchFailure(error, op: "cancel-whisperkit")
      }
    } else {
      guard pipeline.state == .recording || pipeline.state == .loadingModel else { return }
      await pipeline.cancelRecording()
    }
  }

  func markLocked() {
    recordingLockedAccess.set(true)
    recordingOverlay.updateLockState(true)
    Task {
      await AppLogger.shared.log(
        "Hands-free mode activated — overlay expanding",
        level: .info, category: "RecordingFinalizer"
      )
    }
  }

  /// Reset the active pipeline to idle (UI "Try Again" / dismiss action).
  /// Lives here so `DictationRuntime` does not have to store the pipelines
  /// itself; Finalizer already holds them.
  func resetActive() {
    if asrManager.activeBackendType == .whisperKit {
      whisperKitPipeline.reset()
    } else {
      pipeline.reset()
    }
  }
}
