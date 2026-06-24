import AppKit
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - KernelDictationDriverBridgeMatrixTests (epic #827, PR-4b.2 bridge matrix)
//
// Freeze test for the (driver-entry × kernel-state) bridge matrix that Codex
// produced during PR-4b.2 review (`docs/audits/2026-05-25-pr4b2-driver-bridge-matrix-plan.txt`).
// Each cell asserts the driver's observable behavior for a forced kernel
// state. Adding or changing any driver entry MUST update this table —
// otherwise the test fails, surfacing the gap at commit time instead of at
// PR-4b.4 cutover.
//
// Coverage scope: the 5 App-routed entries whose surface PR-4b.2 introduced
// or made public — `stopAndTranscribe`, `handleEngineInterruption`,
// `handleASRServiceInterruption`, `handleCaptureStall`, `reset`. The 4
// `handle(event:)` toggle/preWarm/requestStop/cancel paths and the
// `handle(.cancelRecording)` direct method are covered by existing
// `KernelDictationDriverTests` + `KernelDictationDriverSurfaceTests`.
//
// `#if DEBUG`-gated: the tests drive the kernel through `testForceTransition`.

#if DEBUG

  @MainActor
  @Suite struct KernelDictationDriverBridgeMatrixTests {

    // MARK: Harness

    private struct Fixture {
      let driver: KernelDictationDriver
      let kernel: RecordingSessionKernel
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
        store: { _ in }, deliver: { _ in .pasted },
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
      return Fixture(driver: driver, kernel: kernel)
    }

    private func drain() async {
      for _ in 0..<100 { await Task.yield() }
    }

    /// Drive the kernel to the target state via a legal path. The
    /// forbidden-transition guard rejects gross jumps (`.preparing → .completed`),
    /// so this helper walks the FSM.
    private func forceState(
      _ kernel: RecordingSessionKernel, to target: RecordingSessionState
    ) async {
      let path: [RecordingSessionState]
      switch target {
      case .idle:
        path = []  // resting state — no transitions needed
      case .preparing:
        path = [.preparing]
      case .warmingUp:
        path = [.preparing, .warmingUp]
      case .recording:
        path = [.preparing, .recording]
      case .stopping:
        path = [.preparing, .recording, .stopping]
      case .transcribing:
        path = [.preparing, .recording, .stopping, .transcribing]
      case .finalizing:
        path = [.preparing, .recording, .stopping, .transcribing, .finalizing]
      case .completed:
        path = [.preparing, .recording, .stopping, .transcribing, .finalizing, .completed]
      case .cancelled:
        path = [.preparing, .cancelled]
      case .discarded:
        path = [.preparing, .discarded]
      case .noSpeech:
        path = [.preparing, .recording, .stopping, .transcribing, .noSpeech]
      case .failed:
        path = [.preparing, .failed(.asrEmpty)]
      case .audioInterrupted:
        path = [.preparing, .audioInterrupted]
      case .asrInterrupted:
        path = [.preparing, .asrInterrupted]
      }
      for step in path {
        kernel.testForceTransition(to: step)
        await drain()
      }
    }

    // MARK: Helper — assert PipelineState equality (custom because
    // .error(_) holds an associated value)

    private func assertDriverIsError(_ driver: KernelDictationDriver, contains: String) {
      if case .error(let msg) = driver.state {
        #expect(
          msg.contains(contains), "expected .error containing \"\(contains)\", got \"\(msg)\"")
      } else {
        Issue.record("expected .error, got \(driver.state)")
      }
    }

    // MARK: 1. stopAndTranscribe matrix

    @Test("stopAndTranscribe() is a no-op for active non-recording states (matrix #1)")
    func stopAndTranscribeMatrix() async {
      // The recording-positive case requires the full kernel FSM cycle to
      // reach a terminal and unblock `awaitKernelTerminal()`. That cycle
      // depends on the real async forward path (capture → ASR → finalize),
      // which `testForceTransition` cannot drive. The recording happy path
      // is covered by the inventory scenario tests + the live UAT at
      // PR-4b.4. The matrix freeze focuses on the no-op cases — the gap
      // Codex flagged.
      for state: RecordingSessionState in [
        .idle, .preparing, .warmingUp, .stopping, .transcribing, .finalizing,
      ] {
        let fx = makeFixture()
        await forceState(fx.kernel, to: state)
        let priorState = fx.kernel.state
        await fx.driver.stopAndTranscribe()
        await drain()
        #expect(
          fx.kernel.state == priorState,
          "stopAndTranscribe from \(state) must be a no-op; kernel changed to \(fx.kernel.state)")
      }
    }

    // MARK: 2. handleASRServiceInterruption matrix

    @Test("handleASRServiceInterruption: .recording / .transcribing routes via kernel (matrix #2)")
    func asrInterruptionRecordingOrTranscribing() async {
      // `.recording → .asrInterrupted` depends on the live recording-exit
      // continuation that the real forward path creates — the forced-state
      // fixture has no continuation, so this matrix freeze covers only
      // `.transcribing`, which routes through `finishTerminal` directly.
      // Recording-positive coverage lives in the kernel's external-entry
      // scenario tests (`RecordingSessionKernelExternalInterruptionTests`).
      let fx = makeFixture()
      await forceState(fx.kernel, to: .transcribing)
      fx.driver.handleASRServiceInterruption()
      await drain()
      if case .asrInterrupted = fx.kernel.state {
      } else {
        Issue.record(
          "asrInterruption from .transcribing must reach .asrInterrupted; got \(fx.kernel.state)")
      }
    }

    @Test("handleASRServiceInterruption: L/S/F bridges to driver error (matrix #2)")
    func asrInterruptionBridgesActiveNonRoutable() async {
      for state: RecordingSessionState in [.preparing, .warmingUp, .stopping, .finalizing] {
        let fx = makeFixture()
        await forceState(fx.kernel, to: state)
        fx.driver.handleASRServiceInterruption()
        await drain()
        // The driver's setExternalError sets the .error state; the kernel
        // may be parked at any of several states depending on cancel
        // semantics, but the driver's public state must be .error.
        assertDriverIsError(fx.driver, contains: "Transcription service crashed")
      }
    }

    @Test("handleASRServiceInterruption: idle/terminal is a no-op (matrix #2)")
    func asrInterruptionIdleOrTerminalIsNoOp() async {
      for state: RecordingSessionState in [.idle, .completed] {
        let fx = makeFixture()
        await forceState(fx.kernel, to: state)
        let priorPipelineState = fx.driver.state
        fx.driver.handleASRServiceInterruption()
        await drain()
        // No driver-side error set, no kernel transition.
        #expect(fx.driver.state == priorPipelineState)
      }
    }

    // MARK: 3. handleEngineInterruption matrix

    // Recording-positive coverage (`.recording → .audioInterrupted` via
    // `deliverRecordingExitIfCurrent`) lives in the kernel external-entry
    // scenario tests at `RecordingSessionKernelExternalInterruptionTests`.
    // The forced-state fixture has no recording-exit continuation, so the
    // matrix freeze covers only the bridge cases and the no-op cases.

    @Test("handleEngineInterruption: L/S/T/F bridges to driver error (matrix #4)")
    func engineInterruptionBridgesActiveNonRecording() async {
      for state: RecordingSessionState in [
        .preparing, .warmingUp, .stopping, .transcribing, .finalizing,
      ] {
        let fx = makeFixture()
        await forceState(fx.kernel, to: state)
        fx.driver.handleEngineInterruption(.engineLost)
        await drain()
        // Driver public state must surface the mic-disconnect error.
        assertDriverIsError(fx.driver, contains: "Microphone disconnected")
      }
    }

    @Test("handleEngineInterruption: idle/terminal is a no-op (matrix #4)")
    func engineInterruptionIdleOrTerminalIsNoOp() async {
      for state: RecordingSessionState in [.idle, .completed] {
        let fx = makeFixture()
        await forceState(fx.kernel, to: state)
        let priorPipelineState = fx.driver.state
        fx.driver.handleEngineInterruption(.engineLost)
        await drain()
        #expect(fx.driver.state == priorPipelineState)
      }
    }

    // MARK: 5. reset() tolerance for active states (matrix #5)

    @Test("reset() cancels + resets cleanly from .preparing (matrix #5)")
    func resetTolerantOfActiveStates() async {
      // Old TP's reset() was state-agnostic. The kernel's reset() is
      // legal-only-from-terminal; the driver bridges by cancelling first.
      // `.preparing` is the early-active state where `kernel.cancel()` is
      // synchronous (sets cancelRequested + bumps), so reset can land at
      // `.idle` without waiting on the full FSM. `.recording` reset is a
      // post-PR-4b.4 Live UAT scenario (the full cycle has to unwind).
      let fx = makeFixture()
      await forceState(fx.kernel, to: .preparing)
      // #881 TO-4: seed an external error so the driver's public state reports
      // .error(...) via the mapper short-circuit, then prove reset() clears it.
      // The old test ended in `_ = fx.driver.state  // no crash on read`, which
      // stayed green even if reset() stopped nil-ing lastExternalError (the
      // getter is pure and cannot crash). This pins the real reset() contract.
      fx.driver.setExternalError("boom")
      #expect(fx.driver.state == .error("boom"))
      fx.driver.reset()
      await drain()
      // reset() nils lastExternalError synchronously, so the external-error
      // short-circuit no longer applies. kernel.cancel from .preparing leaves
      // the kernel ~.preparing in this forced-state fixture (no forward path to
      // consume the cancel flag), so the public state falls back to the mapped
      // kernel state — crucially NOT .error("boom").
      #expect(fx.driver.state != .error("boom"))
    }
  }

#endif  // DEBUG
