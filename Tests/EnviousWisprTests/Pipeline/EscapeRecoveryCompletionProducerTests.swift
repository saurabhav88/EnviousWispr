import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline

/// The PRODUCTION writer of the Escape Recovery completion (#2087, chunk 12).
///
/// This suite exists because a mutation battery over the activation code found
/// that nothing did. `EscapeRecoveryCompletionTransportTests` covers the slot's
/// ownership rules thoroughly — take-once, cleared on a new session — but every
/// one of its cases fills the slot through `putEscapeRecoveryCompletionForTesting`,
/// the DEBUG seam. So the seam's behaviour was pinned and
/// `captureEscapeRecoveryCompletionIfNeeded`, the thing that decides what a real
/// user is offered, could be deleted or inverted with the whole suite still green.
///
/// That is the defect this feature kept reproducing at every layer: a consumer
/// verified against the thing beside it rather than against the producer. These
/// tests drive the real capture and read the real slot.
@MainActor
@Suite("Escape Recovery completion producer (#2087)", .tags(.productOutcome))
struct EscapeRecoveryCompletionProducerTests {

  #if DEBUG

    private struct Harness {
      let driver: KernelDictationDriver
      let kernel: RecordingSessionKernel
      let outcome: KernelFinalizationOutcome
    }

    private func makeDriver() -> Harness {
      let clock = FakeClock()
      let adapter = FakeEngine(behavior: .batchSuccess(text: "x"), clock: clock)
      let kernel = RecordingSessionKernel(
        adapter: adapter,
        audioCapture: FakeAudioCapture(),
        vad: FakeVADSignalSource(),
        currentTick: { 0 },
        sleepTicks: { _ in },
        processText: { raw, _ in raw },
        store: { _, _, _ in },
        deliver: { _, _ in .pasted },
        engineMutationScope: .alwaysAllowedForTesting,
        minimumRecordingTicks: 0)
      let observer = KernelHeartPathTelemetryObserver(
        kernel: kernel, audioCapture: FakeAudioCapture(),
        emitter: HeartPathTelemetryEmitter(
          backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
        emitLifecycleEvent: { _ in })
      let steps = LimbSteps(
        wordCorrection: WordCorrectionStep(),
        fillerRemoval: FillerRemovalStep(),
        emojiFormatter: EmojiFormatterStep(),
        inverseTextNormalization: InverseTextNormalizationStep(),
        llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
        emojiRestore: EmojiRestoreStep())
      let outcome = KernelFinalizationOutcome()
      let driver = KernelDictationDriver(
        kernel: kernel, observer: observer, outcome: outcome,
        context: KernelSessionContext(), steps: steps, adapter: adapter,
        engineMutationScope: .alwaysAllowedForTesting)
      driver.start()
      return Harness(driver: driver, kernel: kernel, outcome: outcome)
    }

    private func row() -> Transcript {
      Transcript(
        text: "kept text", processingTime: 1, backendType: .parakeet,
        escapeRecoveredAt: Date(), escapeRecoveryTakeID: "take-1")
    }

    /// Stage a finished recovery and let the driver's own state observation run.
    ///
    /// `historySaved` is set explicitly on every path rather than defaulted,
    /// because whether the row is DURABLE is the thing two of these cases turn
    /// on, and a fixture that leaves it implicit would decide them by accident.
    private func concludeRecovery(
      _ h: Harness, outcome: RecordingOutcome, transcript: Transcript?, historySaved: Bool
    ) async {
      h.kernel.testSetFinalizationDisposition(.escapeRecovery(triggeredAt: Date()))
      h.outcome.transcript = transcript
      h.outcome.historySaved = historySaved
      h.kernel.testForceConclude(outcome)
      for _ in 0..<200 { await Task.yield() }
    }

    // MARK: The happy path, which is also the control for every case below

    @Test("a completed recovery with a durable row offers that row")
    func durableRowIsOffered() async {
      let h = makeDriver()
      let saved = row()

      await concludeRecovery(h, outcome: .completed, transcript: saved, historySaved: true)

      let completion = h.driver.takeEscapeRecoveryCompletion()
      #expect(completion?.outcome == .saved)
      #expect(
        completion?.payload?.transcriptID == saved.id,
        "the pill has to point at the row that was written, not at some other one")
    }

    // MARK: The two conditions `.saved` carries, each asserted alone

    /// A save that threw still leaves a transcript in hand.
    ///
    /// This is the sharp one, and it is invisible from the call site: the
    /// pipeline finished, so `recordingOutcome` is `.completed` and
    /// `outcome.transcript` is populated, and only `historySaved` distinguishes
    /// a row on disk from a row that was built and then failed to be written.
    /// Announcing `.saved` here raises a pill offering to paste from a file that
    /// does not exist, and appends a row that vanishes on relaunch.
    @Test("a completed recovery whose write FAILED offers nothing, and says why")
    func failedWriteOffersNothing() async {
      let h = makeDriver()

      await concludeRecovery(h, outcome: .completed, transcript: row(), historySaved: false)

      let completion = h.driver.takeEscapeRecoveryCompletion()
      #expect(
        completion?.outcome == .saveFailed,
        "a completed take with no durable row is precisely the save-failed case")
      #expect(
        completion?.payload == nil,
        "no payload means no pill, structurally — nothing can offer text that was never written")
    }

    @Test("a recovery that never completed offers nothing")
    func uncompletedOffersNothing() async {
      let h = makeDriver()

      // A transcript in hand and a successful save flag, with a terminal that is
      // NOT `.completed`. Both other conditions are satisfied, so this isolates
      // the terminal check: without it, an abandoned take would raise a pill for
      // the very text the user asked to be rid of.
      await concludeRecovery(h, outcome: .cancelled, transcript: row(), historySaved: true)

      let completion = h.driver.takeEscapeRecoveryCompletion()
      #expect(completion?.outcome == .abandoned)
      #expect(completion?.payload == nil)
    }

    // MARK: The dedupe, driven through the real producer

    /// The transport suite pins this for the SEAM. The seam is written once by
    /// construction, so it can never demonstrate the guard that matters: the
    /// state observation re-runs on every transition, and the real capture is
    /// invoked each time.
    @Test("the real capture writes one completion however many transitions fire")
    func realCaptureIsDedupedWithinASession() async {
      let h = makeDriver()

      await concludeRecovery(h, outcome: .completed, transcript: row(), historySaved: true)
      // Take it, the way the pill's consumer does, then keep the notifications
      // coming. A second write would refill the slot behind the consumer and
      // offer the same dictation twice.
      _ = h.driver.takeEscapeRecoveryCompletion()

      h.kernel.testForceState(.arming)
      for _ in 0..<100 { await Task.yield() }
      h.kernel.testForceState(.live)
      for _ in 0..<100 { await Task.yield() }

      #expect(
        h.driver.escapeRecoveryCompletionIsEmptyForTesting,
        "an offer repeated is a dictation the user already answered being asked again")
    }

    // MARK: The failure the user is told about

    /// The notice has to arrive WITH the terminal, not before it.
    ///
    /// An earlier draft pushed it — `overlay.show(...)` called straight from the
    /// cancel arm, one line above `finishTerminal(.cancelled)`. The terminal's
    /// own state observation then planned `.showOverlay(.hidden)` and
    /// `.cancelPendingWarning`, so the sentence was erased about a frame after it
    /// appeared. Ordering was no defence, because that observation runs in a
    /// `Task` and wins from either side of the call.
    ///
    /// So this reads the SAME property the planner reads. Asserting the kernel's
    /// latch instead would pass against a driver that projected nothing, which
    /// is exactly the state this test was written to end.
    @Test("a recovery that could not be kept says so, through the terminal itself")
    func unavailableNoticeRidesTheTerminal() async {
      let h = makeDriver()
      h.kernel.testSetEscapeRecoveryUnavailable(true)
      h.kernel.testForceConclude(.cancelled)
      for _ in 0..<200 { await Task.yield() }

      #expect(
        h.driver.overlayIntent == .warning(reason: .escapeRecoveryUnavailable),
        """
        the user switched this on and it did not happen; silence lets them \
        believe it did, and the recording is already gone by then
        """)
    }

    @Test("an ordinary cancel still says nothing")
    func ordinaryCancelStaysSilent() async {
      let h = makeDriver()
      h.kernel.testForceConclude(.cancelled)
      for _ in 0..<200 { await Task.yield() }

      #expect(
        h.driver.overlayIntent == .hidden,
        "control: only the failed recovery speaks, or every cancel would nag")
    }

    // MARK: The off path

    @Test("an ordinary dictation produces no completion at all")
    func ordinaryDictationProducesNothing() async {
      let h = makeDriver()
      h.outcome.transcript = row()
      h.outcome.historySaved = true
      // Disposition deliberately left `.ordinary` — the control that keeps every
      // case above honest. Without it they would all pass against a producer
      // that wrote a completion for every dictation anyone ever finished.
      h.kernel.testForceConclude(.completed)
      for _ in 0..<200 { await Task.yield() }

      #expect(
        h.driver.escapeRecoveryCompletionIsEmptyForTesting,
        "nothing about a normal dictation should reach this slot")
    }
  #endif
}
