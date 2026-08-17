import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// The activation branch (#2087, chunk 12) — the single point where everything
/// chunks 1-11 built stops being inert.
///
/// Two conditions gate it, and both are asserted in BOTH directions here,
/// because a gate is only a gate if it also refuses. The one that matters most
/// is the OFF path: this feature is opt-in and off by default, so the promise
/// carrying nearly all its users is that nothing about cancel changed for them.
@MainActor
@Suite("Escape Recovery activation (#2087)", .tags(.productOutcome))
struct EscapeRecoveryActivationTests {

  #if DEBUG

    private struct Harness {
      let wrapper: KernelRecordingSession
      let capture: FakeAudioCapture
      let vad: FakeVADSignalSource
    }

    private func session(
      escapeRecoveryEnabled: Bool,
      origin: RecordingCancelOrigin,
      recoverySessionID: String? = nil,
      markerWrites: Bool = true
    ) -> Harness {
      let clock = FakeClock()
      let capture = FakeAudioCapture()
      let vad = FakeVADSignalSource()
      let wrapper = KernelRecordingSession(
        engine: FakeEngine(behavior: .batchSuccess(text: "kept text"), clock: clock),
        capture: capture,
        vad: vad,
        clock: clock,
        paste: FakePasteTarget(),
        prepareEscapeRecovery: { _, _, _ in markerWrites })
      wrapper.sessionConfigForTesting = .testDefault(
        escapeRecoveryEnabled: escapeRecoveryEnabled,
        recoverySessionID: recoverySessionID)
      wrapper.cancelOriginForTesting = origin
      return Harness(wrapper: wrapper, capture: capture, vad: vad)
    }

    /// Drive to a cancel with real captured audio behind it, so a take that is
    /// KEPT has something to transcribe and a take that is discarded had
    /// something to lose. Cancelling an empty capture would reach the same
    /// terminal by a different road and prove nothing about this branch.
    private func cancelAfterSpeech(_ h: Harness) async {
      await h.wrapper.apply(.start)
      await h.wrapper.drainReadyWork()
      h.capture.deliverBuffer(frameCount: 48000, amplitude: 0.25)
      h.vad.evidence = .voiced
      h.vad.segments = [SpeechSegment(startSample: 0, endSample: 48000)]
      await h.wrapper.drainReadyWork()
      await h.wrapper.apply(.cancel)
      await h.wrapper.drainUntilConcluded()
    }

    // MARK: The off path — the promise that covers nearly every user

    @Test("setting OFF: the shortcut still discards, and nothing is transcribed or stored")
    func offPathIsUnchanged() async {
      let h = session(escapeRecoveryEnabled: false, origin: .user(.shortcut))

      await cancelAfterSpeech(h)

      // `.cancelled`, which is the whole point: the take reached the SAME
      // terminal it reached before this feature existed.
      #expect(h.wrapper.state == .cancelled)
      #expect(
        h.wrapper.testKernel.finalizationDisposition == .ordinary,
        "the disposition must never leave .ordinary with the setting off")
      #expect(
        h.wrapper.storedTexts.isEmpty,
        "nothing reached storage — not permanent History, and not the pending shelf")
      #expect(h.wrapper.effects.pasteCount == 0, "and nothing was delivered")
      #expect(
        h.wrapper.effects.transcript == nil,
        "the take was discarded before a transcript existed, exactly as before")
    }

    // MARK: The button is not the shortcut

    @Test("setting ON but the Cancel BUTTON: still destructive")
    func cancelButtonNeverRecovers() async {
      let h = session(escapeRecoveryEnabled: true, origin: .user(.cancelButton))

      await cancelAfterSpeech(h)

      #expect(
        h.wrapper.testKernel.finalizationDisposition == .ordinary,
        "a deliberate click on a button labelled Cancel is unambiguous intent to destroy")
      #expect(h.wrapper.storedTexts.isEmpty, "so nothing is kept")
    }

    @Test("setting ON but a system cancel: still destructive")
    func systemCancelNeverRecovers() async {
      let h = session(escapeRecoveryEnabled: true, origin: .systemOrFault)

      await cancelAfterSpeech(h)

      #expect(
        h.wrapper.testKernel.finalizationDisposition == .ordinary,
        "the user did not ask for this cancel, so there is no intent to honour")
    }

    // MARK: The on path

    @Test("setting ON and the shortcut: the take is kept and transcribed")
    func shortcutWithSettingOnKeepsTheTake() async {
      let h = session(escapeRecoveryEnabled: true, origin: .user(.shortcut))

      await cancelAfterSpeech(h)

      #expect(
        h.wrapper.testKernel.finalizationDisposition.isEscapeRecovery,
        "the branch fired")
      #expect(
        h.wrapper.storedTexts == ["kept text"],
        "and the ordinary pipeline ran: the take was transcribed and reached storage")
    }

    // MARK: The marker, and the fifth defect the design review caught

    @Test("no crash-recovery session: recovery proceeds, because there is nothing to mark")
    func missingRecoverySessionIDIsNotAFailure() async {
      // `markerWrites: false` is deliberate and is the whole point: with no
      // recovery id the writer must never be CONSULTED, so even a writer that
      // always fails cannot block the feature.
      let h = session(
        escapeRecoveryEnabled: true, origin: .user(.shortcut),
        recoverySessionID: nil, markerWrites: false)

      await cancelAfterSpeech(h)

      #expect(
        h.wrapper.testKernel.finalizationDisposition.isEscapeRecovery,
        """
        crash recovery being off is not a marker failure. Treating it as one \
        would silently disable this feature for everyone who turned crash \
        recovery off, with no message and nothing in telemetry to explain it.
        """)
    }

    @Test("marker write fails for a real spool: fails closed to the ordinary destructive cancel")
    func markerFailureFailsClosed() async {
      let h = session(
        escapeRecoveryEnabled: true, origin: .user(.shortcut),
        recoverySessionID: "spool-abc", markerWrites: false)

      await cancelAfterSpeech(h)

      #expect(
        h.wrapper.testKernel.finalizationDisposition == .ordinary,
        "a spool we cannot mark would be replayed into permanent History at launch")
      #expect(
        h.wrapper.storedTexts.isEmpty,
        "so the take is discarded — costing the user exactly what cancel always costs them")
    }

    @Test("marker write succeeds for a real spool: recovery proceeds")
    func markerSuccessProceeds() async {
      let h = session(
        escapeRecoveryEnabled: true, origin: .user(.shortcut),
        recoverySessionID: "spool-abc", markerWrites: true)

      await cancelAfterSpeech(h)

      #expect(
        h.wrapper.testKernel.finalizationDisposition.isEscapeRecovery,
        "control: the failure case above is about the WRITE failing, not about having a spool")
    }
  #endif
}
