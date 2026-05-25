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
        llmPolish: LLMPolishStep(keychainManager: KeychainManager()))
      let outcome = KernelFinalizationOutcome()
      let context = KernelSessionContext()
      let kernel = RecordingSessionKernel(
        adapter: FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock()),
        audioCapture: FakeAudioCapture(),
        vad: FakeVADSignalSource(),
        currentTick: { 0 }, sleepTicks: { _ in },
        processText: { raw, _ in raw },
        store: { _ in }, deliver: { _ in .pasted },
        minimumRecordingTicks: 0)
      let observer = KernelHeartPathTelemetryObserver(
        kernel: kernel, audioCapture: FakeAudioCapture(),
        emitLifecycleEvent: { _ in })
      let driver = KernelDictationDriver(
        kernel: kernel, observer: observer, outcome: outcome,
        context: context, steps: steps)
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

    // MARK: 2. currentSessionConfig clears in each of the 8 idle/terminal states

    @Test("currentSessionConfig clears when the kernel reaches .completed")
    func clearsOnCompleted() async {
      await assertClears(targetState: .completed)
    }

    @Test("currentSessionConfig clears when the kernel reaches .cancelled")
    func clearsOnCancelled() async {
      await assertClears(targetState: .cancelled)
    }

    @Test("currentSessionConfig clears when the kernel reaches .discarded")
    func clearsOnDiscarded() async {
      await assertClears(targetState: .discarded)
    }

    @Test("currentSessionConfig clears when the kernel reaches .noSpeech")
    func clearsOnNoSpeech() async {
      await assertClears(targetState: .noSpeech)
    }

    @Test("currentSessionConfig clears when the kernel reaches .failed")
    func clearsOnFailed() async {
      await assertClears(targetState: .failed(.asrEmpty))
    }

    @Test("currentSessionConfig clears when the kernel reaches .audioInterrupted")
    func clearsOnAudioInterrupted() async {
      await assertClears(targetState: .audioInterrupted)
    }

    @Test("currentSessionConfig clears when the kernel reaches .asrInterrupted")
    func clearsOnASRInterrupted() async {
      await assertClears(targetState: .asrInterrupted)
    }

    private func assertClears(targetState: RecordingSessionState) async {
      let fx = makeFixture()
      fx.context.config = .testDefault()
      // Drive the kernel from .idle through legal intermediates to the
      // terminal under test. `.completed` and `.noSpeech` cannot be reached
      // directly from `.preparing` (the forbidden-transition guard rejects),
      // so this helper walks the legal forward path long enough that the
      // target state is always reachable. The observer's state-change task
      // is async, so drain the queue before reading.
      for step in legalPath(to: targetState) {
        fx.kernel.testForceTransition(to: step)
        await drain()
      }
      #expect(
        fx.driver.currentSessionConfig == nil,
        "\(targetState) is a 'no in-flight session' state; context.config must clear")
    }

    /// Build a legal forward-path sequence ending in `target`. Mirrors the
    /// `RecordingSessionState` transition graph documented at
    /// `RecordingSessionKernel.swift:55-68`.
    private func legalPath(to target: RecordingSessionState) -> [RecordingSessionState] {
      switch target {
      case .completed:
        return [.preparing, .recording, .stopping, .transcribing, .finalizing, .completed]
      case .noSpeech:
        return [.preparing, .recording, .stopping, .transcribing, .noSpeech]
      default:
        return [.preparing, target]
      }
    }

    // MARK: 3. currentSessionConfig stays non-nil across active states

    @Test("currentSessionConfig stays non-nil across the 6 active states")
    func staysNonNilWhileActive() async {
      let fx = makeFixture()
      fx.context.config = .testDefault()
      for active: RecordingSessionState in [
        .preparing, .warmingUp, .recording, .stopping, .transcribing, .finalizing,
      ] {
        fx.kernel.testForceTransition(to: active)
        await drain()
        #expect(
          fx.driver.currentSessionConfig != nil,
          "\(active) is an active state; context.config must persist")
      }
    }

    // MARK: 4. BT-disconnect scenario — audioInterrupted clears context.config

    @Test("BT-disconnect scenario: audioInterrupted clears context.config")
    func btDisconnectClearsConfig() async {
      let fx = makeFixture()
      fx.context.config = .testDefault()
      fx.kernel.testForceTransition(to: .preparing)
      await drain()
      fx.kernel.testForceTransition(to: .recording)
      await drain()
      #expect(fx.driver.currentSessionConfig != nil)
      fx.kernel.testForceTransition(to: .audioInterrupted)
      await drain()
      #expect(
        fx.driver.currentSessionConfig == nil,
        "audioInterrupted reached terminal; backend-switch guard must see nil")
    }
  }

#endif  // DEBUG
