import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// #1558 (E1) / #1564 (E2). Freezes the copy contract: `DictationNarrator` is
/// the SOLE author of the founder-locked sentences and processing labels, no
/// reason leaks raw internal detail, and every processing phase keeps its exact
/// byte form across the three render surfaces.
@Suite struct DictationNarratorTests {

  // MARK: - Terminal notices (E1)

  @Test("every reason maps to its exact founder-locked sentence")
  func everyReasonMapsToLockedCopy() {
    let expected: [TerminalNoticeReason: String] = [
      // Audio capture error bucket (our-fault start / capture).
      .prepareFailed: "Audio capture error. Try again.",
      .modelWedged: "Audio capture error. Try again.",
      .modelLoadFailed: "Audio capture error. Try again.",
      .captureStartFailed: "Audio capture error. Try again.",
      .micWouldNotOpen: "Audio capture error. Try again.",
      .captureStalled: "Audio capture error. Try again.",
      .zeroSignal: "Audio capture error. Try again.",
      // Transcription error bucket (our-fault transcribe).
      .asrFailed: "Transcription error. Try again.",
      .asrWedged: "Transcription error. Try again.",
      .asrInterrupted: "Transcription error. Try again.",
      .noAudioCaptured: "Transcription error. Try again.",
      .asrEmptyWithSpeech: "Transcription error. Try again.",
      .emptyAfterProcessing: "Transcription error. Try again.",
      .unknown: "Transcription error. Try again.",
      // User-actionable.
      .permissionDenied: "Microphone access is off.",
      .noMicrophoneFound: "No microphone found. Please connect one.",
      // Informational interruptions.
      .deviceRemoved: "Microphone disconnected.",
      .engineLost: "Recording interrupted.",
      .unknownInterruption: "Recording interrupted.",
    ]
    // The map must cover EVERY case — a new reason with no expected entry fails
    // here rather than silently defaulting.
    for reason in TerminalNoticeReason.allCases {
      guard let want = expected[reason] else {
        Issue.record("no expected copy for \(reason) — add it to the locked set")
        continue
      }
      #expect(DictationNarrator.copy(for: reason) == want)
    }
  }

  @Test("no sentence carries raw internal detail (the retired leak prefixes)")
  func noRawDetailLeak() {
    let bannedPrefixes = [
      "Model load failed:", "Recording failed:", "Transcription failed:",
      "Speech engine isn't responding",  // old ModelLoadWatchdog.userMessage
    ]
    for reason in TerminalNoticeReason.allCases {
      let copy = DictationNarrator.copy(for: reason)
      for banned in bannedPrefixes {
        #expect(!copy.contains(banned), "\(reason) copy must not contain '\(banned)'")
      }
    }
  }

  @Test("the terminal sentences use no em/en dashes (in-app copy rule)")
  func noDashesInTerminalCopy() {
    for reason in TerminalNoticeReason.allCases {
      let copy = DictationNarrator.copy(for: reason)
      #expect(!copy.contains("\u{2014}") && !copy.contains("\u{2013}"), "\(reason) copy has a dash")
    }
  }

  // MARK: - Processing phases (E2, #1564)

  /// The active-pill / main-window form uses three ASCII periods and the
  /// 60-minute cap prefix. Byte-exact — these must match today's literals.
  @Test("processing pill copy is byte-exact ASCII")
  func processingPillCopyByteExact() {
    #expect(DictationNarrator.copy(for: .transcribing) == "Transcribing...")
    #expect(DictationNarrator.copy(for: .polishing) == "Polishing...")
    #expect(
      DictationNarrator.copy(for: .transcribingMaxDurationReached)
        == "60-minute limit reached. Transcribing...")
    // Guard the ASCII vs Unicode distinction explicitly: the pill must NOT carry
    // the single Unicode ellipsis the badge uses.
    #expect(!DictationNarrator.copy(for: .transcribing).contains("\u{2026}"))
  }

  /// The toolbar status-badge form uses ONE Unicode ellipsis (`\u{2026}`),
  /// preserving today's `StatusBadge` bytes — NOT the ASCII pill form.
  @Test("processing status-badge copy keeps the Unicode ellipsis")
  func processingBadgeCopyKeepsUnicodeEllipsis() {
    #expect(DictationNarrator.statusBadgeCopy(for: .transcribing) == "Transcribing\u{2026}")
    #expect(DictationNarrator.statusBadgeCopy(for: .polishing) == "Polishing\u{2026}")
    // The max-duration case collapses to the plain transcribing badge (Channel B
    // never emits it, but the switch must be total and byte-stable).
    #expect(
      DictationNarrator.statusBadgeCopy(for: .transcribingMaxDurationReached)
        == "Transcribing\u{2026}")
    // Must NOT be the ASCII three-period form.
    #expect(!DictationNarrator.statusBadgeCopy(for: .transcribing).contains("..."))
  }

  /// The tight sidebar chip form uses no ellipsis at all.
  @Test("processing short copy has no ellipsis")
  func processingShortCopyHasNoEllipsis() {
    #expect(DictationNarrator.shortCopy(for: .transcribing) == "Transcribing")
    #expect(DictationNarrator.shortCopy(for: .polishing) == "Polishing")
    #expect(DictationNarrator.shortCopy(for: .transcribingMaxDurationReached) == "Transcribing")
    for phase in ProcessingPhase.allCases {
      let short = DictationNarrator.shortCopy(for: phase)
      #expect(
        !short.contains("...") && !short.contains("\u{2026}"), "\(phase) short copy has an ellipsis"
      )
    }
  }

  @Test("processing copy uses no em/en dashes (in-app copy rule)")
  func noDashesInProcessingCopy() {
    for phase in ProcessingPhase.allCases {
      for copy in [
        DictationNarrator.copy(for: phase),
        DictationNarrator.statusBadgeCopy(for: phase),
        DictationNarrator.shortCopy(for: phase),
      ] {
        #expect(
          !copy.contains("\u{2014}") && !copy.contains("\u{2013}"), "\(phase) copy has a dash")
      }
    }
  }

  // MARK: - Post-completion + advisory warnings (E3, #1567)

  /// Every `RecordingWarningReason` maps to its founder-locked sentence. The
  /// four interrupted-tail cells and the two interpolated reasons are pinned
  /// byte-exact; the two cleanups (model-not-downloaded, polish-failed) are the
  /// only strings that changed from today.
  @Test("warning reasons map to their exact founder-locked sentences")
  func warningReasonsMapToLockedCopy() {
    #expect(
      DictationNarrator.copy(for: .modelNotDownloaded(engineLabel: "Parakeet"))
        == "Parakeet isn't downloaded yet. Open Settings to download it.")
    #expect(DictationNarrator.copy(for: .polishFailed) == "Polish failed. Using raw text.")
    #expect(
      DictationNarrator.copy(for: .historySaveFailed(reason: "disk is full"))
        == "Couldn't save to history: disk is full")
    #expect(
      DictationNarrator.copy(for: .salvagedBeginning)
        == "Beginning of dictation was unclear and was skipped")
    #expect(
      DictationNarrator.copy(
        for: .interruptedTail(disclosure: .deviceRemoved, alsoTrimmedLead: false))
        == "Microphone disconnected. Text may be cut short.")
    #expect(
      DictationNarrator.copy(
        for: .interruptedTail(disclosure: .deviceRemoved, alsoTrimmedLead: true))
        == "Microphone disconnected. Words may be missing.")
    #expect(
      DictationNarrator.copy(
        for: .interruptedTail(disclosure: .otherInterruption, alsoTrimmedLead: false))
        == "Recording interrupted. Text may be cut short.")
    #expect(
      DictationNarrator.copy(
        for: .interruptedTail(disclosure: .otherInterruption, alsoTrimmedLead: true))
        == "Recording interrupted. Words may be missing.")
  }

  /// Only a VERIFIED device removal may name the microphone. If this fails, a
  /// user whose engine died with the mic still attached is being lied to.
  @Test("the neutral interruption family never mentions the microphone")
  func neutralInterruptionNeverClaimsTheMicrophone() {
    for alsoTrimmedLead in [false, true] {
      let copy = DictationNarrator.copy(
        for: .interruptedTail(disclosure: .otherInterruption, alsoTrimmedLead: alsoTrimmedLead))
      #expect(!copy.localizedCaseInsensitiveContains("microphone"))
      #expect(!copy.localizedCaseInsensitiveContains("mic"))
    }
  }

  /// The two founder cleanups: no banned em/en dash, no literal `--`, and the
  /// second clause capitalizes (a true two-sentence form).
  @Test("the cleaned-up warning sentences drop the dash and double-hyphen")
  func cleanedWarningSentencesAreClean() {
    let cleaned = [
      DictationNarrator.copy(for: .modelNotDownloaded(engineLabel: "EG-1")),
      DictationNarrator.copy(for: .polishFailed),
    ]
    for copy in cleaned {
      #expect(!copy.contains("\u{2014}") && !copy.contains("\u{2013}"), "\(copy) has a dash")
      #expect(!copy.contains(" -- "), "\(copy) has a literal double-hyphen")
    }
    #expect(DictationNarrator.copy(for: .polishFailed).contains(". Using"))
  }

  // MARK: - In-panel recording notices (E3, #1567)

  @Test("recording notices map to their exact founder-locked sentences")
  func recordingNoticesMapToLockedCopy() {
    #expect(
      DictationNarrator.copy(for: RecordingNoticeReason.approachingCap)
        == "Recording auto-stops in under a minute (60-minute cap)")
    #expect(
      DictationNarrator.copy(for: RecordingNoticeReason.autoStopUnavailable)
        == "Auto-stop on silence is unavailable right now")
  }

  // MARK: - Spoken announcements + fixed status copy (E4, #1569)

  /// Every `OverlayIntent` case maps to its exact spoken announcement — the words
  /// VoiceOver reads, byte-identical to the panel's retired inline literals. The
  /// three message-bearing cases compose the narrator's own reason copy.
  @Test("every overlay intent maps to its exact spoken announcement")
  func announcementsAreByteExact() {
    let chip = LanguageChipPayload(
      lang: "es", displayName: "Spanish", state: .askToLock, generation: 0)
    let cases: [(OverlayIntent, String)] = [
      (.hidden, "Recording complete"),
      (.recording(audioLevel: 0.5), "Recording started"),
      (.processing(phase: .transcribing), "Processing transcription"),
      (.clipboardFallback, "Text copied to clipboard"),
      (.accessibilityToast, "Accessibility permission needed for auto-paste"),
      (.warning(reason: .polishFailed), "Warning: Polish failed. Using raw text."),
      (.error(reason: .prepareFailed), "Error: Audio capture error. Try again."),
      (.interruption(reason: .deviceRemoved), "Interruption: Microphone disconnected."),
      (.passiveChip(payload: chip), "Detected Spanish"),
      (.cachingModel(engineLabel: "Parakeet"), "Getting dictation ready, one moment"),
      (.engineReady, "Dictation ready. Press to start."),
      (
        .recoveringLastRecording,
        "Recovering your last recording. Press Discard to skip."
      ),
      (
        .bluetoothAwareness,
        "Bluetooth microphone detected. Wait a moment before speaking on a cold start."
      ),
    ]
    for (intent, want) in cases {
      #expect(DictationNarrator.announcement(for: intent) == want)
    }
  }

  /// The fixed status-pill / window / badge / sidebar copy is byte-identical to
  /// today's retired renderer literals (founder-locked 2026-07-15).
  @Test("fixed status copy accessors are byte-exact")
  func fixedStatusCopyByteExact() {
    #expect(DictationNarrator.coldStartTitle == "Getting dictation ready…")
    #expect(
      DictationNarrator.coldStartSubtitle(engineLabel: "Parakeet")
        == "Parakeet is warming up after a restart")
    #expect(DictationNarrator.readyTitle == "Ready — press to dictate")
    #expect(DictationNarrator.clipboardFallbackText == "Copied. Press \u{2318}V to paste")
    #expect(DictationNarrator.accessibilityToastText == "Auto-paste needs Accessibility")
    #expect(DictationNarrator.recoveryTitle == "Recovering your last recording…")
    #expect(DictationNarrator.recoverySubtitle == "Saved to History when it's done")
    #expect(DictationNarrator.recoveryAccessibilityLabel == "Recovering your last recording")
    #expect(DictationNarrator.loadingModelStatus == "Loading model...")
    #expect(DictationNarrator.loadingModelBadge == "Loading model\u{2026}")
    #expect(DictationNarrator.loadingModelSidebar == "Loading Model")
    #expect(DictationNarrator.recordingStatus == "Recording")
    #expect(DictationNarrator.errorStatus == "Error")
  }

  /// The byte-distinct render forms must stay distinct: the main-window body uses
  /// ASCII `...`, the toolbar badge uses the single Unicode ellipsis, and the
  /// recovery container AX label drops the ellipsis the visible title carries.
  @Test("the distinct render forms keep their exact byte differences")
  func distinctRenderFormsStayDistinct() {
    #expect(DictationNarrator.loadingModelStatus != DictationNarrator.loadingModelBadge)
    #expect(DictationNarrator.loadingModelStatus.contains("..."))
    #expect(DictationNarrator.loadingModelBadge.contains("\u{2026}"))
    #expect(!DictationNarrator.loadingModelBadge.contains("..."))
    // The sidebar form is title-case, distinct from the body form.
    #expect(DictationNarrator.loadingModelSidebar != DictationNarrator.loadingModelStatus)
    // The recovery AX label has no ellipsis; the visible title does.
    #expect(DictationNarrator.recoveryAccessibilityLabel != DictationNarrator.recoveryTitle)
    #expect(!DictationNarrator.recoveryAccessibilityLabel.contains("…"))
  }
}
