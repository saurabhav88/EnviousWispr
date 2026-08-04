import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// #1891 (epic #1876 Phase 2b). Freezes the seventh sentence and the routing
/// that reaches it.
///
/// Every test here has a NEGATIVE arm. A classifier that returned an advisory
/// for everything, or a projection that fired on every no-speech source, would
/// pass the positive assertions alone while silencing correct behaviour
/// elsewhere — the exact shape `verify-the-feature-not-the-crash` warns about.
@Suite struct TerminalAdvisoryTests {

  // MARK: - The classifier: one authority, both projections

  @Test("only zeroSignal and vadGate no-speech are advisories")
  func classifierTruthTable() {
    // POSITIVE — the two endings the founder decision covers.
    #expect(
      KernelDictationDriver.advisoryReason(for: .failed(.zeroSignal)) == .zeroSignal)
    #expect(
      KernelDictationDriver.advisoryReason(for: .noSpeech(.vadGate)) == .vadGateNoSpeech)

    // NEGATIVE — a working microphone and a user who said nothing. These stay
    // SILENT by founder ruling: they already know they did not speak.
    #expect(KernelDictationDriver.advisoryReason(for: .noSpeech(.asrEmptyNoSpeech)) == nil)
    // #1920: audio WAS arriving above every dead-air floor and the engine ran
    // clean, so there is nothing to tell the user to check. The two advisories
    // above stay the only ones, and they are the genuinely-absent-audio cases.
    #expect(KernelDictationDriver.advisoryReason(for: .asrEmptyDespiteAudio) == nil)
    #expect(KernelDictationDriver.advisoryReason(for: .noSpeech(.emptyAfterProcessing)) == nil)

    // NEGATIVE — genuinely our software. These keep "Audio capture error.
    // Try again." `.captureStalled` is here deliberately: the mid-take death
    // stays our-fault until #1578 telemetry explains it.
    for reason: RecordingFailureReason in [
      .prepareFailed, .permissionDenied, .modelWedged, .modelLoadFailed,
      .captureStartFailed, .noMicrophoneFound, .noAudioCaptured, .asrEmpty,
      .asrFailed, .asrWedged, .emptyAfterProcessing, .captureStalled,
    ] {
      #expect(
        KernelDictationDriver.advisoryReason(for: .failed(reason)) == nil,
        "\(reason) must not become an advisory")
    }

    // NEGATIVE — non-failure terminals.
    #expect(KernelDictationDriver.advisoryReason(for: .completed) == nil)
    #expect(KernelDictationDriver.advisoryReason(for: .cancelled) == nil)
    #expect(KernelDictationDriver.advisoryReason(for: .discarded(.tooShort)) == nil)
    #expect(KernelDictationDriver.advisoryReason(for: .discarded(.releasedBeforeRecording)) == nil)
    #expect(KernelDictationDriver.advisoryReason(for: .noTransport) == nil)
  }

  // MARK: - The copy

  @Test("the seventh sentence is byte-exact and shared by both reasons")
  func seventhSentenceIsFrozen() {
    let expected =
      "Audio isn't capturing. Your lid may be closed, your headset muted, or there may be a hardware issue. Please check your microphone settings."
    for reason in TerminalAdvisoryReason.allCases {
      #expect(DictationNarrator.copy(for: reason) == expected)
    }
  }

  @Test("the advisory is a plain sentence, never the our-fault retry form")
  func advisoryNeverClaimsOurBug() {
    // The house rule (#1558): "[Category] error. Try again." means OUR bug.
    // This sentence must never adopt that form — saying it would both blame
    // ourselves falsely and send the user to do the one thing that cannot work.
    for reason in TerminalAdvisoryReason.allCases {
      let copy = DictationNarrator.copy(for: reason)
      #expect(!copy.contains("Try again."))
      #expect(!copy.contains("error."))
      // Rule 6: no em-dashes or en-dashes in user-facing copy.
      #expect(!copy.contains("\u{2014}"))
      #expect(!copy.contains("\u{2013}"))
    }
  }

  // MARK: - VoiceOver

  @Test("VoiceOver announces the advisory with no Error prefix")
  func advisoryHasNoErrorPrefix() {
    let spoken = DictationNarrator.announcement(for: .advisory(reason: .vadGateNoSpeech))
    #expect(spoken == DictationNarrator.copy(for: .vadGateNoSpeech))
    #expect(!spoken.hasPrefix("Error:"))

    // TWO-WAY CONTROL: a real error must STILL be prefixed. Without this arm a
    // change that dropped the prefix everywhere would pass the assertion above.
    let errorSpoken = DictationNarrator.announcement(for: .error(reason: .asrFailed))
    #expect(errorSpoken.hasPrefix("Error:"))
  }

  // MARK: - The state contract

  @Test("advisory is inactive and keeps the error telemetry phase label")
  func advisoryStateContract() {
    for reason in TerminalAdvisoryReason.allCases {
      let state = PipelineState.advisory(reason)
      // Recording controls must stay enabled — an advisory is a resting
      // terminal, not work in progress.
      #expect(state.isActive == false)
      // DELIBERATELY "error": this feeds `app_phase` on
      // `telemetry.flush_requested`, and a new value would change that series'
      // vocabulary at a version boundary (#1813's trap).
      #expect(state.telemetryLabel == "error")
      #expect(state.activity == .advisory(reason))
    }
  }

  // MARK: - The dead mapping, documented rather than left as a trap

  @Test("no producer routes zeroSignal to the old error sentence any more")
  func zeroSignalNoLongerNarratesAsCaptureError() {
    // `TerminalNoticeReason.zeroSignal` still exists and its rawValue is still
    // the LIVE PostHog `zero_signal` code — that series must not break. But
    // after #1891 no code path produces `.error(.zeroSignal)`: the outcome now
    // classifies as an advisory first, and every `setTerminalReason` caller
    // passes permissionDenied / noMicrophoneFound / micWouldNotOpen /
    // modelWedged / asrInterrupted or an interruption cause.
    //
    // So this asserts the ROUTING, not the dead table entry.
    #expect(
      KernelDictationDriver.advisoryReason(for: .failed(.zeroSignal)) == .zeroSignal)
    #expect(TerminalNoticeReason.zeroSignal.rawValue == "zero_signal")
  }
}
