import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// The kernel FILLS the terminal row's VAD conditioning record (#2184).
///
/// A separate suite for the same reason `EscapeRecoveryTerminalDispositionTests`
/// is one: `DictationTerminalTelemetryTests` proves the sink forwards whatever
/// the snapshot carries, and neither of those exercises the step that DECIDES
/// the value. The chain is conditioner → telemetry state → snapshot → sink →
/// event, and a test of any two adjacent links says nothing about the third.
///
/// **What the user sees when this fails:** nothing, which is the problem. A
/// dictation in a noisy room comes back short and confident, the user assumes
/// they misspoke, and no row anywhere records that the audio was trimmed. Six
/// such takes went through production before this issue and not one was
/// countable.
@MainActor
@Suite("VAD conditioning terminal telemetry (#2184)", .tags(.observabilityContract))
struct VADConditioningTerminalTelemetryTests {

  #if DEBUG

    private final class SnapshotLog {
      var conditionings: [KernelVADConditioningTelemetry?] = []
    }

    /// Drives the real kernel to a terminal and returns what the snapshot
    /// carried. `voicedSamples == nil` means deliver no audio at all, so the
    /// take concludes before the conditioner ever runs.
    private func run(
      behavior: FakeEngineBehavior = .batchSuccess(text: "hello"),
      capturedSamples: Int? = 48_000,
      voicedSamples: Int? = nil
    ) async -> SnapshotLog {
      let log = SnapshotLog()
      let clock = FakeClock()
      let engine = FakeEngine(behavior: behavior, clock: clock)
      let capture = FakeAudioCapture()
      let vad = FakeVADSignalSource()
      let wrapper = KernelRecordingSession(
        engine: engine, capture: capture, vad: vad,
        clock: clock, paste: FakePasteTarget(),
        onTerminalSnapshot: { [log] snapshot in
          log.conditionings.append(snapshot.vadConditioning)
        })

      await wrapper.apply(.start)
      await wrapper.drainReadyWork()
      if let capturedSamples {
        capture.deliverBuffer(frameCount: capturedSamples, amplitude: 0.25)
        vad.evidence = .voiced
        vad.segments = [
          SpeechSegment(startSample: 0, endSample: voicedSamples ?? capturedSamples)
        ]
        await wrapper.drainReadyWork()
      }
      await wrapper.apply(.stop)
      await wrapper.drainUntilConcluded()
      return log
    }

    @Test("an ordinary completed dictation reports what the VAD kept")
    func completedTakeCarriesTheRecord() async {
      let log = await run()

      let record: KernelVADConditioningTelemetry? = log.conditionings.first ?? nil
      #expect(record?.rawSampleCount == 48_000)
      #expect(
        (record?.retainedRatio ?? 0) > 0.9,
        "a take whose speech spans the whole buffer should report a ratio near 1; got \(String(describing: record))"
      )
      #expect(record?.conditioningReason == "filtered")
    }

    /// The measurement that makes the failure countable. The VAD marks a quarter
    /// of the buffer as speech, and the row has to say so — this is the shape
    /// the aeroplane takes had, where the ratio sat between 0.07 and 0.43 and
    /// nothing anywhere recorded it.
    @Test("a heavily trimmed take reports a low retained ratio")
    func trimmedTakeReportsItsRatio() async {
      let log = await run(capturedSamples: 48_000, voicedSamples: 12_000)

      let record: KernelVADConditioningTelemetry? = log.conditionings.first ?? nil
      let ratio = record?.retainedRatio ?? 1.0
      #expect(
        ratio < 0.5,
        "the VAD kept a quarter of the buffer and the row reported \(ratio) — a trim this size is the whole subject of #2184 and has to be visible"
      )
      #expect((record?.filteredSampleCount ?? 0) < 48_000)
    }

    /// The case that decides where this record lives. A take whose decode comes
    /// back empty never reaches the completion payload, so a signal hung off
    /// that payload would omit exactly the failures it was added to reveal.
    @Test("an empty decode still reports its conditioning")
    func asrEmptyTakeStillCarriesTheRecord() async {
      let log = await run(behavior: .empty(hadSpeechEvidence: true))

      let record: KernelVADConditioningTelemetry? = log.conditionings.first ?? nil
      #expect(
        record != nil,
        "the decode returned nothing and so did the telemetry — this is the population the record exists for"
      )
      #expect(record?.rawSampleCount == 48_000)
    }

    /// The absence is data. A take that ended before the conditioner ran has no
    /// conditioning to report, and a manufactured ratio would put a fabricated
    /// 1.0 in the denominator of every query over this dimension.
    @Test("a take that ends before conditioning reports nothing")
    func takeEndingBeforeConditioningReportsNothing() async {
      let log = await run(capturedSamples: nil)

      #expect(
        (log.conditionings.first ?? nil) as KernelVADConditioningTelemetry? == nil,
        "a take with no audio reported a conditioning record, so some path is inventing one"
      )
    }

  #endif
}
