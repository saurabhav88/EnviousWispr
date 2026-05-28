import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// PR10 of #763 — owns the stop / cancel / lock-on path lifted out of
/// the former root state. User stop dispatches `.requestStop`. User cancel emits
/// telemetry first, then clears the chip, clears the hands-free lock,
/// hides the overlay, then dispatches `.cancelRecording` on the active
/// backend. Also owns the `lastUserStopRequest` timestamp (read by
/// `RecordingStarter.start()`'s post-condition wedge guard) and the
/// hands-free "lock on" toggle that the `onLocked` hotkey callback fires.
///
/// Timing invariant: `userStop()` and `cancel()` mark
/// `lastUserStopRequest` BEFORE any `await` that could suspend; Starter's
/// wedge guard reads it after dispatch/prewarm at the same logical point
/// as the old root-state code (pre-PR10).
/// Clock source is `ContinuousClock`, NOT `Date`.
@MainActor
final class RecordingFinalizer {
  let kernelDriver: KernelDictationDriver
  let whisperKitKernelDriver: KernelDictationDriver
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
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver,
    asrManager: any ASRManagerInterface,
    recordingOverlay: RecordingOverlayPanel,
    heartControlRecovery: HeartControlRecovery,
    recordingLockedAccess: DictationLifecycleCoordinator.RecordingLockedAccess,
    languageSuggestionPresenter: LanguageSuggestionPresenter?
  ) {
    self.kernelDriver = kernelDriver
    self.whisperKitKernelDriver = whisperKitKernelDriver
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
      asrManager.activeBackendType == .whisperKit ? whisperKitKernelDriver : kernelDriver
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
    // PR-5 Rung 5 (#827): both backends are kernel drivers now; collapse the
    // WhisperKit-specific cancel branch (which used `handle(.cancelRecording)`
    // and gated on the now-extinct `.startingUp` state) onto the same
    // `cancelRecording()` shape Parakeet uses.
    let active: KernelDictationDriver =
      asrManager.activeBackendType == .whisperKit ? whisperKitKernelDriver : kernelDriver
    guard active.state == .recording || active.state == .loadingModel else { return }
    await active.cancelRecording()
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
      whisperKitKernelDriver.reset()
    } else {
      kernelDriver.reset()
    }
  }
}
