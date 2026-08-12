import EnviousWisprCore
import EnviousWisprPipeline

/// #1567 (heartpath E3): a typed fact for an in-panel recording notice rendered
/// through `RecordingOverlayPanel.flashRecordingNotice`. Distinct from
/// `.warning`: these appear inside the LIVE recording panel, not as a
/// post-completion pill, so they carry their own family rather than a
/// `RecordingWarningReason`. Lives in AppKit — the panel and its callers are the
/// only code that touches it; it never crosses into Pipeline.
enum RecordingNoticeReason: Equatable, Sendable {
  /// Within the last minute before the 60-minute cap. Persistent (nil dismiss).
  case approachingCap
  /// The VAD model can't load, so silence auto-stop is off. Timed (4 s dismiss).
  case autoStopUnavailable
}

/// #1558 (E1) / #1564 (E2). The single, stateless authority that turns the
/// engine's typed facts into the customer-facing words shown on the pill, the
/// main window, the toolbar badge, and the sidebar status chip.
///
/// This is the "what we say" half of the one-voice split: the engine emits the
/// fact (`TerminalNoticeReason` for terminal failures/interruptions,
/// `ProcessingPhase` for the transcribe/polish stages), this narrator — and
/// ONLY this narrator — authors the English. It lives in AppKit because the
/// engine modules that produce the facts sit below AppKit and cannot author UI
/// copy without inverting dependency direction. Stateless (an `enum` with
/// static funcs): neither stored nor environment-injected. Promote to an
/// injected instance only if a test ever needs to swap the mapping.
///
/// Renamed from `TerminalNoticePresenter` in E2 once it began authoring more
/// than terminal notices. As of E4 (#1569) it is the SOLE voice (heartpath
/// step 6, "one voice" COMPLETE): every recording-lifecycle status/notice
/// literal — spoken announcements, status pills, the window/badge/sidebar status
/// words, and the recovery container AX label — is authored here and nowhere
/// else. The renderers (panel, main window, sidebar) are pure presenters.
enum DictationNarrator {

  // MARK: - Terminal failures / interruptions (E1)

  /// The six sentences are founder-LOCKED (issue #1558, 2026-07-15). The design
  /// rule: `[Category] error. Try again.` = our bug, just retry (a deliberate
  /// self-triage channel — a user reporting "Transcription error" names the
  /// stage with no logs); a plain sentence = a true event that happened. Raw
  /// internal detail never reaches here — it stays owned by the producer's
  /// Sentry site.
  static func copy(for reason: TerminalNoticeReason) -> String {
    switch reason {
    // Our-fault start / capture failures → retry.
    case .prepareFailed, .modelWedged, .modelLoadFailed, .captureStartFailed,
      .micWouldNotOpen, .captureStalled, .zeroSignal:
      return "Audio capture error. Try again."
    // Our-fault transcribe failures (incl. "couldn't catch that") → retry.
    case .asrFailed, .asrWedged, .asrInterrupted, .noAudioCaptured,
      .asrEmptyWithSpeech, .emptyAfterProcessing, .unknown:
      return "Transcription error. Try again."
    // User-actionable.
    case .permissionDenied:
      return "Microphone access is off."
    case .noMicrophoneFound:
      return "No microphone found. Please connect one."
    // Informational interruptions (audio was saved).
    case .deviceRemoved:
      return "Microphone disconnected."
    case .engineLost, .unknownInterruption:
      return "Recording interrupted."
    }
  }

  // MARK: - Processing / phase labels (E2, #1564)

  // The processing words are founder-LOCKED unchanged (2026-07-15). Three
  // byte-distinct render forms are preserved: the active pill and main window
  // use three ASCII periods; the toolbar status badge uses ONE Unicode ellipsis
  // (`\u{2026}`); the tight sidebar chip uses no ellipsis. They are three
  // presentation forms of one authority, not three authorities.

  /// Active-pill / main-window form: three ASCII periods, plus the 60-minute
  /// cap prefix on the max-duration variant.
  static func copy(for phase: ProcessingPhase) -> String {
    switch phase {
    case .transcribing:
      return "Transcribing..."
    case .polishing:
      return "Polishing..."
    case .transcribingMaxDurationReached:
      return "60-minute limit reached. Transcribing..."
    }
  }

  /// Toolbar status-badge form: one Unicode ellipsis (preserves today's bytes).
  static func statusBadgeCopy(for phase: ProcessingPhase) -> String {
    switch phase {
    case .transcribing, .transcribingMaxDurationReached:
      return "Transcribing\u{2026}"
    case .polishing:
      return "Polishing\u{2026}"
    }
  }

  /// Tight sidebar status chip: no ellipsis (max-duration collapses to the
  /// plain word — Channel B never emits the max-duration case anyway).
  static func shortCopy(for phase: ProcessingPhase) -> String {
    switch phase {
    case .transcribing, .transcribingMaxDurationReached:
      return "Transcribing"
    case .polishing:
      return "Polishing"
    }
  }

  /// #1891 (epic #1876 Phase 2b) — THE SEVENTH SENTENCE, founder-approved
  /// verbatim 2026-07-31. Do not reword without a founder decision: #1558
  /// locked the six, and this adds exactly one.
  ///
  /// It is a PLAIN SENTENCE, not `[Category] error. Try again.`, and that is
  /// the whole point. Under the design rule at the top of this file the error
  /// form means "our bug, just retry" — which is false here and, worse,
  /// sends the user to do the one thing that cannot help. Capture worked. It
  /// recorded exactly what the microphone sent, which was nothing usable.
  ///
  /// Both reasons share one sentence deliberately: the user cannot act on the
  /// difference between a digitally silent channel and a signal floor below
  /// every dead-air threshold, and the founder's model gives capture endings
  /// exactly two customer buckets rather than one per cause.
  ///
  /// The three causes are offered with "may" because we genuinely cannot tell
  /// them apart from the samples, and the app never claims a mute it cannot
  /// substantiate (#1876 product decision 1).
  static func copy(for reason: TerminalAdvisoryReason) -> String {
    switch reason {
    case .zeroSignal, .vadGateNoSpeech, .noTransport:
      return
        "Audio isn't capturing. Your lid may be closed, your headset muted, or there may be a hardware issue. Please check your microphone settings."
    }
  }

  // MARK: - Post-completion + advisory warnings (E3, #1567)

  /// Founder-LOCKED 2026-07-15. Unchanged from today EXCEPT two approved
  /// cleanups: model-not-downloaded drops a banned em-dash and polish-failed
  /// drops a literal `--` — each becomes a clean two-sentence form.
  static func copy(for reason: RecordingWarningReason) -> String {
    switch reason {
    case .modelNotDownloaded(let engineLabel):
      return "\(engineLabel) isn't downloaded yet. Open Settings to download it."
    case .polishFailed:
      return "Polish failed. Using raw text."
    case .historySaveFailed(let reason):
      return "Couldn't save to history: \(reason)"
    case .salvagedBeginning:
      return "Beginning of dictation was unclear and was skipped"
    case .interruptedTail(let disclosure, let alsoTrimmedLead):
      switch (disclosure, alsoTrimmedLead) {
      case (.deviceRemoved, true):
        return "Microphone disconnected. Words may be missing."
      case (.deviceRemoved, false):
        return "Microphone disconnected. Text may be cut short."
      case (.otherInterruption, true):
        return "Recording interrupted. Words may be missing."
      case (.otherInterruption, false):
        return "Recording interrupted. Text may be cut short."
      }
    }
  }

  // MARK: - In-panel recording notices (E3, #1567)

  /// Founder-LOCKED unchanged (2026-07-15). Authored here even though these
  /// render through `flashRecordingNotice` (a live-panel banner), not the
  /// `.warning` pill — one voice, two render paths.
  static func copy(for reason: RecordingNoticeReason) -> String {
    switch reason {
    case .approachingCap:
      return "Recording auto-stops in under a minute (60-minute cap)"
    case .autoStopUnavailable:
      return "Auto-stop on silence is unavailable right now"
    }
  }

  // MARK: - Spoken announcements (E4, #1569) — the app's VoiceOver voice.

  /// The single authority for every VoiceOver announcement the recording overlay
  /// posts. The panel keeps choosing the AX priority + target element; the words
  /// live here. Words byte-identical to today (founder-locked 2026-07-15).
  static func announcement(for intent: OverlayIntent) -> String {
    switch intent {
    case .hidden: return "Recording complete"
    case .recording(audioLevel: _): return "Recording started"
    case .processing(phase: _): return "Processing transcription"
    case .clipboardFallback: return "Text copied to clipboard"
    case .accessibilityToast: return "Accessibility permission needed for auto-paste"
    case .warning(let reason): return "Warning: \(copy(for: reason))"
    case .error(let reason): return "Error: \(copy(for: reason))"
    // #1891: NO "Error: " prefix. A screen-reader user would otherwise hear
    // the exact opposite of what the sentence says. This arm is the reason the
    // advisory is a separate intent rather than a suppression flag on `.error`.
    case .advisory(let reason): return copy(for: reason)
    case .interruption(let reason): return "Interruption: \(copy(for: reason))"
    case .passiveChip(let payload): return "Detected \(payload.displayName)"
    case .cachingModel(engineLabel: _): return "Getting dictation ready, one moment"
    case .engineReady: return "Dictation ready. Press to start."
    case .recoveringLastRecording: return "Recovering your last recording. Press Discard to skip."
    case .recoverySucceeded: return recoverySucceededText
    case .bluetoothAwareness:
      return "Bluetooth microphone detected. Wait a moment before speaking on a cold start."
    }
  }

  // MARK: - Fixed status-pill + window/badge/sidebar copy (E4, #1569). Byte-identical.

  static let coldStartTitle = "Getting dictation ready…"
  static func coldStartSubtitle(engineLabel: String) -> String {
    "\(engineLabel) is warming up after a restart"
  }
  static let readyTitle = "Ready — press to dictate"  // dash kept (founder 2026-07-15)
  static let clipboardFallbackText = "Copied. Press \u{2318}V to paste"
  static let accessibilityToastText = "Auto-paste needs Accessibility"
  static let recoveryTitle = "Recovering your last recording…"
  /// #1897 — CONDITIONAL, and it must stay that way. This read "Saved to History
  /// when it's done", which asserts an outcome the app cannot know yet, and a
  /// recovery that ends without text says nothing at all — so the pill had
  /// already promised something that never arrived.
  ///
  /// Founder decision 2026-08-12, given the choice between adding a failure
  /// notice and removing the promise: *"stop promising, just close the loop
  /// quietly."* The defect was only ever the promise. `OverlayIntent` therefore
  /// keeps exactly its two recovery cases and gains NO failure case, which is
  /// what this issue's body originally proposed and what that decision
  /// explicitly declines.
  ///
  /// **An announcement would be wrong because the cause is UNKNOWN, not because
  /// it is known-benign.** The single authority on what an empty recovery result
  /// does and does not establish is the `recoveryEmptyText` doc comment in
  /// `SentryBreadcrumb` — read it there rather than trusting any restatement,
  /// including this one. Its consequence for copy: a recogniser miss on real
  /// speech and a person who chose not to speak are indistinguishable here, so
  /// any sentence naming a reason asserts one of two possibilities we cannot
  /// tell apart.
  ///
  /// **Four review rounds on this one string each killed a different unsupported
  /// claim in this comment** — a promised delivery, a promise conditioned on the
  /// wrong link, an invented cause, and a statistic quoted with the wrong
  /// denominator. Every one was a fact restated here that is owned somewhere
  /// else. Hence the rule this block now follows: state the DECISION and point at
  /// the owner; do not reproduce its numbers or its reasoning. If you find
  /// yourself adding a figure here, put it where the contract lives instead.
  ///
  /// The quiet close needs no code: this pill is a transient notice with a 6s
  /// auto-dismiss (`RecordingOverlayPanel`), so a recovery that yields nothing
  /// already ends by the pill simply going away.
  ///
  /// **MORE THAN ONE link can defeat delivery, and a fix that closes only one
  /// is the same defect again.** This shipped as "Anything found goes to History" and
  /// cloud review killed it: conditioning on *found* still asserts the save.
  /// `RecoverySpoolReplayer` can produce text and then have
  /// `transcriptStore.save` throw (disk full, History unwritable), returning
  /// `.failed(.save)`; `RecoveryCoordinator` posts its notice only for
  /// `.recovered`, so that path shows nothing and the pill has again promised an
  /// outcome that never happened. Condition on the LAST link instead: only a
  /// transcript that actually saved reaches History, and that holds by
  /// construction because `transcriptCoordinator.append` is non-throwing and runs
  /// immediately after a successful `save`.
  static let recoverySubtitle = "Anything saved lands in History"
  /// The recovery pill's CONTAINER accessibility label (no ellipsis — distinct
  /// bytes from `recoveryTitle`). VoiceOver reads it as the group's spoken status.
  static let recoveryAccessibilityLabel = "Recovering your last recording"
  /// #1464 — the recovery SUCCESS notice (green `.recoverySucceeded` pill).
  /// Title + subtitle for the visual pill; `recoverySucceededText` is the single
  /// spoken VoiceOver sentence. No em-dash (Rule 6). Founder-approved 2026-07-16.
  static let recoverySucceededTitle = "Recovered your last recording"
  static let recoverySucceededSubtitle = "Saved to History"
  static let recoverySucceededText = "Recovered your last recording. Saved to History."
  static let loadingModelStatus = "Loading model..."  // main-window body (ASCII ellipsis)
  static let loadingModelBadge = "Loading model\u{2026}"  // toolbar badge (Unicode ellipsis)
  static let loadingModelSidebar = "Loading Model"  // sidebar row (title-case, no ellipsis)
  /// Shared by the toolbar badge and the sidebar row — one word, one authority.
  static let recordingStatus = "Recording"
  static let errorStatus = "Error"  // sidebar row + main-window `.error` heading (single word)
}
