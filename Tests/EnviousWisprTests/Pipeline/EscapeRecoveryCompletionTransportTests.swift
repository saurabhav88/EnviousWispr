import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline

/// The one-shot handoff that carries a concluded Escape Recovery from the
/// kernel side of the terminal cleanup to the AppKit side of `onStateChange`
/// (#2087, chunk 6).
///
/// Everything here is about a container refusing to give the same answer twice.
/// The feature it protects is small and the failure it prevents is not: a user
/// who cancelled once being offered their text back two or three times, once per
/// state notification the session happens to produce.
///
/// The production writer lands in chunk 7 with the exit arm that decides a take
/// is recoverable. The driver-level tests below drive the slot through a DEBUG
/// seam instead, because a guard whose only writer does not exist yet is a guard
/// that cannot be shown to work. The slot's own contract needs no seam and is
/// therefore checked in both build configurations.
@MainActor
/// Class: `.productOutcome` — the offer appears twice, or a stale one surfaces against a later dictation.
@Suite("Escape Recovery completion transport (#2087)", .tags(.productOutcome))
struct EscapeRecoveryCompletionTransportTests {

  // MARK: The slot itself

  @Test("take returns the completion once and nothing afterwards")
  func takeIsDestructive() {
    let slot = EscapeRecoveryCompletionSlot()
    let id = UUID()
    slot.put(
      .saved(CancelUndoPayload(transcriptID: id, targetApp: nil, targetElement: nil)))

    #expect(slot.take()?.payload?.transcriptID == id)
    #expect(
      slot.take() == nil, "a second take must find nothing — this is the duplicate-pill guard")
  }

  /// `clear` and `take` differ in intent, not only in return type: this one runs
  /// when nobody is going to be shown the completion at all. The preceding test
  /// is its control — the same `put` followed by `take` yields the completion,
  /// so a nil here is the clear working rather than the put failing.
  @Test("clear empties the slot without anyone consuming it")
  func clearEmptiesWithoutConsuming() {
    let slot = EscapeRecoveryCompletionSlot()
    slot.put(.nothingToRestore(.abandoned))

    slot.clear()
    #expect(slot.take() == nil)
  }

  /// The pairing used to be an `assert`, which compiles out of Release. It is
  /// now structural: `.saved` cannot be written without a payload and nothing
  /// else can carry one, so this checks the remaining risk — that the two closed
  /// sets drift apart and an ending stops being reportable.
  ///
  /// A SET equality, not a count. A count comparison passes whenever two
  /// mistakes cancel, and this file's job is to notice exactly that.
  @Test("the no-payload endings and saved together cover every reportable outcome")
  func closedSetsAgree() {
    let fromCompletion =
      Set(EscapeRecoveryCompletion.NothingToRestore.allCases.map(\.rawValue))
      .union([EscapeRecoveryTerminalOutcome.saved.rawValue])
    #expect(fromCompletion == Set(EscapeRecoveryTerminalOutcome.allCases.map(\.rawValue)))

    for reason in EscapeRecoveryCompletion.NothingToRestore.allCases {
      let completion = EscapeRecoveryCompletion.nothingToRestore(reason)
      #expect(completion.payload == nil, "\(reason.rawValue) must not be able to offer a pill")
      #expect(
        completion.outcome.rawValue == reason.rawValue,
        "the flat outcome must not rename the ending on its way to telemetry")
    }
    #expect(
      EscapeRecoveryCompletion.saved(
        CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
      ).outcome == .saved)
  }

  // MARK: The driver's ownership of it

  #if DEBUG
    @Test("the driver hands the completion to exactly one caller")
    func driverTakeIsDestructive() {
      let h = makeDriver()
      let id = UUID()
      h.driver.putEscapeRecoveryCompletionForTesting(
        .saved(CancelUndoPayload(transcriptID: id, targetApp: nil, targetElement: nil)))

      #expect(h.driver.takeEscapeRecoveryCompletion()?.payload?.transcriptID == id)
      #expect(h.driver.takeEscapeRecoveryCompletion() == nil)
    }

    /// The failure this whole design exists to prevent, driven the way it would
    /// actually happen: `onStateChange` fires more than once for one session,
    /// and the consumer asks for the completion each time.
    @Test("a second state notification in the same session presents no second pill")
    func secondStateNotificationPresentsNothing() async {
      let h = makeDriver()
      var pillsPresented: [UUID] = []
      h.driver.onStateChange = { [driver = h.driver] _ in
        guard let completion = driver.takeEscapeRecoveryCompletion() else { return }
        guard let payload = completion.payload else { return }
        pillsPresented.append(payload.transcriptID)
      }

      h.driver.putEscapeRecoveryCompletionForTesting(
        .saved(samplePayload()))

      // Two mapped-state changes, one session. Both reach `onStateChange`.
      h.kernel.testForceState(.arming)
      await drainUntil { pillsPresented.count == 1 }
      h.kernel.testForceState(.live)
      for _ in 0..<50 { await Task.yield() }

      #expect(
        pillsPresented.count == 1,
        "the pill is an offer, and an offer repeated is a dictation the user never cancelled")
    }

    /// The negative half of the session guard. Without it the "cleared on a new
    /// session" test below would pass against a driver that cleared on every
    /// notification — which would drop every completion before its consumer ran,
    /// and no test in this file would notice.
    @Test("a state change within the same session leaves the completion alone")
    func sameSessionDoesNotClear() async {
      let h = makeDriver()
      h.driver.putEscapeRecoveryCompletionForTesting(
        .saved(samplePayload()))

      h.kernel.testForceState(.arming)
      for _ in 0..<50 { await Task.yield() }

      #expect(
        h.driver.escapeRecoveryCompletionIsEmptyForTesting == false,
        "the completion belongs to the session still in progress")
    }

    @Test("a completion nobody took does not survive into the next session")
    func newSessionClearsAnUnconsumedCompletion() async {
      let h = makeDriver()
      // Conclude first, because that is when a real completion is frozen — and
      // because `reset()` refuses to run while a session is still in flight.
      h.kernel.testForceConclude(.cancelled)
      for _ in 0..<50 { await Task.yield() }

      h.driver.putEscapeRecoveryCompletionForTesting(
        .saved(samplePayload()))
      #expect(h.driver.escapeRecoveryCompletionIsEmptyForTesting == false)

      // `reset()` mints a fresh `SessionID` — the boundary the guard keys off.
      h.kernel.reset()
      await drainUntil { h.driver.escapeRecoveryCompletionIsEmptyForTesting }

      #expect(
        h.driver.escapeRecoveryCompletionIsEmptyForTesting,
        "a stale offer must never surface against a later, unrelated dictation")
    }

    // MARK: Helpers

    private func samplePayload() -> CancelUndoPayload {
      CancelUndoPayload(transcriptID: UUID(), targetApp: nil, targetElement: nil)
    }

    private struct Harness {
      let driver: KernelDictationDriver
      let kernel: RecordingSessionKernel
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
      let driver = KernelDictationDriver(
        kernel: kernel, observer: observer, outcome: KernelFinalizationOutcome(),
        context: KernelSessionContext(), steps: steps, adapter: adapter,
        engineMutationScope: .alwaysAllowedForTesting)
      driver.start()
      return Harness(driver: driver, kernel: kernel)
    }

    private func drainUntil(_ condition: @MainActor () -> Bool) async {
      for _ in 0..<2000 {
        if condition() { return }
        await Task.yield()
      }
    }
  #endif
}
