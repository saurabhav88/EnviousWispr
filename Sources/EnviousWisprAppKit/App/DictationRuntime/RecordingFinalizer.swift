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
/// hands-free "lock on" toggle that the `onLockRequested` hotkey callback fires
/// — since #1631 that callback runs only when the session the press started is
/// still the running one, so `markLocked()` is never reached for a press that
/// produced no recording.
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

  /// #902 test seams — the stop/cancel dispatch steps. Defaults are today's exact
  /// inline calls, so production behavior is identical. Two separate closures
  /// because `userStop()` dispatches `.requestStop` (throwing) while `cancel()`
  /// calls `cancelRecording()` (non-throwing, different method). A test injects a
  /// closure that reads `lastUserStopRequest` at dispatch entry to prove the
  /// timestamp is set BEFORE the suspending await — the ordering invariant
  /// `RecordingStarter`'s post-await wedge guards depend on, which the old test
  /// (reading only after the await resolved) could never verify.
  var requestStopDispatch: @MainActor (KernelDictationDriver) async throws -> Void = {
    try await $0.handle(event: .requestStop)
  }
  var cancelRecordingDispatch: @MainActor (KernelDictationDriver, UserCancelTrigger) async ->
    Void = {
      // #1063 PR2 / #1464 / #1755: the genuine USER cancel path — attributed
      // `.user` for provenance; every cancel origin deletes under the discard
      // doctrine. #2087 carries WHICH control was used, because only the
      // shortcut is ambiguous enough to be worth recovering from.
      await $0.cancelRecording(disposition: .user($1))
    }

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
    let active: KernelDictationDriver =
      asrManager.activeBackendType == .whisperKit ? whisperKitKernelDriver : kernelDriver
    do {
      try await requestStopDispatch(active)
    } catch {
      heartControlRecovery.logDispatchFailure(error, op: "stop")
    }
  }

  /// Cancel, returning whether it was an ABANDONMENT (#2087) — the caller must
  /// disarm on that, and `CancelAffordancePolicy.isAbandonment` owns why.
  @discardableResult
  func cancel(trigger: UserCancelTrigger) async -> Bool {
    TelemetryService.shared.dictationCanceled(
      stage: "recording", reason: "user_cancel", durationSeconds: nil)
    // Prologue: an ignored cancel still unlocks (RecordingFinalizerCancelPathTests).
    recordingLockedAccess.set(false)
    lastUserStopRequest = ContinuousClock.now
    // PR-5 Rung 5 (#827): both backends are kernel drivers now; collapse the
    // WhisperKit-specific cancel branch (which used `handle(.cancelRecording)`
    // and gated on the now-extinct `.startingUp` state) onto the same
    // `cancelRecording()` shape Parakeet uses.
    let active: KernelDictationDriver =
      asrManager.activeBackendType == .whisperKit ? whisperKitKernelDriver : kernelDriver
    // #2087: abandonment returns at once — no teardown, no terminal await; see policy.
    if CancelAffordancePolicy.isAbandonment(
      trigger: trigger, isEscapeRecoveryTranscribing: active.isEscapeRecoveryTranscribing)
    {
      active.requestEscapeRecoveryAbandonment()
      return true
    }
    guard active.state == .recording || active.state == .loadingModel else { return false }
    languageSuggestionPresenter?.clearCurrentChip()
    languageSuggestionPresenter?.clearBuffer()
    recordingOverlay.hide()
    await cancelRecordingDispatch(active, trigger)
    return false
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
