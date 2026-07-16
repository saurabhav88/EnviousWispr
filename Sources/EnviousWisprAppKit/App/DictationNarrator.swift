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
    case .interruption(let reason): return "Interruption: \(copy(for: reason))"
    case .passiveChip(let payload): return "Detected \(payload.displayName)"
    case .cachingModel(engineLabel: _): return "Getting dictation ready, one moment"
    case .engineReady: return "Dictation ready. Press to start."
    case .recoveringLastRecording: return "Recovering your last recording. Press Discard to skip."
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
  static let recoverySubtitle = "Saved to History when it's done"
  /// The recovery pill's CONTAINER accessibility label (no ellipsis — distinct
  /// bytes from `recoveryTitle`). VoiceOver reads it as the group's spoken status.
  static let recoveryAccessibilityLabel = "Recovering your last recording"
  static let loadingModelStatus = "Loading model..."  // main-window body (ASCII ellipsis)
  static let loadingModelBadge = "Loading model\u{2026}"  // toolbar badge (Unicode ellipsis)
  static let loadingModelSidebar = "Loading Model"  // sidebar row (title-case, no ellipsis)
  /// Shared by the toolbar badge and the sidebar row — one word, one authority.
  static let recordingStatus = "Recording"
  static let errorStatus = "Error"  // sidebar row + main-window `.error` heading (single word)
}
