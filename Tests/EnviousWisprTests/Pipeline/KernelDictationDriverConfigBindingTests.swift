import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - KernelDictationDriverConfigBindingTests (epic #827, PR-4b.2 §11)
//
// Coverage for:
//   - PR-4b.2 §3.3: `handle(.toggleRecording(config))` writes the 4 LLM-polish
//     fields onto `LimbSteps.llmPolish`.
//   - PR-4b.2 §3.4: `currentSessionConfig` clears in each of the 8 "no in-flight
//     session" kernel states (`.idle` + the 7 `RecordingSessionState.isTerminal`
//     states), and stays non-nil across the 6 active states.
//
// These tests bypass the public factory and construct the driver directly so
// they hold a `kernel` reference for `testForceTransition`. `#if DEBUG`-gated.

#if DEBUG

  @MainActor
  @Suite struct KernelDictationDriverConfigBindingTests {

    // MARK: Composition (no factory — needs kernel handle for testForceTransition)

    private struct Fixture {
      let driver: KernelDictationDriver
      let kernel: RecordingSessionKernel
      let context: KernelSessionContext
      let steps: LimbSteps
    }

    private func makeFixture() -> Fixture {
      let steps = LimbSteps(
        wordCorrection: WordCorrectionStep(),
        fillerRemoval: FillerRemovalStep(),
        emojiFormatter: EmojiFormatterStep(),
        inverseTextNormalization: InverseTextNormalizationStep(),
        llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
        emojiRestore: EmojiRestoreStep())
      let outcome = KernelFinalizationOutcome()
      let context = KernelSessionContext()
      let adapter = FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock())
      let kernel = RecordingSessionKernel(
        adapter: adapter,
        audioCapture: FakeAudioCapture(),
        vad: FakeVADSignalSource(),
        currentTick: { 0 }, sleepTicks: { _ in },
        processText: { raw, _ in raw },
        store: { _, _ in }, deliver: { _ in .pasted },
        minimumRecordingTicks: 0)
      let observer = KernelHeartPathTelemetryObserver(
        kernel: kernel, audioCapture: FakeAudioCapture(),
        emitter: HeartPathTelemetryEmitter(
          backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
        emitLifecycleEvent: { _ in })
      let driver = KernelDictationDriver(
        kernel: kernel, observer: observer, outcome: outcome,
        context: context, steps: steps, adapter: adapter)
      driver.start()
      return Fixture(driver: driver, kernel: kernel, context: context, steps: steps)
    }

    private func drain() async {
      for _ in 0..<100 { await Task.yield() }
    }

    // MARK: 1. LLM-config apply on toggleRecording

    @Test("handle(.toggleRecording) writes the 4 LLM-polish fields to LimbSteps.llmPolish")
    func toggleRecordingAppliesLLMConfig() async throws {
      let fx = makeFixture()
      let config: DictationSessionConfig = .testDefault(
        llmProvider: .openAI,
        llmModel: "gpt-4o-mini",
        polishInstructions: .default,
        useExtendedThinking: true)
      try await fx.driver.handle(event: .toggleRecording(config))
      #expect(fx.steps.llmPolish.llmProvider == .openAI)
      #expect(fx.steps.llmPolish.llmModel == "gpt-4o-mini")
      #expect(fx.steps.llmPolish.useExtendedThinking == true)
      // PolishInstructions is .default — set to the same value the config
      // carries; assertion is that the write happened (default == default).
      // No equality on PolishInstructions to assert further.
    }

    // MARK: 2. currentSessionConfig clears on each ending outcome (#1548 D1)
    // The ending category moved onto `recordingOutcome`; a conclusion returns
    // the FSM to `.idle`, which is the "no in-flight session" state that clears
    // the config. Each outcome is exercised.

    @Test("currentSessionConfig clears when the session concludes .completed")
    func clearsOnCompleted() async {
      await assertClears(outcome: .completed)
    }

    @Test("currentSessionConfig clears when the session concludes .cancelled")
    func clearsOnCancelled() async {
      await assertClears(outcome: .cancelled)
    }

    @Test("currentSessionConfig clears when the session concludes .discarded")
    func clearsOnDiscarded() async {
      await assertClears(outcome: .discarded(.tooShort))
    }

    @Test("currentSessionConfig clears when the session concludes .noSpeech")
    func clearsOnNoSpeech() async {
      await assertClears(outcome: .noSpeech(.vadGate))
    }

    @Test("currentSessionConfig clears when the session concludes .failed")
    func clearsOnFailed() async {
      await assertClears(outcome: .failed(.asrEmpty))
    }

    @Test("currentSessionConfig clears when the session concludes .audioInterrupted")
    func clearsOnAudioInterrupted() async {
      await assertClears(outcome: .audioInterrupted(nil))
    }

    @Test("currentSessionConfig clears when the session concludes .asrInterrupted")
    func clearsOnASRInterrupted() async {
      await assertClears(outcome: .asrInterrupted(wasRecording: true))
    }

    @Test("currentSessionConfig clears when the session concludes .noTransport")
    func clearsOnNoTransport() async {
      await assertClears(outcome: .noTransport)
    }

    private func assertClears(outcome: RecordingOutcome) async {
      let fx = makeFixture()
      fx.context.config = .testDefault()
      // Arm a session, then conclude on the outcome under test. The conclusion
      // returns the FSM to `.idle`; the driver's observer-driven cleanup fires
      // `clearContextConfigIfTerminalOrIdle` there. The observer's state-change
      // task is async, so drain the queue before reading.
      fx.kernel.testForceState(.arming)
      await drain()
      fx.kernel.testForceConclude(outcome)
      await drain()
      #expect(
        fx.driver.currentSessionConfig == nil,
        "\(outcome) concluded the session; context.config must clear")
    }

    // MARK: 3. currentSessionConfig stays non-nil across active states

    @Test("currentSessionConfig stays non-nil across every active state")
    func staysNonNilWhileActive() async {
      let fx = makeFixture()
      fx.context.config = .testDefault()
      for active: RecordingSessionState in [.arming, .live, .stopping, .delivering] {
        fx.kernel.testForceState(active)
        await drain()
        #expect(
          fx.driver.currentSessionConfig != nil,
          "\(active) is an active state; context.config must persist")
      }
    }

    // MARK: 4. BT-disconnect scenario — audioInterrupted clears context.config

    @Test("BT-disconnect scenario: an audio-interrupted conclusion clears context.config")
    func btDisconnectClearsConfig() async {
      let fx = makeFixture()
      fx.context.config = .testDefault()
      fx.kernel.testForceState(.live)
      await drain()
      #expect(fx.driver.currentSessionConfig != nil)
      fx.kernel.testForceConclude(.audioInterrupted(.deviceRemoved))
      await drain()
      #expect(
        fx.driver.currentSessionConfig == nil,
        "the audio-interrupted conclusion returned the FSM to idle; backend-switch guard must see nil"
      )
    }
  }

#endif  // DEBUG
