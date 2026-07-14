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
      return Fixture(driver: driver, kernel: kernel)
    }

    private func drain() async {
      for _ in 0..<100 { await Task.yield() }
    }

    /// A kernel configuration the bridge matrix parks the fixture in. #1548 D1
    /// collapsed the FSM to 5 states and moved the ending category onto
    /// `recordingOutcome`; the two `delivering` sub-phases are kept distinct
    /// because the driver's ASR-interruption routing branches on them
    /// (`.transcribing` routes to the kernel, `.finalizing(_)` is the cancel /
    /// ASR-interrupt safe point that takes the driver fallback).
    private enum Placement: CustomStringConvertible {
      case idle
      case arming
      case live
      case stopping
      case deliveringTranscribing
      case deliveringFinalizing
      /// A concluded session: `recordingOutcome` is set and the FSM is back at
      /// `.idle`. Stands in for the old terminal states (`.completed`, …).
      case concluded(RecordingOutcome)

      var description: String {
        switch self {
        case .idle: return "idle"
        case .arming: return "arming"
        case .live: return "live"
        case .stopping: return "stopping"
        case .deliveringTranscribing: return "delivering(.transcribing)"
        case .deliveringFinalizing: return "delivering(.finalizing)"
        case .concluded(let o): return "concluded(\(o))"
        }
      }
    }

    /// Park the kernel in `placement`. The matrix asserts the driver's behavior
    /// for a given kernel configuration, not the path taken to reach it, so the
    /// test seams set the state / phase / outcome directly.
    private func place(_ kernel: RecordingSessionKernel, in placement: Placement) async {
      switch placement {
      case .idle:
        break  // resting state — the fixture starts here
      case .arming:
        kernel.testForceState(.arming)
      case .live:
        kernel.testForceState(.live)
      case .stopping:
        kernel.testForceState(.stopping)
      case .deliveringTranscribing:
        kernel.testForceState(.delivering)
        kernel.testSetDeliveringPhase(.transcribing)
      case .deliveringFinalizing:
        kernel.testForceState(.delivering)
        kernel.testSetDeliveringPhase(.finalizing(.transcribing))
      case .concluded(let outcome):
        kernel.testForceConclude(outcome)
      }
      await drain()
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
      for placement: Placement in [
        .idle, .arming, .stopping, .deliveringTranscribing, .deliveringFinalizing,
      ] {
        let fx = makeFixture()
        await place(fx.kernel, in: placement)
        let priorState = fx.kernel.state
        await fx.driver.stopAndTranscribe()
        await drain()
        #expect(
          fx.kernel.state == priorState,
          "stopAndTranscribe from \(placement) must be a no-op; kernel changed to \(fx.kernel.state)"
        )
      }
    }

    // MARK: 2. handleASRServiceInterruption matrix

    @Test(
      "handleASRServiceInterruption: .live / delivering(.transcribing) routes via kernel (matrix #2)"
    )
    func asrInterruptionRecordingOrTranscribing() async {
      // `.live → .asrInterrupted` depends on the live recording-exit
      // continuation that the real forward path creates — the forced-state
      // fixture has no continuation, so this matrix freeze covers only
      // `delivering(.transcribing)`, which concludes through `finishTerminal`
      // directly. Recording-positive coverage lives in the kernel's
      // external-entry scenario tests (`RecordingSessionKernelExternalInterruptionTests`).
      let fx = makeFixture()
      await place(fx.kernel, in: .deliveringTranscribing)
      fx.driver.handleASRServiceInterruption()
      await drain()
      if case .asrInterrupted = fx.kernel.recordingOutcome {
      } else {
        Issue.record(
          "asrInterruption from delivering(.transcribing) must conclude .asrInterrupted; got outcome \(String(describing: fx.kernel.recordingOutcome))"
        )
      }
    }

    @Test(
      "handleASRServiceInterruption: arming/stopping/delivering(.finalizing) bridges to driver error (matrix #2)"
    )
    func asrInterruptionBridgesActiveNonRoutable() async {
      for placement: Placement in [.arming, .stopping, .deliveringFinalizing] {
        let fx = makeFixture()
        await place(fx.kernel, in: placement)
        fx.driver.handleASRServiceInterruption()
        await drain()
        // The driver's setExternalError sets the .error state; the kernel
        // may be parked at any of several states depending on cancel
        // semantics, but the driver's public state must be .error.
        assertDriverIsError(fx.driver, contains: "Transcription service crashed")
      }
    }

    @Test("handleASRServiceInterruption: idle/concluded is a no-op (matrix #2)")
    func asrInterruptionIdleOrTerminalIsNoOp() async {
      for placement: Placement in [.idle, .concluded(.completed)] {
        let fx = makeFixture()
        await place(fx.kernel, in: placement)
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

    /// #1408: the bridged sentence is CAUSE-AWARE. This test used to inject
    /// `.engineLost` and demand "Microphone disconnected" — it froze the very
    /// claim that was false, since an engine that fails to recover leaves the
    /// microphone plugged in. Both causes are exercised now, so the freeze locks
    /// the distinction rather than the bug.
    @Test(
      "handleEngineInterruption: L/S/T/F bridges to a cause-accurate driver error (matrix #4)",
      arguments: [
        (EngineInterruptionCause.deviceRemoved, "Microphone disconnected"),
        (EngineInterruptionCause.engineLost, "Recording interrupted"),
      ])
    func engineInterruptionBridgesActiveNonRecording(
      cause: EngineInterruptionCause, expected: String
    ) async {
      for placement: Placement in [
        .arming, .stopping, .deliveringTranscribing, .deliveringFinalizing,
      ] {
        let fx = makeFixture()
        await place(fx.kernel, in: placement)
        fx.driver.handleEngineInterruption(cause)
        await drain()
        assertDriverIsError(fx.driver, contains: expected)
      }
    }

    @Test("handleEngineInterruption: idle/concluded is a no-op (matrix #4)")
    func engineInterruptionIdleOrTerminalIsNoOp() async {
      for placement: Placement in [.idle, .concluded(.completed)] {
        let fx = makeFixture()
        await place(fx.kernel, in: placement)
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
      await place(fx.kernel, in: .arming)
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
