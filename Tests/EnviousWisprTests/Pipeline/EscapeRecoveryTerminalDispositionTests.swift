import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// The kernel FILLS the terminal row's delivery disposition (#2087, chunk 11).
///
/// A separate suite because the failure it guards is one layer up from where it
/// shows: `DictationTerminalTelemetryTests` proves the sink forwards whatever
/// the snapshot carries, and `EscapeRecoveryEventPayloadTests` proves the event
/// renders it — but a mutation hardcoding `.ordinary` at the kernel's
/// construction site survived both, because neither exercises the step that
/// decides the value.
///
/// The chain is kernel → snapshot → sink → event, and a test of any two
/// adjacent links says nothing about the third.
@MainActor
/// Class: `.productOutcome` — storage and delivery disagree about what the take was.
@Suite("Escape Recovery terminal disposition (#2087)", .tags(.productOutcome))
struct EscapeRecoveryTerminalDispositionTests {

  #if DEBUG

    private final class SnapshotLog {
      var dispositions: [DeliveryDisposition] = []
    }

    private func run(disposition: FinalizationDisposition?) async -> SnapshotLog {
      let log = SnapshotLog()
      let clock = FakeClock()
      let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
      let capture = FakeAudioCapture()
      let vad = FakeVADSignalSource()
      let wrapper = KernelRecordingSession(
        engine: engine, capture: capture, vad: vad,
        clock: clock, paste: FakePasteTarget(),
        onTerminalSnapshot: { [log] snapshot in
          log.dispositions.append(snapshot.deliveryDisposition)
        })

      await wrapper.apply(.start)
      await wrapper.drainReadyWork()
      capture.deliverBuffer(frameCount: 48000, amplitude: 0.25)
      vad.evidence = .voiced
      vad.segments = [SpeechSegment(startSample: 0, endSample: 48000)]
      await wrapper.drainReadyWork()
      if let disposition {
        wrapper.testKernel.testSetFinalizationDisposition(disposition)
      }
      await wrapper.apply(.stop)
      await wrapper.drainUntilConcluded()
      return log
    }

    @Test("an ordinary dictation reports the value every existing row already has")
    func ordinarySessionReportsOrdinary() async {
      let log = await run(disposition: nil)
      #expect(log.dispositions == [.ordinary])
    }

    @Test("a held recovery is distinguishable on its terminal row")
    func escapeRecoverySessionReportsEscapeRecovery() async {
      let log = await run(disposition: .escapeRecovery(triggeredAt: Date()))
      #expect(
        log.dispositions == [.escapeRecovery],
        "without this the row reports withheld text as a delivered dictation")
    }

    /// An abandoned recovery is still a recovery. Reporting it as ordinary
    /// would hide exactly the population the funnel measures — the users who
    /// tried the feature and discarded the result.
    @Test("an abandoned recovery still reports as a recovery")
    func abandonedRecoveryReportsEscapeRecovery() async {
      let log = await run(disposition: .abandonedEscapeRecovery(triggeredAt: Date()))
      #expect(log.dispositions == [.escapeRecovery])
    }

  #endif
}
