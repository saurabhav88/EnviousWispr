import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// #1884 chunk 1. The two shared projections a concluded take is classified by.
///
/// These are the vocabulary authority for `dictation.terminal`. A wrong value
/// here is not a crash, it is a silently mislabelled dictation that looks
/// exactly like a correctly labelled one in every dashboard — so the mapping is
/// asserted exhaustively rather than sampled.
@Suite("Kernel terminal projections (#1884)")
struct KernelTerminalProjectionsTests {

  // MARK: - RecordingFailureReason → TerminalNoticeReason

  /// Exact and exhaustive: all 13 reasons, named individually.
  ///
  /// Deliberately NOT a loop over `CaseIterable` comparing to itself — that
  /// would assert the mapping equals the mapping. Each expected raw value is
  /// written out so a wrong-but-plausible edit has to be typed by hand.
  @Test("every failure reason maps to its shipped snake_case code")
  func reasonMappingIsExhaustiveAndExact() {
    let expected: [(RecordingFailureReason, String)] = [
      (.prepareFailed, "prepare_failed"),
      (.permissionDenied, "permission_denied"),
      (.modelWedged, "model_wedged"),
      (.modelLoadFailed, "model_load_failed"),
      (.captureStartFailed, "capture_start_failed"),
      (.noMicrophoneFound, "no_microphone_found"),
      (.noAudioCaptured, "no_audio_captured"),
      (.asrEmpty, "asr_empty_with_speech"),
      (.asrFailed, "asr_failed"),
      (.asrWedged, "asr_wedged"),
      (.emptyAfterProcessing, "empty_after_processing"),
      (.captureStalled, "capture_stalled"),
      (.zeroSignal, "zero_signal"),
    ]

    #expect(expected.count == 13, "13 RecordingFailureReason cases exist; update this table")

    for (reason, code) in expected {
      #expect(
        reason.terminalNoticeReason.rawValue == code,
        "\(reason) must emit \(code)")
    }
  }

  /// The one non-identity mapping, called out because it is the name #1890
  /// counts and an "obvious" correction to `asr_empty` would silently break
  /// that issue's queries.
  @Test("asrEmpty maps to asr_empty_with_speech, not asr_empty")
  func asrEmptyKeepsItsMoreSpecificName() {
    #expect(RecordingFailureReason.asrEmpty.terminalNoticeReason == .asrEmptyWithSpeech)
    #expect(
      RecordingFailureReason.asrEmpty.terminalNoticeReason.rawValue == "asr_empty_with_speech")
  }

  /// Cheap diagnostic, NOT the vocabulary authority — a wrong snake_case value
  /// passes this. The exhaustive table above is what actually pins the codes.
  @Test("no emitted reason code contains an uppercase letter")
  func reasonCodesAreSnakeCase() {
    for reason in TerminalNoticeReason.allCases {
      #expect(
        reason.rawValue == reason.rawValue.lowercased(),
        "\(reason.rawValue) is not snake_case — raw Swift case names must never be emitted")
    }
  }

  // MARK: - RecordingOutcome → KernelLifecycleEvent

  @Test("every outcome projects to its terminal lifecycle event")
  func outcomeProjectionCoversEveryEnding() {
    #expect(RecordingOutcome.completed.lifecycleEvent == .pipelineCompleted)
    #expect(RecordingOutcome.cancelled.lifecycleEvent == .cancelled)
    #expect(RecordingOutcome.failed(.asrFailed).lifecycleEvent == .failed(.asrFailed))
    #expect(RecordingOutcome.noSpeech(.vadGate).lifecycleEvent == .noSpeech(.vadGate))
    #expect(RecordingOutcome.discarded(.tooShort).lifecycleEvent == .discarded(.tooShort))
    #expect(
      RecordingOutcome.asrInterrupted(wasRecording: true).lifecycleEvent
        == .asrInterrupted(wasRecording: true))
  }

  /// LOCKED projection. `.noTransport` reuses an existing telemetry identity
  /// rather than minting a new one, so a transport-less take is counted with the
  /// captured-nothing family. Changing this splits a population across two names
  /// with no migration.
  @Test("noTransport projects to the existing noAudioCaptured identity")
  func noTransportKeepsItsLockedProjection() {
    #expect(RecordingOutcome.noTransport.lifecycleEvent == .failed(.noAudioCaptured))
  }

  /// An interrupted take with no stamped cause is still an unowned loss (#1174
  /// A3), so it defaults to `.engineLost` rather than being dropped.
  @Test("audioInterrupted with no cause defaults to engineLost")
  func interruptedWithoutCauseStillCounts() {
    #expect(
      RecordingOutcome.audioInterrupted(nil).lifecycleEvent
        == .audioInterrupted(cause: .engineLost))
    #expect(
      RecordingOutcome.audioInterrupted(.deviceRemoved).lifecycleEvent
        == .audioInterrupted(cause: .deviceRemoved))
  }

  /// Every projected event must be a TERMINAL one. A projection landing on a
  /// non-terminal would emit `result: nil` and produce an unqueryable row.
  /// `@MainActor` because `KernelLifecycleTelemetrySink` is main-actor isolated;
  /// the projections themselves are pure and need no isolation.
  @MainActor
  @Test("every projected event is a terminal, never a mid-flight event")
  func everyProjectionIsTerminal() {
    let endings: [RecordingOutcome] = [
      .completed, .cancelled, .noTransport,
      .failed(.zeroSignal), .noSpeech(.vadGate), .discarded(.tooShort),
      .audioInterrupted(nil), .asrInterrupted(wasRecording: false),
    ]
    for outcome in endings {
      #expect(
        KernelLifecycleTelemetrySink.terminalStateLabel(for: outcome.lifecycleEvent) != nil,
        "\(outcome) projected to a non-terminal event")
    }
  }
}
