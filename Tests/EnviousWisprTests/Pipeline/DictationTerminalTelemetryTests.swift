import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #1884 chunk 2. The two events, their contracts, and the invariants that make
/// the frozen-snapshot design real rather than aspirational.
@MainActor
@Suite("Dictation terminal telemetry (#1884)")
struct DictationTerminalTelemetryTests {

  /// Captures what `emitTerminal` hands the vendor boundary.
  private final class Recorder {
    var terminals: [(takeID: String, backend: String, result: String, reason: String?)] = []
    var attributions: [(kind: String?, peak: Float?, transport: String?)] = []
    var starts: [(takeID: String, backend: String)] = []
  }

  private func makeSink(_ recorder: Recorder) -> KernelLifecycleTelemetrySink {
    KernelLifecycleTelemetrySink(
      backend: .parakeet,
      audioCapture: FakeAudioCapture(),
      context: KernelSessionContext(),
      captureTelemetry: CaptureTelemetryState(),
      telemetryState: KernelTelemetryState(),
      dictationStarted: { takeID, backend in
        recorder.starts.append((takeID, backend))
      },
      dictationTerminal: {
        takeID, backend, result, reason, kind, effectiveTransport, _, _, _, _, peak, _, _, _ in
        recorder.terminals.append((takeID, backend, result, reason))
        recorder.attributions.append((kind, peak, effectiveTransport))
      }
    )
  }

  private func snapshot(
    _ outcome: RecordingOutcome,
    attribution: KernelSignalAttributionTelemetry? = nil
  ) -> KernelTerminalTelemetrySnapshot {
    KernelTerminalTelemetrySnapshot(
      takeID: "TAKE-A", backend: "parakeet", outcome: outcome, signalAttribution: attribution)
  }

  // MARK: - The seven terminals

  @Test("every terminal emits exactly one row with its expected label")
  func everyTerminalEmitsItsLabel() {
    let cases: [(RecordingOutcome, String)] = [
      (.completed, "completed"),
      (.failed(.asrFailed), "failed"),
      (.cancelled, "cancelled"),
      (.discarded(.tooShort), "discarded"),
      (.noSpeech(.vadGate), "no_speech"),
      (.audioInterrupted(.deviceRemoved), "audio_interrupted"),
      (.asrInterrupted(wasRecording: true), "asr_interrupted"),
    ]
    for (outcome, expected) in cases {
      let recorder = Recorder()
      makeSink(recorder).emitTerminal(snapshot(outcome))
      #expect(recorder.terminals.count == 1, "\(outcome) must emit exactly one row")
      #expect(recorder.terminals.first?.result == expected)
    }
  }

  /// Every outcome, with the reason each one owes. `result` and `reason` are both
  /// read from the SAME projection, so a `failed` row without a reason is a
  /// contradiction rather than a gap — which is what `.noTransport` shipped as
  /// until the whole-diff review caught it: it projects to
  /// `.failed(.noAudioCaptured)`, so an outcome-side match labelled it `failed`
  /// and then found no reason to attach, hiding it from every reason-keyed count.
  @Test("a failed row always carries a reason, and only failed rows do")
  func failedAlwaysCarriesItsReason() {
    let cases: [(RecordingOutcome, String, String?)] = [
      (.completed, "completed", nil),
      (.failed(.asrFailed), "failed", "asr_failed"),
      (.cancelled, "cancelled", nil),
      (.discarded(.tooShort), "discarded", nil),
      (.noSpeech(.vadGate), "no_speech", nil),
      (.audioInterrupted(.deviceRemoved), "audio_interrupted", nil),
      (.asrInterrupted(wasRecording: true), "asr_interrupted", nil),
      (.noTransport, "failed", "no_audio_captured"),
    ]
    for (outcome, expectedResult, expectedReason) in cases {
      let recorder = Recorder()
      makeSink(recorder).emitTerminal(snapshot(outcome))
      #expect(recorder.terminals.first?.result == expectedResult, "\(outcome) result")
      #expect(recorder.terminals.first?.reason == expectedReason, "\(outcome) reason")
      #expect(
        (recorder.terminals.first?.result == "failed")
          == (recorder.terminals.first?.reason != nil),
        "\(outcome): a failed row without a reason is unqueryable")
    }
  }

  /// `reason` exists only on `failed`. A reason on `cancelled` would invite a
  /// query that reads user intent as a fault.
  @Test("reason is present only for failed terminals")
  func reasonOnlyOnFailure() {
    let recorder = Recorder()
    let sink = makeSink(recorder)
    sink.emitTerminal(snapshot(.failed(.zeroSignal)))
    sink.emitTerminal(snapshot(.cancelled))
    sink.emitTerminal(snapshot(.noSpeech(.vadGate)))
    #expect(recorder.terminals[0].reason == "zero_signal")
    #expect(recorder.terminals[1].reason == nil)
    #expect(recorder.terminals[2].reason == nil)
  }

  /// The two reasons #1890 counts, in the exact spelling its queries use.
  @Test("the two signal-free reasons emit their #1890 spellings")
  func signalFreeReasonSpellings() {
    let recorder = Recorder()
    let sink = makeSink(recorder)
    sink.emitTerminal(snapshot(.failed(.zeroSignal)))
    sink.emitTerminal(snapshot(.failed(.asrEmpty)))
    #expect(recorder.terminals.map(\.reason) == ["zero_signal", "asr_empty_with_speech"])
  }

  // MARK: - Attribution, and the zero that must never be manufactured

  @Test("attribution rides along when present")
  func attributionIsCarried() {
    let recorder = Recorder()
    makeSink(recorder).emitTerminal(
      snapshot(
        .failed(.zeroSignal),
        attribution: KernelSignalAttributionTelemetry(
          inputDeviceKind: "built_in_mic", effectiveTransport: "builtin",
          selectedTransport: nil, inputSelectionMode: "auto",
          wholeBufferRMS: 0.0001, maxWindowRMS: 0.0002, peakAudioLevel: 0.0007,
          durationMs: 3200, captureNativeRateHz: 48000, captureNativeChannelCount: 1)))
    #expect(recorder.attributions.first?.kind == "built_in_mic")
    #expect(recorder.attributions.first?.peak == 0.0007)
    #expect(recorder.attributions.first?.transport == "builtin")
  }

  /// A take that is not signal-free carries no attribution at all — absent, not
  /// zeroed. This is the two-way control for the invariant below.
  @Test("a healthy terminal carries no attribution fields")
  func healthyTerminalHasNoAttribution() {
    let recorder = Recorder()
    makeSink(recorder).emitTerminal(snapshot(.completed))
    #expect(recorder.attributions.first?.kind == nil)
    #expect(recorder.attributions.first?.peak == nil)
  }

  /// The invariant #1809 bought with real pain: a MISSING peak must stay
  /// missing, because an exact zero is the signature of a digitally dead
  /// channel. Both directions asserted — absent stays absent, and a genuine 0.0
  /// still travels, because that reading IS the finding.
  @Test("a missing peak omits; a measured exact zero is preserved")
  func peakNeverManufacturesAZero() {
    let missing = Recorder()
    makeSink(missing).emitTerminal(
      snapshot(
        .failed(.zeroSignal),
        attribution: KernelSignalAttributionTelemetry(
          inputDeviceKind: nil, effectiveTransport: nil, selectedTransport: nil,
          inputSelectionMode: nil, wholeBufferRMS: nil, maxWindowRMS: nil,
          peakAudioLevel: nil, durationMs: nil, captureNativeRateHz: nil,
          captureNativeChannelCount: nil)))
    #expect(missing.attributions.first?.peak == nil, "a missing reading must never become 0")

    let measuredZero = Recorder()
    makeSink(measuredZero).emitTerminal(
      snapshot(
        .failed(.zeroSignal),
        attribution: KernelSignalAttributionTelemetry(
          inputDeviceKind: nil, effectiveTransport: nil, selectedTransport: nil,
          inputSelectionMode: nil, wholeBufferRMS: nil, maxWindowRMS: nil,
          peakAudioLevel: 0.0, durationMs: nil, captureNativeRateHz: nil,
          captureNativeChannelCount: nil)))
    #expect(
      measuredZero.attributions.first?.peak == 0.0,
      "a MEASURED zero is the diagnostic finding and must survive")
  }

  // MARK: - The identity race this design exists to remove

  /// Take B may already be running by the time take A's row is rendered. The
  /// snapshot must therefore be sufficient on its own: rendering reads it and
  /// nothing else, so nothing take B does can change what take A reported.
  @Test("a snapshot renders identically regardless of later state")
  func snapshotIsSelfSufficient() {
    let recorder = Recorder()
    let sink = makeSink(recorder)
    let takeA = snapshot(.failed(.zeroSignal))
    // Emit twice with an unrelated terminal in between, standing in for take B
    // having moved the world on.
    sink.emitTerminal(takeA)
    sink.emitTerminal(snapshot(.completed))
    sink.emitTerminal(takeA)
    #expect(recorder.terminals[0].takeID == "TAKE-A")
    #expect(recorder.terminals[0].result == "failed")
    #expect(
      recorder.terminals[2].takeID == recorder.terminals[0].takeID,
      "the same snapshot must render the same row, whatever happened in between")
    #expect(recorder.terminals[2].result == recorder.terminals[0].result)
  }

  // MARK: - The denominator

  @Test("acceptance emits exactly one started row carrying the same identity")
  func acceptanceEmitsTheDenominator() {
    let recorder = Recorder()
    makeSink(recorder).acceptSession(takeID: "TAKE-A")
    #expect(recorder.starts.count == 1)
    #expect(recorder.starts.first?.takeID == "TAKE-A")
    #expect(recorder.starts.first?.backend == "parakeet")
  }
}
