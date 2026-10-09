import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Other-key interference ends a take destructively and says so on its terminal row (#3544 P4, D2).
///
/// Drives the real kernel: the reason is filled at the kernel's snapshot construction from the
/// first-wins cancel-origin latch, so a test of the sink alone could not catch a construction site
/// that omits it.
@MainActor
/// Class: `.productOutcome` — a dismissed take that was kept, pasted or reported as an ordinary
/// cancel.
@Suite("Other-key dismissal terminal (#3544 P4)", .tags(.productOutcome))
struct OtherKeyDismissalTerminalTests {

  #if DEBUG

    private final class SnapshotLog {
      var reasons: [TerminalCancelReason?] = []
      var dispositions: [DeliveryDisposition] = []
    }

    private func cancelAfterSpeech(
      origin: RecordingCancelOrigin, escapeRecoveryEnabled: Bool
    ) async -> (KernelRecordingSession, SnapshotLog) {
      let log = SnapshotLog()
      let clock = FakeClock()
      let capture = FakeAudioCapture()
      let vad = FakeVADSignalSource()
      let wrapper = KernelRecordingSession(
        engine: FakeEngine(behavior: .batchSuccess(text: "kept text"), clock: clock),
        capture: capture, vad: vad, clock: clock, paste: FakePasteTarget(),
        prepareEscapeRecovery: { _, _, _ in true },
        onTerminalSnapshot: { [log] snapshot in
          log.reasons.append(snapshot.cancelReason)
          log.dispositions.append(snapshot.deliveryDisposition)
        })
      wrapper.sessionConfigForTesting = .testDefault(
        escapeRecoveryEnabled: escapeRecoveryEnabled, recoverySessionID: "spool")
      wrapper.cancelOriginForTesting = origin
      await wrapper.apply(.start)
      await wrapper.drainReadyWork()
      capture.deliverBuffer(frameCount: 48000, amplitude: 0.25)
      vad.evidence = .voiced
      vad.segments = [SpeechSegment(startSample: 0, endSample: 48000)]
      await wrapper.drainReadyWork()
      await wrapper.apply(.cancel)
      await wrapper.drainUntilConcluded()
      return (wrapper, log)
    }

    @Test(
      "interference discards the take with its reason, Escape Recovery on or off",
      arguments: [false, true])
    func interferenceIsDestructiveAndReported(escapeRecoveryEnabled: Bool) async {
      let (wrapper, log) = await cancelAfterSpeech(
        origin: .user(.otherKeyInterference), escapeRecoveryEnabled: escapeRecoveryEnabled)
      #expect(wrapper.state == .cancelled)
      #expect(wrapper.testKernel.finalizationDisposition == .ordinary, "a dismissed take was held")
      #expect(wrapper.storedTexts.isEmpty, "a dismissed take reached History or the shelf")
      #expect(wrapper.effects.pasteCount == 0, "a dismissed take was pasted")
      #expect(log.reasons == [.otherKeyDismissed])
      #expect(log.dispositions == [.ordinary])
    }

    @Test("the user's own cancel controls keep reason nil")
    func ordinaryCancelsCarryNoReason() async {
      for origin in [RecordingCancelOrigin.user(.shortcut), .user(.cancelButton), .systemOrFault] {
        let (_, log) = await cancelAfterSpeech(origin: origin, escapeRecoveryEnabled: false)
        #expect(log.reasons == [nil], "\(origin) gained a cancel reason")
      }
    }

  #endif

  @Test("only a cancelled outcome from interference carries the reason")
  func reasonProjection() {
    #expect(
      RecordingSessionKernel.cancelReason(outcome: .cancelled, origin: .user(.otherKeyInterference))
        == .otherKeyDismissed)
    #expect(
      RecordingSessionKernel.cancelReason(outcome: .cancelled, origin: .user(.shortcut)) == nil)
    #expect(
      RecordingSessionKernel.cancelReason(outcome: .completed, origin: .user(.otherKeyInterference))
        == nil)
    #expect(TerminalCancelReason.otherKeyDismissed.rawValue == "other_key_dismissed")
  }
}
