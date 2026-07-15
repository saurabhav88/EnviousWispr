import EnviousWisprCore
import EnviousWisprLLM
import Foundation

/// Every side effect the state-change closure produces, as a value.
///
/// Executed in order by the caller. The caller owns stateful concerns
/// (the warning `Task`, the concrete telemetry service, the overlay panel);
/// the planner is a pure projection from inputs to this list.
enum PipelineStateSideEffect: Equatable, Sendable {
  /// Cancel any pending post-completion warning task. Emitted on every
  /// non-complete transition — mirrors the former root-state file behavior.
  case cancelPendingWarning

  /// Schedule the "Polish failed -- using raw text" warning 400 ms after
  /// completion. Emitted ONLY on `.complete` when a polish error was recorded
  /// AND the paste did not fall back to clipboard-only.
  case schedulePolishFailedWarning

  /// Render this intent on the overlay. Always emitted exactly once per call.
  case showOverlay(OverlayIntent)

  /// Append the just-completed transcript to the in-memory history cache
  /// (no disk I/O — finalizer already persisted before `.complete` fires).
  /// Emitted only when `hasCurrentTranscript` is true; `.complete` with
  /// `nil` transcript is treated as a transient stale-cache condition and
  /// no append is emitted.
  case appendCompletedTranscript

  /// Call `TelemetryService.shared.reportDictationCompleted(transcript:inputMode:)`
  /// using the caller's current transcript. Emitted only when `.complete` AND
  /// the pipeline has a current transcript — matches the former root state's `if let t`.
  case reportDictationCompleted

  /// Call `TelemetryService.shared.pipelineFailed(...)` with the captured error
  /// code. The caller supplies the fixed `stage` / `errorCategory` / `backend`
  /// literals that today live in the former root state's closures.
  case reportPipelineFailed(errorCode: String)

  /// #1167: schedule the transient "Couldn't save to history: <reason>" pill
  /// ~400 ms after completion, concurrent with the (already-completed) paste.
  /// Emitted ONLY on `.complete` when the durable history save threw but
  /// delivery still ran (best-effort save). Reuses the single post-completion
  /// warning slot, so it is mutually exclusive with `schedulePolishFailedWarning`.
  case scheduleHistorySaveFailedWarning(reason: String)

  /// #1434: schedule the transient "Beginning of dictation was unclear and was
  /// skipped" pill on a SALVAGED completion — the degraded-lead retry recovered
  /// the transcript by trimming a poisoned prefix, so the pasted text is
  /// missing its lead, and a trimmed lead can invert meaning invisibly. The
  /// disclosure never touches the pasted text. Shares the single
  /// post-completion warning slot: history-save-failed > disconnect >
  /// salvaged-lead > polish-failed (rank 2 inserted by #1408).
  case scheduleSalvagedLeadWarning

  /// #1408: schedule the transient interruption pill on a completion whose
  /// capture was interrupted mid-recording. The pasted text is what survived,
  /// so the user must be told it may be cut short BEFORE they send it. The
  /// disclosure picks the sentence family: `.deviceRemoved` may say
  /// "Microphone disconnected"; `.otherInterruption` gets the neutral
  /// "Recording interrupted" wording (grounded review A1 — a non-disconnect
  /// salvage must not paste truncated text silently).
  ///
  /// `alsoTrimmedLead` is true when this take ALSO lost its opening to the
  /// degraded-lead retry (#1434). One take can lose both ends, and a plain
  /// ranking would tell the user only about the tail — so the combined case gets
  /// its own copy rather than suppressing the lead notice. One effect carrying
  /// flags, not two effects: the difference is a message, not a mechanism.
  case scheduleInterruptionWarning(
    disclosure: CompletionInterruptionDisclosure, alsoTrimmedLead: Bool)
}

struct PipelineStateChangePlan: Equatable, Sendable {
  let effects: [PipelineStateSideEffect]
}

/// Pure projection from a state transition's observable inputs to the ordered
/// list of side effects the former root state's `onStateChange` closures must perform.
///
/// **What lives here:**
/// - Three-way overlay priority on `.complete`
///   (clipboardFallback > polish-failed-warning > success).
/// - Warning-task cancellation on any non-complete transition.
/// - Telemetry + history-reload emission for `.complete` / `.error`.
///
/// **What does NOT live here** (stays with the caller / future handler):
/// - Stateful `Task` ownership for the delayed polish-failed warning.
/// - The `.ready`-as-completion-equivalent guard inside the delayed warning
///   closure (that guard fires at 400 ms, not at plan time).
/// - Hotkey register/unregister, `isRecordingLocked = false` reset, the
///   inactive→active tiebreaker, the `onPipelineStateChange?` fan-out.
///   All four are root-state-only concerns that the bible (§7) keeps inline.
///
/// Kept `internal` to `EnviousWisprPipeline`: only the handler in this
/// module calls `plan(...)`; tests reach it through `@testable import`.
@MainActor
enum PipelineStateChangePlanner {
  static func plan(
    to newState: any PipelineStateProtocol,
    pipelineOverlayIntent: OverlayIntent,
    isClipboardFallback: Bool,
    isAccessibilityToast: Bool,
    lastPolishError: String?,
    hasCurrentTranscript: Bool,
    historySaved: Bool,
    historySaveReason: String?,
    salvagedLead: Bool = false,
    interruptionDisclosure: CompletionInterruptionDisclosure? = nil
  ) -> PipelineStateChangePlan {
    var effects: [PipelineStateSideEffect] = []
    let interrupted = interruptionDisclosure != nil

    // #1167: a degraded-save completion (delivery ran, history write threw).
    // Only meaningful on `.complete` with a transcript in hand.
    let historySaveFailed = hasCurrentTranscript && !historySaved

    // Step 1 — overlay resolution + warning scheduling / cancellation.
    // Order mirrors the production closures at the former root-state file: resolve intent, schedule warning iff applicable, then show.
    let resolvedOverlayIntent: OverlayIntent
    switch newState.activity {
    case .complete:
      if isAccessibilityToast {
        resolvedOverlayIntent = .accessibilityToast
      } else if isClipboardFallback {
        resolvedOverlayIntent = .clipboardFallback
      } else if let polishError = lastPolishError {
        resolvedOverlayIntent = pipelineOverlayIntent
        // #945: a "skipped" notice (no key yet, too long, timed out) is not a
        // hard failure — the in-window banner shows the actionable
        // "AI cleanup skipped: ..." message, but the transient
        // "Polish failed -- using raw text" overlay would contradict it, so
        // suppress it for skips. Real failures (and the unchanged Apple
        // Intelligence / legacy strings) still schedule the warning.
        // #1167: a history-save failure takes the single post-completion
        // warning slot (its pill is scheduled in Step 2), so suppress the
        // polish-failed pill when both fired this session.
        // #1434: a salvaged-lead completion also takes the single warning
        // slot ahead of the polish pill (data-loss disclosure beats a
        // formatting notice) — scheduled below, outside this branch.
        // #1408: so does a mid-recording disconnect, for the same reason.
        if !historySaveFailed, !interrupted, !salvagedLead,
          !PolishFailureReason.isSkipNotice(polishError)
        {
          effects.append(.schedulePolishFailedWarning)
        }
      } else {
        resolvedOverlayIntent = pipelineOverlayIntent
      }
      // Disclosure priority within the single post-completion warning slot:
      // history-save-failed (scheduled in Step 2) > disconnect > salvaged-lead >
      // polish-failed (suppressed above). Encoded as explicit suppression
      // conditions, NOT as array order — `schedulePostCompletionWarning` is
      // last-writer-wins, so position in this list decides nothing.
      //
      // #1408: a take can lose its opening (lead trimmed) AND its ending (mic
      // died). Suppressing the lead notice under a plain ranking would tell the
      // user only that the text is cut short, hiding the dropped opening — so
      // the both-fired case carries its own copy instead.
      if let disclosure = interruptionDisclosure, !historySaveFailed {
        effects.append(
          .scheduleInterruptionWarning(disclosure: disclosure, alsoTrimmedLead: salvagedLead))
      }
      if salvagedLead, !historySaveFailed, !interrupted {
        effects.append(.scheduleSalvagedLeadWarning)
      }
    default:
      effects.append(.cancelPendingWarning)
      resolvedOverlayIntent = pipelineOverlayIntent
    }
    effects.append(.showOverlay(resolvedOverlayIntent))

    // Step 2 — complete-path: append to in-memory history + telemetry.
    // Phase C: replaced unconditional disk-backed reload with an
    // in-memory append that only fires when the pipeline has a
    // current transcript. Finalizer already persisted by the time
    // `.complete` is observed (TranscriptFinalizer.swift:126), so the
    // new row is on disk regardless. The in-memory append keeps the
    // history cache visibly fresh without an O(n) disk scan.
    if case .complete = newState.activity {
      if hasCurrentTranscript {
        // #1167: skip the in-memory history append on a save failure — the row
        // was never persisted, so the append would show a phantom entry that
        // vanishes on restart (it reappears as a "Recovered" entry via the
        // retained crash-recovery spool). Skipping the append also skips the
        // `onDurableSave` spool cleanup wired inside that handler, so the spool
        // is retained. Instead, schedule the reason pill. Telemetry still fires.
        if historySaved {
          effects.append(.appendCompletedTranscript)
        } else if let reason = historySaveReason {
          effects.append(.scheduleHistorySaveFailedWarning(reason: reason))
        }
        effects.append(.reportDictationCompleted)
      }
    }

    // Step 3 — error-path telemetry. #1558: the payload is now a typed
    // `TerminalNoticeReason`; its stable `rawValue` is the PostHog
    // `pipeline.failed.error_code`. String only at the telemetry boundary — no
    // customer copy, no user payload.
    if case .error(let reason) = newState.activity {
      effects.append(.reportPipelineFailed(errorCode: reason.rawValue))
    }

    return PipelineStateChangePlan(effects: effects)
  }
}
