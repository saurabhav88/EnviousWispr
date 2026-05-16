import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// Recovery actions for failed heart-control dispatches (`.requestStop`, `.toggleRecording`,
/// `.cancelRecording`). Extracted from AppState to keep the coordinator thin (issue #585).
///
/// Two shapes:
/// - `logDispatchFailure` — log only. Use when the caller has already reset overlay + lock
///   before the dispatch (Stop, WhisperKit Cancel paths).
/// - `recover` — full recovery: log, hide overlay, clear lock, surface user-facing message
///   via the pipeline. Use when the caller has NOT pre-reset state (Toggle paths).
///
/// `CancellationError` is treated as a coordinated unwind in both shapes: skipped from the
/// log (mirrors prior inline behavior at `AppState.swift` pre-warm catch), but `recover`
/// still hides overlay + clears lock so the UI doesn't get stuck mid-state.
@MainActor
struct HeartControlRecovery {
  let hideOverlay: @MainActor () -> Void
  let setLocked: @MainActor (Bool) -> Void
  let backend: @MainActor () -> String

  func logDispatchFailure(_ error: any Error, op: String) {
    guard !(error is CancellationError) else { return }
    SentryBreadcrumb.captureError(
      error, category: .pipelineDispatchFailed, stage: "recording",
      extra: ["op": op, "backend": backend()])
  }

  func recover(
    error: any Error, pipeline: any DictationPipeline, op: String, message: String
  ) {
    let isCancellation = error is CancellationError
    if !isCancellation {
      SentryBreadcrumb.captureError(
        error, category: .pipelineDispatchFailed, stage: "recording",
        extra: ["op": op, "backend": backend()])
    }
    hideOverlay()
    setLocked(false)
    if !isCancellation {
      pipeline.setExternalError(message)
    }
  }
}
