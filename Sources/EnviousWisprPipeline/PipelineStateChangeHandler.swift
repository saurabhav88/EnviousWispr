import EnviousWisprCore
import Foundation

/// Executes the side-effect plan produced by `PipelineStateChangePlanner`.
///
/// One instance per pipeline (Parakeet / WhisperKit). The handler holds no
/// pipeline reference itself — the caller passes the pipeline-scoped inputs
/// (`pipelineOverlayIntent`, `lastPolishError`, `currentTranscript`) for each
/// transition. the former root state remains the owner of cross-pipeline state (the
/// `postCompletionWarningTask`, the tiebreaker, the hotkey register/unregister
/// ordering), and the handler reaches back into those through narrow
/// callbacks.
///
/// Why the warning task is NOT owned by the handler: the current production
/// `schedulePostCompletionWarning` at the former root-state file treats
/// the WhisperKit driver's state at `.complete` (pre-Rung-5 also `.ready`)
/// delayed guard. That check crosses pipeline boundaries (the warning can be
/// scheduled from Parakeet's closure and still fire if WhisperKit is in
/// `.ready` when the 400 ms sleep wakes). Moving the task into a per-pipeline
/// handler would split that shared lifecycle across two owners — a behavior
/// change, not a refactor. Preserved verbatim via the `cancelPendingWarning`
/// and `schedulePolishFailedWarning` callbacks.
@MainActor
public final class PipelineStateChangeHandler {
  /// Overlay show is now a closure rather than a protocol existential. The
  /// caller wires this directly to the concrete `RecordingOverlayPanel.show(
  /// intent:audioLevelProvider:isRecordingLocked:)` so dispatch is static,
  /// matching commit-1's inline behavior exactly.
  public typealias ShowOverlay = @MainActor (OverlayIntent) -> Void

  private let showOverlay: ShowOverlay
  private let cancelPendingWarning: @MainActor () -> Void
  private let schedulePolishFailedWarning: @MainActor () -> Void
  private let appendCompletedTranscript: @MainActor (Transcript) -> Void
  private let reportDictationCompleted: @MainActor (Transcript) -> Void
  private let reportPipelineFailed: @MainActor (String) -> Void
  /// #1167: schedule the transient "Couldn't save to history: <reason>" pill.
  private let scheduleHistorySaveFailedWarning: @MainActor (String) -> Void
  /// #1434: schedule the transient salvaged-lead disclosure pill.
  private let scheduleSalvagedLeadWarning: @MainActor () -> Void
  /// #1408: schedule the transient interruption disclosure pill. The callback
  /// carries the two typed facts (disclosure + also-trimmed-lead) unchanged;
  /// #1567: `DictationNarrator` owns all four sentences.
  private let scheduleInterruptionWarning:
    @MainActor (_ disclosure: CompletionInterruptionDisclosure, _ alsoTrimmedLead: Bool) -> Void
  /// #2087: append the just-saved PENDING row. Distinct from the completed
  /// append because the row is temporary and separately presented; chunks 9 and
  /// 10 own its lifetime and its badge.
  private let appendPendingTranscript: @MainActor (Transcript) -> Void
  /// #2087: present the Escape Recovery pill for a durably saved row. Takes the
  /// payload the plan cannot carry, so a pill can never be raised pointing at
  /// nothing. Chunk 8 supplies the implementation and owns the dwell.
  private let presentEscapeRecoveryPill: @MainActor (CancelUndoPayload) -> Void
  /// #2087: emit `escape_recovery.completed` with its terminal outcome.
  /// #2087: takes the TRANSCRIPT alongside the outcome, because every number
  /// the completion event needs — ASR and polish latency, total processing
  /// time, backend, and the persisted take id — already lives on the row that
  /// was just written. Reaching back into the driver for them instead would
  /// read whatever it holds NOW, which after a fast follow-up recording is a
  /// different take. Nil for `.nothingToRestore`, which has no row by
  /// definition.
  private let reportEscapeRecoveryCompleted:
    @MainActor (EscapeRecoveryTerminalOutcome, Transcript?) -> Void

  public init(
    showOverlay: @escaping ShowOverlay,
    cancelPendingWarning: @escaping @MainActor () -> Void,
    schedulePolishFailedWarning: @escaping @MainActor () -> Void,
    appendCompletedTranscript: @escaping @MainActor (Transcript) -> Void,
    reportDictationCompleted: @escaping @MainActor (Transcript) -> Void,
    reportPipelineFailed: @escaping @MainActor (String) -> Void,
    scheduleHistorySaveFailedWarning: @escaping @MainActor (String) -> Void,
    scheduleSalvagedLeadWarning: @escaping @MainActor () -> Void = {},
    scheduleInterruptionWarning: @escaping @MainActor (
      _ disclosure: CompletionInterruptionDisclosure, _ alsoTrimmedLead: Bool
    ) -> Void = { _, _ in },
    // #2087: no-op defaults, so a call site supplying none of the three behaves
    // exactly as it did. `PipelineStateChangeHandlerFactory` supplies all three.
    appendPendingTranscript: @escaping @MainActor (Transcript) -> Void = { _ in },
    presentEscapeRecoveryPill: @escaping @MainActor (CancelUndoPayload) -> Void = { _ in },
    reportEscapeRecoveryCompleted: @escaping @MainActor (
      EscapeRecoveryTerminalOutcome, Transcript?
    ) -> Void = { _, _ in }
  ) {
    self.showOverlay = showOverlay
    self.cancelPendingWarning = cancelPendingWarning
    self.schedulePolishFailedWarning = schedulePolishFailedWarning
    self.appendCompletedTranscript = appendCompletedTranscript
    self.reportDictationCompleted = reportDictationCompleted
    self.reportPipelineFailed = reportPipelineFailed
    self.scheduleHistorySaveFailedWarning = scheduleHistorySaveFailedWarning
    self.scheduleSalvagedLeadWarning = scheduleSalvagedLeadWarning
    self.scheduleInterruptionWarning = scheduleInterruptionWarning
    self.appendPendingTranscript = appendPendingTranscript
    self.presentEscapeRecoveryPill = presentEscapeRecoveryPill
    self.reportEscapeRecoveryCompleted = reportEscapeRecoveryCompleted
  }

  /// Drive the full state-change behavior contract for one pipeline.
  ///
  /// Step 1 — delegate plan derivation to the pure planner (tested
  /// comprehensively in `PipelineStateChangePlannerTests`).
  /// Step 2 — execute each side effect through the injected dependencies.
  /// No decision logic beyond translating typed effects into calls.
  public func handle(
    to newState: any PipelineStateProtocol,
    pipelineOverlayIntent: OverlayIntent,
    lastPolishError: String?,
    currentTranscript: Transcript?,
    historySaved: Bool,
    historySaveReason: String?,
    salvagedLead: Bool = false,
    interruptionDisclosure: CompletionInterruptionDisclosure? = nil,
    // #2087: this session's completion, taken from the driver moments earlier.
    // It splits here and only here: the sendable outcome goes into the plan, the
    // paste target stays behind. `PipelineStateChangePlan` is `Sendable` and
    // `AXUIElement` is a main-actor handle, so the plan can say THAT a pill is
    // due and never what it points at. Nil for every user with the setting off,
    // which is the default. Being wired is not the same as being able to fire,
    // and conflating the two is how a dormant path gets read as a live one.
    escapeRecoveryCompletion: EscapeRecoveryCompletion? = nil
  ) {
    let plan = PipelineStateChangePlanner.plan(
      to: newState,
      pipelineOverlayIntent: pipelineOverlayIntent,
      isClipboardFallback: currentTranscript?.metrics?.pasteTier == "clipboard_only"
        || currentTranscript?.metrics?.pasteTier == "clipboard_only_ax_denied",
      isAccessibilityToast: currentTranscript?.metrics?.pasteTier == "clipboard_only_ax_denied",
      lastPolishError: lastPolishError,
      hasCurrentTranscript: currentTranscript != nil,
      historySaved: historySaved,
      historySaveReason: historySaveReason,
      salvagedLead: salvagedLead,
      interruptionDisclosure: interruptionDisclosure,
      escapeRecoveryOutcome: escapeRecoveryCompletion?.outcome
    )
    for effect in plan.effects {
      switch effect {
      case .cancelPendingWarning:
        cancelPendingWarning()
      case .schedulePolishFailedWarning:
        schedulePolishFailedWarning()
      case .showOverlay(let intent):
        showOverlay(intent)
      case .appendCompletedTranscript:
        if let t = currentTranscript {
          appendCompletedTranscript(t)
        }
      case .reportDictationCompleted:
        if let t = currentTranscript {
          reportDictationCompleted(t)
        }
      case .reportPipelineFailed(let msg):
        reportPipelineFailed(msg)
      case .scheduleHistorySaveFailedWarning(let reason):
        scheduleHistorySaveFailedWarning(reason)
      case .scheduleSalvagedLeadWarning:
        scheduleSalvagedLeadWarning()
      case .scheduleInterruptionWarning(let disclosure, let alsoTrimmedLead):
        scheduleInterruptionWarning(disclosure, alsoTrimmedLead)
      case .appendPendingTranscript:
        if let t = currentTranscript {
          appendPendingTranscript(t)
        }
      case .presentEscapeRecoveryPill:
        // #2087: the unwrap is the ONLY thing standing between this marker and a
        // pill, and it needs no runtime guarantee behind it — a nil payload here
        // means `escapeRecoveryCompletion` was `.nothingToRestore` or absent, and
        // `EscapeRecoveryCompletion` cannot express `.saved` without a target in
        // any build configuration. Silence rather than a placeholder: a pill the
        // user presses to no effect leaves them unable to tell whether the
        // feature or their own text is broken.
        if let payload = escapeRecoveryCompletion?.payload {
          presentEscapeRecoveryPill(payload)
        }
      case .reportEscapeRecoveryCompleted(let outcome):
        reportEscapeRecoveryCompleted(outcome, currentTranscript)
      }
    }
  }
}
