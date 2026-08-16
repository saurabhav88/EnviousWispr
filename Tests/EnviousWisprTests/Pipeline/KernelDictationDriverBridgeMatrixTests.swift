import AppKit
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
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
        engineMutationScope: .alwaysAllowedForTesting,
        minimumRecordingTicks: 0)
      let observer = KernelHeartPathTelemetryObserver(
        kernel: kernel, audioCapture: FakeAudioCapture(),
        emitter: HeartPathTelemetryEmitter(
          backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
        emitLifecycleEvent: { _ in })
      let driver = KernelDictationDriver(
        kernel: kernel, observer: observer, outcome: outcome,
        context: context, steps: steps, adapter: adapter,
        engineMutationScope: .alwaysAllowedForTesting)
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

    private func assertDriverIsError(
      _ driver: KernelDictationDriver, reason expected: TerminalNoticeReason
    ) {
      if case .error(let reason) = driver.state {
        #expect(reason == expected, "expected .error(\(expected)), got .error(\(reason))")
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
      // `delivering(.transcribing)`. #1755 chunk 3: that state ROUTES into the
      // kernel and stays pending (the suspended decode's own failure enters
      // the Phase-2 retry) — no early terminal, and no driver fallback error
      // for a routable state. Retry behavior: `KernelPhase2RetryTests`.
      let fx = makeFixture()
      await place(fx.kernel, in: .deliveringTranscribing)
      fx.driver.handleASRServiceInterruption()
      await drain()
      #expect(fx.kernel.recordingOutcome == nil, "no early terminal from a routable state")
      #expect(fx.kernel.state == .delivering)
      #expect(fx.kernel.deliveringPhase == .transcribing)
      if case .error = fx.driver.state {
        Issue.record("the driver must not manufacture its fallback error for a routable state")
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
        // The driver's setTerminalReason sets the .error state; the kernel
        // may be parked at any of several states depending on cancel
        // semantics, but the driver's public state must be .error.
        assertDriverIsError(fx.driver, reason: .asrInterrupted)
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

    /// #1408 / #1558: the bridged REASON is CAUSE-AWARE. This test used to inject
    /// `.engineLost` and demand "Microphone disconnected" — it froze the very
    /// claim that was false, since an engine that fails to recover leaves the
    /// microphone plugged in. Both causes are exercised now, so the freeze locks
    /// the distinction rather than the bug. Copy is frozen in the presenter test.
    @Test(
      "handleEngineInterruption: L/S/T/F bridges to a cause-accurate driver error (matrix #4)",
      arguments: [
        (EngineInterruptionCause.deviceRemoved, TerminalNoticeReason.deviceRemoved),
        (EngineInterruptionCause.engineLost, TerminalNoticeReason.engineLost),
      ])
    func engineInterruptionBridgesActiveNonRecording(
      cause: EngineInterruptionCause, expected: TerminalNoticeReason
    ) async {
      for placement: Placement in [
        .arming, .stopping, .deliveringTranscribing, .deliveringFinalizing,
      ] {
        let fx = makeFixture()
        await place(fx.kernel, in: placement)
        fx.driver.handleEngineInterruption(cause)
        await drain()
        assertDriverIsError(fx.driver, reason: expected)
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
      fx.driver.setTerminalReason(.modelWedged)
      #expect(fx.driver.state == .error(.modelWedged))
      fx.driver.reset()
      await drain()
      // reset() nils lastExternalError synchronously, so the external-error
      // short-circuit no longer applies. kernel.cancel from .preparing leaves
      // the kernel ~.preparing in this forced-state fixture (no forward path to
      // consume the cancel flag), so the public state falls back to the mapped
      // kernel state — crucially NOT .error(.modelWedged).
      #expect(fx.driver.state != .error(.modelWedged))
    }

    // MARK: 6. Escape Recovery stays inert until its single activation point (#2087)

    /// The whole 13-chunk order rests on one invariant: chunks 1-11 add
    /// capability that nothing can reach, and chunk 12 is the ONLY place the
    /// feature turns on. `isEscapeRecoveryTranscribing` is the capability every
    /// later chunk's policy code reads, so it is where premature activation
    /// would first become observable.
    ///
    /// This is an activation canary, not a tautology. The second assertion is
    /// the load-bearing one: even parked in `.delivering(.transcribing)` — the
    /// exact state where a real escape recovery WOULD report true — it reports
    /// false today. If a later chunk wires the kernel's disposition through
    /// before chunk 12, this fails, and it fails in the file that already owns
    /// the driver-bridges-kernel contract.
    @Test("the escape-recovery capability stays inert before chunk 12 activates it")
    func escapeRecoveryCapabilityIsInertBeforeActivation() async {
      let fx = makeFixture()
      #expect(fx.driver.isEscapeRecoveryTranscribing == false, "idle reports not-transcribing")

      await place(fx.kernel, in: .deliveringTranscribing)
      #expect(
        fx.driver.isEscapeRecoveryTranscribing == false,
        """
        The capability reported TRUE before chunk 12. Either the feature was \
        activated early — which breaks the inert-chunks invariant and can append \
        a pending row to ordinary History — or activation has landed and this \
        canary should be replaced by a real behavioural assertion.
        """)
    }

    // MARK: 7. Cancel provenance reaches the recovery ending (#2087)

    /// Lives in this suite because the driver fixture and the bounded `drain()`
    /// already exist here; the subject is the same driver-bridges-kernel
    /// contract the matrix above covers.
    ///
    /// #2087 removed the driver's own `pendingCancelOrigin` and made the fire
    /// site read `kernel.lastCancelOrigin`. Kernel-level tests cannot see that
    /// line: they would still pass if it hard-coded `.systemOrFault`, projected
    /// the wrong value, or stopped firing the callback entirely. This asserts
    /// the emitted `RecordingRecoveryEnding`, which is the actual contract the
    /// crash-recovery coordinator consumes.
    ///
    /// `.stopping` is chosen deliberately: it is the accepting state where
    /// `cancel` concludes SYNCHRONOUSLY, so `cancelRecording`'s terminal await
    /// resolves without a forward path running. Driving this from `.live`
    /// instead is what hung a run for five hours
    /// (`swift-patterns.md` RULE: tests-no-unconditional-continuation-await).
    @Test("the driver projects the kernel's accepted cancel origin into the ending")
    func cancelProvenanceReachesTheRecoveryEnding() async {
      for trigger in [UserCancelTrigger.shortcut, .cancelButton] {
        let fx = makeFixture()
        await place(fx.kernel, in: .stopping)
        let box = EndingBox()
        fx.driver.onSessionEndedWithoutSave = { _, ending in box.value = ending }

        await fx.driver.cancelRecording(disposition: .user(trigger))
        await drain()

        #expect(
          box.value == .cancelled(.user(trigger)),
          "the ending must carry the trigger the user actually used, not a default")

        // First-wins, end to end: a fault cancel arriving behind the accepted
        // user cancel must not rewrite what was emitted.
        await fx.driver.cancelRecording()
        await drain()
        #expect(
          box.value == .cancelled(.user(trigger)),
          "a later system cancel must not alter the already-emitted ending")
      }
    }
  }

  /// Captures the ending emitted by the driver's `@MainActor` callback. The
  /// suite is `@MainActor`, so plain mutation is safe.
  @MainActor
  private final class EndingBox {
    var value: RecordingRecoveryEnding?
  }

#endif  // DEBUG
