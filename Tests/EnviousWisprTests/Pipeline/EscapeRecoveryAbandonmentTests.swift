import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline

/// A second cancel during an Escape Recovery abandons the OUTPUT and cannot
/// abandon the WAIT (#2087, chunk 7).
///
/// The rule this protects is not about text, it is about the engine. Adapter
/// cancellation invalidates the generation so a late result cannot mutate the
/// next session, but the decode itself keeps running. Concluding on the second
/// cancel would free the state machine while that decode still owns the single
/// ASR engine, so a new recording could start on top of it — the same
/// two-decodes-one-engine hazard the whole feature was redesigned to avoid,
/// reached this time by a path the user never agreed to.
///
/// Nothing sets `.escapeRecovery` in production yet, because doing so also means
/// changing where a cancel routes, and that routing change is chunk 12's
/// activation. These tests use the kernel's DEBUG disposition seam instead.
@MainActor
@Suite("Escape Recovery abandonment (#2087)")
struct EscapeRecoveryAbandonmentTests {

  #if DEBUG

    // MARK: The disposition itself

    @Test("every session starts ordinary")
    func defaultDispositionIsOrdinary() {
      #expect(makeKernel().finalizationDisposition == .ordinary)
    }

    /// A disposition that leaked forward would make the NEXT take inherit an
    /// abandonment its user never asked for, and the decode-return checks would
    /// then conclude that innocent session `.cancelled` mid-transcription.
    @Test("a disposition does not survive into the next session")
    func dispositionResetsBetweenSessions() {
      let k = makeKernel()
      k.testSetFinalizationDisposition(.abandonedEscapeRecovery(triggeredAt: Date()))
      #expect(k.finalizationDisposition != .ordinary)

      k.testForceConclude(.cancelled)
      k.reset()
      k.start(config: .testDefault())

      #expect(k.finalizationDisposition == .ordinary)
    }

    // MARK: The second cancel

    @Test("a second cancel marks the recovery abandoned and keeps the session busy")
    func secondCancelMarksAbandonedWithoutConcluding() {
      let k = transcribingRecovery()

      k.cancel(origin: .user(.shortcut))

      guard case .abandonedEscapeRecovery = k.finalizationDisposition else {
        Issue.record("the second cancel did not mark the session abandoned")
        return
      }
      #expect(
        k.recordingOutcome == nil,
        "concluding here would free the engine while its decode is still running")
      #expect(k.state == .delivering, "the session stays busy until the decode returns")
    }

    /// Pressing Escape a third time is asking for something already granted.
    @Test("further cancels during an abandoned recovery change nothing")
    func repeatedCancelsAreIdempotent() {
      let k = transcribingRecovery()
      k.cancel(origin: .user(.shortcut))
      let after = k.finalizationDisposition

      k.cancel(origin: .user(.shortcut))
      k.cancel(origin: .user(.shortcut))

      #expect(k.finalizationDisposition == after)
      #expect(k.recordingOutcome == nil)
    }

    /// The control that keeps the branch honest: an ordinary transcribing cancel
    /// must still conclude immediately. Without this, marking every transcribing
    /// cancel as abandonment would pass every other test in this file.
    @Test("an ordinary cancel while transcribing still concludes immediately")
    func ordinaryCancelIsUnchanged() {
      let k = makeKernel()
      k.start(config: .testDefault())
      k.testForceState(.delivering)
      k.testSetDeliveringPhase(.transcribing)

      k.cancel(origin: .user(.shortcut))

      #expect(k.recordingOutcome == .cancelled)
      #expect(k.finalizationDisposition == .ordinary)
    }

    /// The safe point outranks abandonment. Once the transcript is in hand there
    /// is nothing left to abandon, and admitting a cancel there would break the
    /// invariant every other terminal path depends on.
    @Test("a cancel inside the safe point is still ignored during a recovery")
    func safePointStillWins() {
      let k = makeKernel()
      k.start(config: .testDefault())
      k.testForceState(.delivering)
      k.testSetFinalizationDisposition(.escapeRecovery(triggeredAt: Date()))
      k.testSetDeliveringPhase(.finalizing(.transcribing))

      k.cancel(origin: .user(.shortcut))

      guard case .escapeRecovery = k.finalizationDisposition else {
        Issue.record("the safe point admitted an abandonment it must ignore")
        return
      }
      #expect(k.recordingOutcome == nil)
    }

    // MARK: The capability AppKit reads

    /// `.abandonedEscapeRecovery` answers `false` deliberately: a decode is still
    /// running, but there is nothing left to recover, so the affordance this
    /// gates must be gone. Asking a capability rather than an identity is what
    /// makes that impossible for a caller to get wrong.
    @Test("the transcribing capability is true only for a live, unabandoned recovery")
    func capabilityIsFalseOnceAbandoned() {
      let h = makeDriver()
      h.kernel.start(config: .testDefault())
      h.kernel.testForceState(.delivering)
      h.kernel.testSetDeliveringPhase(.transcribing)
      #expect(h.driver.isEscapeRecoveryTranscribing == false, "an ordinary take is never one")

      h.kernel.testSetFinalizationDisposition(.escapeRecovery(triggeredAt: Date()))
      #expect(h.driver.isEscapeRecoveryTranscribing)

      h.kernel.testSetFinalizationDisposition(
        .abandonedEscapeRecovery(triggeredAt: Date()))
      #expect(
        h.driver.isEscapeRecoveryTranscribing == false,
        "nothing is left to recover, so the affordance must be gone")
    }

    @Test("the capability is false once the safe point is reached")
    func capabilityIsFalseInsideTheSafePoint() {
      let h = makeDriver()
      h.kernel.start(config: .testDefault())
      h.kernel.testForceState(.delivering)
      h.kernel.testSetFinalizationDisposition(.escapeRecovery(triggeredAt: Date()))
      h.kernel.testSetDeliveringPhase(.finalizing(.transcribing))

      #expect(h.driver.isEscapeRecoveryTranscribing == false)
    }

    // MARK: Helpers

    private func transcribingRecovery() -> RecordingSessionKernel {
      let k = makeKernel()
      k.start(config: .testDefault())
      k.testForceState(.delivering)
      k.testSetDeliveringPhase(.transcribing)
      k.testSetFinalizationDisposition(.escapeRecovery(triggeredAt: Date()))
      return k
    }

    private func makeKernel() -> RecordingSessionKernel {
      RecordingSessionKernel(
        adapter: FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock()),
        audioCapture: FakeAudioCapture(),
        vad: FakeVADSignalSource(),
        currentTick: { 0 },
        sleepTicks: { _ in },
        processText: { raw, _ in raw },
        store: { _, _, _ in },
        deliver: { _, _ in .pasted },
        engineMutationScope: .alwaysAllowedForTesting,
        minimumRecordingTicks: 0)
    }

    private struct Harness {
      let driver: KernelDictationDriver
      let kernel: RecordingSessionKernel
    }

    private func makeDriver() -> Harness {
      let adapter = FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock())
      let kernel = makeKernel()
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
      return Harness(driver: driver, kernel: kernel)
    }
  #endif
}
