import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Recovery actions for failed heart-control dispatches (`.requestStop`, `.toggleRecording`,
/// `.cancelRecording`). Extracted from the former root state to keep the coordinator thin (issue #585).
///
/// Two shapes:
/// - `logDispatchFailure` — log only. Use when the caller has already reset overlay + lock
///   before the dispatch (Stop, WhisperKit Cancel paths).
/// - `recover` — full recovery: log, hide overlay, clear lock, surface the terminal notice
///   via the driver's `setTerminalReason` closure (#1558: a TYPED reason, not English — the
///   presenter authors the sentence). Use when the caller has NOT pre-reset state (Toggle paths).
///
/// `CancellationError` is treated as a coordinated unwind in both shapes: skipped from the
/// log (mirrors prior inline behavior at the former root-state file pre-warm catch), but `recover`
/// still hides overlay + clears lock so the UI doesn't get stuck mid-state.
@MainActor
struct HeartControlRecovery {
  let hideOverlay: @MainActor () -> Void
  let setLocked: @MainActor (Bool) -> Void
  let backend: @MainActor () -> String

  func logDispatchFailure(_ error: any Error, op: String) {
    guard !(error is CancellationError) else { return }
    // Row 11 (#1525 PR J-1): production-inert today (only `.preWarm` can
    // actually throw here) — normalize anyway so a future implementation
    // change that starts throwing something real still alerts.
    SentryBreadcrumb.captureError(
      SentryCaptureBoundaryError.normalizingHeartControlFailure(error),
      category: .pipelineDispatchFailed, stage: "recording",
      extra: ["op": op, "backend": backend()])
  }

  func recover(
    error: any Error, op: String, reason: TerminalNoticeReason,
    setTerminalReason: @MainActor (TerminalNoticeReason) -> Void
  ) {
    let isCancellation = error is CancellationError
    if !isCancellation {
      SentryBreadcrumb.captureError(
        SentryCaptureBoundaryError.normalizingHeartControlFailure(error),
        category: .pipelineDispatchFailed, stage: "recording",
        extra: ["op": op, "backend": backend()])
    }
    hideOverlay()
    setLocked(false)
    if !isCancellation {
      setTerminalReason(reason)
    }
  }
}
