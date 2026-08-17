import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// #1408: assembles a `PipelineStateChangeHandler` from the AppKit-owned seams
/// its closures need, so `DictationLifecycleCoordinator` stays a thin wiring site
/// (the same move #1434 made for `DictationCompletedReporting`). Pure closure
/// assembly — no state, no decisions; the pure planner owns which effect fires.
///
/// #1567 (heartpath E3): these closures translate each typed planner effect into
/// a typed `RecordingWarningReason`; `DictationNarrator` owns every user-facing
/// sentence. No literals live here anymore.
@MainActor
enum PipelineStateChangeHandlerFactory {
  /// The coordinator-owned seams the handler's closures reach back into. Passed
  /// as closures rather than a coordinator reference so the coordinator's own
  /// methods stay `private` (its non-private-method ceiling is exactly full) and
  /// the handler cannot reach anything it was not handed.
  struct Deps {
    let showOverlay: @MainActor (OverlayIntent) -> Void
    let cancelPendingWarning: @MainActor () -> Void
    /// The generic single-slot post-completion pill. Last-writer-wins by design;
    /// the planner guarantees exactly one caller per completion. #1567: carries a
    /// typed `RecordingWarningReason`; `DictationNarrator` authors the sentence.
    let schedulePostCompletionWarning: @MainActor (RecordingWarningReason) -> Void
    let appendTranscript: @MainActor (Transcript) -> Void
    /// #1063 PR1: the durable save landed, so this session's spool + key can go.
    let onDurableSave: @MainActor (String) -> Void
    /// `nil` once the coordinator is gone, so a completion racing teardown emits
    /// nothing rather than reporting an empty input mode.
    let inputMode: @MainActor () -> String?
    /// This handler's driver — completion telemetry reads its length, stop
    /// reason, route, capture health, and salvage markers (#1060, #1376, #1434).
    let driver: KernelDictationDriver
    /// #2087: raise the Escape Recovery pill. Separate from `showOverlay`
    /// because the payload carries main-actor AX handles the `Sendable` intent
    /// cannot. No-op default keeps every existing construction site unchanged.
    var presentEscapeRecoveryPill: @MainActor (CancelUndoPayload) -> Void = { _ in }
    /// #2087: put the held row into History's in-memory list. It is already on
    /// disk by the time this runs — the kernel's storage step wrote it to the
    /// pending namespace — so this is the in-session view catching up, not a
    /// second write. Without it a held recovery is invisible until the next
    /// launch, and the 24-hour offer would quietly begin with the user unable
    /// to see the thing being offered.
    var appendPendingTranscript: @MainActor (Transcript) -> Void = { _ in }
    /// #2087: the completion half of the funnel. Takes the terminal outcome AND
    /// the row it describes, and reads every number from that row rather than
    /// from the driver — the driver holds whatever take is current at emission
    /// time, which after a fast follow-up recording is a different one.
    /// Nil transcript for the terminals that have no row.
    var reportEscapeRecoveryCompleted:
      @MainActor (EscapeRecoveryTerminalOutcome, Transcript?) -> Void = { _, _ in }
  }

  static func make(backendLabel: String, deps: Deps) -> PipelineStateChangeHandler {
    PipelineStateChangeHandler(
      showOverlay: { intent in deps.showOverlay(intent) },
      cancelPendingWarning: { deps.cancelPendingWarning() },
      schedulePolishFailedWarning: {
        deps.schedulePostCompletionWarning(.polishFailed)
      },
      appendCompletedTranscript: { t in
        deps.appendTranscript(t)
        // #1063 PR1: the save is durable by `.complete`; delete this session's
        // spool + key. nil unless recovery was armed for this take.
        if let sid = t.recoverySessionID { deps.onDurableSave(sid) }
      },
      reportDictationCompleted: { t in
        guard let inputMode = deps.inputMode() else { return }
        // #1376/#1434: route + capture-health + salvage argument assembly lives
        // in `DictationCompletedReporting` (thin-factory discipline).
        DictationCompletedReporting.report(
          transcript: t, inputMode: inputMode, driver: deps.driver)
      },
      reportPipelineFailed: { msg in
        TelemetryService.shared.pipelineFailed(
          stage: "transcription", errorCategory: "pipeline_error", errorCode: msg,
          recoverable: false, backend: backendLabel,
          // #1714: the failing population is the one this issue exists to
          // measure, so a failed take must still say which microphone it used.
          inputResolutionSource: deps.driver.lastInputResolutionSource)
      },
      // #1167: history-save-failed pill (post-completion warning slot, ~400 ms).
      scheduleHistorySaveFailedWarning: { reason in
        deps.schedulePostCompletionWarning(.historySaveFailed(reason: reason))
      },
      // #1434: salvaged-lead disclosure pill — the degraded-lead retry recovered
      // this dictation by trimming a poisoned opening, so the pasted text is
      // missing its lead.
      scheduleSalvagedLeadWarning: {
        deps.schedulePostCompletionWarning(.salvagedBeginning)
      },
      // #1408: capture died mid-recording and the pasted text is what survived.
      // Forward the two typed facts unchanged; `DictationNarrator` picks the
      // sentence family (only a VERIFIED device removal may say "Microphone
      // disconnected"; a non-disconnect salvage gets the neutral wording) and the
      // both-ends-lost variant. The four sentences are founder-LOCKED (2026-07-15).
      scheduleInterruptionWarning: { disclosure, alsoTrimmedLead in
        deps.schedulePostCompletionWarning(
          .interruptedTail(disclosure: disclosure, alsoTrimmedLead: alsoTrimmedLead))
      },
      // #2087: the WHOLE payload goes to the panel, not just the row id. The
      // payload's reason for existing is the paste TARGET — the app and field
      // the dictation was aimed at — and dropping it here would have made the
      // feature's own promise unreachable while everything still compiled.
      //
      // A dedicated seam rather than `showOverlay`, because `OverlayIntent` is
      // `Sendable` and cannot carry main-actor AX handles.
      // Both wired at activation (chunk 12). They carried no-op defaults through
      // chunks 6-11 so the transport could ship without behaviour, and leaving
      // either defaulted here is the shape of bug this feature cannot have: a
      // held row nobody can see, or a funnel missing the event that says it
      // worked.
      appendPendingTranscript: { transcript in deps.appendPendingTranscript(transcript) },
      presentEscapeRecoveryPill: { payload in deps.presentEscapeRecoveryPill(payload) },
      reportEscapeRecoveryCompleted: { outcome, transcript in
        deps.reportEscapeRecoveryCompleted(outcome, transcript)
      }
    )
  }
}
