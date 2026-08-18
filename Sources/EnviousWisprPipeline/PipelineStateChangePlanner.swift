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

  /// Schedule the "Polish failed. Using raw text." warning 400 ms after
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

  // MARK: Escape Recovery (#2087)
  //
  // Value-only MARKERS. This plan is `Sendable`, and the pill's paste target is
  // not — `AXUIElement` and `NSRunningApplication` are main-actor handles. The
  // handler retains the real payload and requires it non-nil before presenting;
  // the plan only ever says THAT a pill is due, never what it points at.

  /// Append the just-saved PENDING row to the in-memory history cache.
  ///
  /// Distinct from `appendCompletedTranscript`, and a saved Escape completion
  /// emits this one INSTEAD. They differ in what the row is: an ordinary
  /// completion is permanent History, while a pending row is temporary and
  /// separately presented (chunks 9 and 10 own its lifetime and its badge).
  /// Emitting both would put one dictation in History twice under two different
  /// identities — which is the reason the two are exclusive rather than ordered.
  case appendPendingTranscript

  /// Present the Escape Recovery pill (chunk 8 owns its dwell).
  ///
  /// Emitted only for `.saved`, because the pill is an offer to restore something
  /// that exists. Whoever produces the completion must therefore not report
  /// `.saved` until the write has actually landed — #1897 is what happens when a
  /// recovery path promises a save it did not make. The handler additionally
  /// unwraps a payload, so this marker alone cannot raise a pill pointing at
  /// nothing.
  case presentEscapeRecoveryPill

  /// Emit `escape_recovery.completed` with its terminal outcome.
  ///
  /// Carries the outcome because `saved` / `empty` / `transcription_failed` /
  /// `save_failed` / `abandoned` are the question the feature exists to answer:
  /// whether people who opt in actually get their text back. A boolean would
  /// collapse a user's deliberate abandon into a failure of ours.
  case reportEscapeRecoveryCompleted(outcome: EscapeRecoveryTerminalOutcome)

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
    interruptionDisclosure: CompletionInterruptionDisclosure? = nil,
    // #2087: non-nil means this transition concludes an Escape Recovery, and it
    // takes over the completion path entirely (Step 2b). Sendable by
    // construction — the pill's paste target travels beside the plan, never in
    // it. Nil is the ordinary-dictation value and leaves the resulting plan
    // byte-identical, so no existing caller changes by a single effect.
    escapeRecoveryOutcome: EscapeRecoveryTerminalOutcome? = nil
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
        // "Polish failed. Using raw text." overlay would contradict it, so
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
    // Phase C: replaced an unconditional disk-backed reload with an in-memory
    // append that only fires when the pipeline has a current transcript.
    // Storage is BEST-EFFORT (#1167): a successful save means the row is
    // already on disk, and the failure branch below deliberately skips the
    // append rather than showing a phantom row. The in-memory append keeps the
    // history cache visibly fresh without an O(n) disk scan.
    //
    // #2087: an Escape Recovery takes this path over completely (Step 2b). The
    // two are mutually exclusive rather than additive — the row is written to
    // `pending/`, not to History, so emitting the ordinary append as well would
    // put one dictation in the list twice under two identities, and
    // `reportDictationCompleted` would count a cancelled take as a delivered one.
    if case .complete = newState.activity, escapeRecoveryOutcome == nil {
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

    // Step 2b — Escape Recovery (#2087). Deliberately NOT gated on
    // `newState.activity`: the outcomes conclude on different terminals — a
    // saved recovery on `.complete`, an abandoned one on the `.idle` callback —
    // and the caller has already decided that this transition is the one that
    // ends the recovery. Re-deriving that from the state here would be a second
    // authority disagreeing with the first.
    //
    // Only `.saved` produces a row and an offer. `empty`, `transcriptionFailed`
    // and `saveFailed` have nothing to give back, and `abandoned` is a user who
    // asked for nothing to be given back — all four report and stop.
    if let outcome = escapeRecoveryOutcome {
      if outcome == .saved {
        effects.append(.appendPendingTranscript)
        effects.append(.presentEscapeRecoveryPill)
      }
      // A FAILED WRITE has to say so, and it is the only one of the four that
      // does (cloud review). `empty`, `transcriptionFailed` and `abandoned` all
      // reach a terminal the user can already read: the first two show the
      // ordinary no-text ending, and the third is the thing they just asked for.
      // `saveFailed` is different — the user pressed cancel EXPECTING this take
      // to be kept, the disk refused, and without this the pill simply never
      // appears. Silence there reads as "it worked and I missed the offer",
      // which is the worst available reading because it stops them looking in
      // History, where there is also nothing.
      //
      // Reuses the ordinary path's single post-completion warning slot rather
      // than inventing a second failure surface; a recovery cannot collide with
      // the polish or interruption pills, because Step 2b replaces the ordinary
      // completion effects entirely.
      if outcome == .saveFailed, let reason = historySaveReason {
        effects.append(.scheduleHistorySaveFailedWarning(reason: reason))
      }
      effects.append(.reportEscapeRecoveryCompleted(outcome: outcome))
    }

    // Step 3 — error-path telemetry. #1558: the payload is now a typed
    // `TerminalNoticeReason`; its stable `rawValue` is the PostHog
    // `pipeline.failed.error_code`. String only at the telemetry boundary — no
    // customer copy, no user payload.
    if case .error(let reason) = newState.activity {
      effects.append(.reportPipelineFailed(errorCode: reason.rawValue))
    }
    // #1891/#1923/#1925: `.zeroSignal` and `.noTransport` moved from `.error`
    // to `.advisory` for PRESENTATION only. Their telemetry must not move
    // with them — `zero_signal` and `no_audio_captured` are existing series
    // (`zero_signal`: 340 events / 50 users per 30d, the baseline the whole
    // Phase 2 analysis rests on) that keep emitting under their unchanged
    // codes. Splitting or renaming either would be the #1813 retired-
    // vocabulary trap, self-inflicted. An exhaustive switch (not a second
    // freestanding `if case`) so a FUTURE fourth advisory case is a compile
    // error here, not a silently skipped telemetry record.
    //
    // `.vadGateNoSpeech` emits NOTHING here on purpose: it is already counted
    // by `audio.vad_gate_no_speech` (#1845), and a second record would both
    // double-count that population and inflate total `pipeline.failed` volume
    // with takes that were never a pipeline failure.
    if case .advisory(let reason) = newState.activity {
      switch reason {
      case .zeroSignal:
        effects.append(
          .reportPipelineFailed(errorCode: TerminalNoticeReason.zeroSignal.rawValue))
      case .noTransport:
        effects.append(
          .reportPipelineFailed(errorCode: TerminalNoticeReason.noAudioCaptured.rawValue))
      case .vadGateNoSpeech:
        break
      }
    }

    return PipelineStateChangePlan(effects: effects)
  }
}
