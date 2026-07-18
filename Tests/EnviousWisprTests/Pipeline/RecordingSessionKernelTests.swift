import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - Direct kernel-invariant tests (epic #827, PR-3 plan §11.2)
//
// The scenario-execution suite asserts observable end-to-end behavior; these
// assert the FSM structural invariants (PR-1 §B.1.4) directly — `SessionID`
// uniqueness, the forbidden-transition guard, the one-terminal invariant, the
// safe point, and the §3.1a "no active task references after a terminal
// state" task-bag drain.
//
// `#if DEBUG`-gated: these tests drive the kernel through `testForceTransition`
// / `testActiveTaskCount`, which are `#if DEBUG`-only hooks on the kernel so
// they never ship in the release app binary (same posture as
// `TelemetryService.testEventHook` / `DualModePolishTelemetryTests`). The suite
// therefore compiles only in debug; the post-merge release-config test run
// skips it. Coverage is preserved in every dev/PR debug test run, and the FSM
// logic these assert is config-independent.

#if DEBUG

  @MainActor
  @Suite("RecordingSessionKernel — FSM invariants")
  struct RecordingSessionKernelTests {

    private func makeWrapper(
      behavior: FakeEngineBehavior = .batchSuccess(text: "hello")
    ) -> (SimulatorContext, KernelRecordingSession) {
      let clock = FakeClock()
      let engine = FakeEngine(behavior: behavior, clock: clock)
      let capture = FakeAudioCapture()
      let vad = FakeVADSignalSource()
      let paste = FakePasteTarget()
      let wrapper = KernelRecordingSession(
        engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
      let context = SimulatorContext(
        sut: wrapper, engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
      return (context, wrapper)
    }

    /// Drive one trigger and settle the kernel.
    private func apply(_ trigger: SessionTrigger, to wrapper: KernelRecordingSession) async {
      await wrapper.apply(trigger)
      await wrapper.drainReadyWork()
    }

    /// Start a session and drive it to `.live`. #1548 D1: reaching `.live` now
    /// requires the FIRST converted buffer (the transport gate), delivered via
    /// an async @MainActor hop — deliver one buffer and drain so the commit lands.
    private func startToLive(
      _ context: SimulatorContext, _ wrapper: KernelRecordingSession
    ) async {
      await apply(.start, to: wrapper)
      context.capture.deliverBuffer()
      await wrapper.drainReadyWork()
    }

    // MARK: Invariant 1 — SessionID minted fresh, never reused

    @Test("each session mints a distinct SessionID")
    func sessionIDNeverReused() async {
      let (context, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await apply(.start, to: wrapper)
      let first = kernel.currentSessionID
      await apply(.cancel, to: wrapper)  // recording → cancelled

      await apply(.start, to: wrapper)
      let second = kernel.currentSessionID
      await apply(.cancel, to: wrapper)

      await apply(.start, to: wrapper)
      let third = kernel.currentSessionID

      #expect(first != second)
      #expect(second != third)
      #expect(first != third)
      _ = context
    }

    @Test("reset mints a fresh SessionID so stale async work is invalidated")
    func resetMintsFreshSessionID() async {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await apply(.start, to: wrapper)
      await apply(.cancel, to: wrapper)  // → cancelled (terminal)
      let terminalSID = kernel.currentSessionID

      await apply(.reset, to: wrapper)  // cancelled → idle
      #expect(kernel.state == .idle)
      // The post-reset session identity must differ — any continuation still
      // unwinding under `terminalSID` now fails its `isCurrent` guard (Codex P1).
      #expect(kernel.currentSessionID != terminalSID)
    }

    // MARK: Invariant 6 — forbidden transition logged + refused, state unchanged

    @Test("a forbidden transition is refused and leaves FSM state unchanged")
    func forbiddenTransitionRefused() async {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      // `idle → live` skips `arming` — forbidden (#1548 D1 legal table).
      let applied = kernel.testForceTransition(to: .live)

      #expect(!applied)
      #expect(kernel.state == .idle)
      #expect(kernel.forbiddenTransitionRejected)
    }

    @Test("a forbidden transition after a conclusion is refused; the outcome holds")
    func terminalToTerminalRefused() async {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await apply(.start, to: wrapper)
      await apply(.cancel, to: wrapper)  // concludes .cancelled; the FSM returns to .idle
      #expect(kernel.recordingOutcome == .cancelled)

      // From the concluded `.idle`, only `idle → arming` is legal (#1548 D1); a
      // jump to `.live` is refused and neither the state nor the outcome moves.
      let applied = kernel.testForceTransition(to: .live)
      #expect(!applied)
      #expect(kernel.state == .idle)
      #expect(kernel.recordingOutcome == .cancelled)
      #expect(kernel.forbiddenTransitionRejected)
    }

    // MARK: Invariant 3 — exactly one terminal state per session

    @Test("post-terminal triggers are ignored — the terminal state holds")
    func oneTerminalStatePerSession() async {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await apply(.start, to: wrapper)
      await apply(.cancel, to: wrapper)
      #expect(kernel.recordingOutcome == .cancelled)

      // Every further trigger except start / reset is ignored.
      await apply(.cancel, to: wrapper)
      await apply(.stop, to: wrapper)
      #expect(kernel.recordingOutcome == .cancelled)
    }

    // MARK: Invariant 5 — the safe point is inviolable

    @Test("cancel from finalizing is ignored — the safe point holds")
    func cancelDuringFinalizingIgnored() async {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      // Walk the FSM to the finalizing safe point through legal transitions;
      // the transcribe→finalize boundary is a `deliveringPhase` advance with no
      // FSM transition (#1548 D1).
      kernel.testForceTransition(to: .arming)
      kernel.testForceTransition(to: .live)
      kernel.testForceTransition(to: .stopping)
      kernel.testForceTransition(to: .delivering)
      kernel.testSetDeliveringPhase(.finalizing(.transcribing))
      #expect(kernel.state == .delivering && kernel.deliveringPhase == .finalizing(.transcribing))

      kernel.cancel()
      // transcript in hand — cancel refused; the safe point holds.
      #expect(kernel.state == .delivering && kernel.deliveringPhase == .finalizing(.transcribing))
    }

    // MARK: §3.1a — no active task references remain after a terminal state

    @Test("the task bag is drained on reaching a terminal state")
    func taskBagDrainedAtTerminal() async {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await apply(.start, to: wrapper)
      await apply(.cancel, to: wrapper)
      #expect(kernel.recordingOutcome == .cancelled)
      #expect(kernel.testActiveTaskCount == 0)
    }

    @Test("a wedged load leaves no task references after the terminal state")
    func uncooperativeTaskDroppedAtTerminal() async {
      let (context, wrapper) = makeWrapper(behavior: .wedgeOnLoad)
      let kernel = wrapper.testKernel

      await apply(.start, to: wrapper)
      // The load wedges and parks; advance logical time so the wedge watcher
      // fires and the kernel reaches its terminal state.
      context.clock.advance(by: 4)
      await wrapper.drainReadyWork()

      #expect(kernel.recordingOutcome == .failed(.modelWedged))
      // The wedged warm-up task ignored cooperative cancellation, yet the kernel
      // holds NO task reference — it cancelled and cleared the bag (§3.1a).
      #expect(kernel.testActiveTaskCount == 0)

      context.clock.drainPending()
    }

    // MARK: #1658 PR J-2 — a non-conforming modelLoadError keeps its own bridged identity

    @Test(
      "a genuine load failure with a raw NSError normalizes at the write site and the lifecycle sink fires exactly one event under the raw error's own domain#code identity"
    )
    func modelLoadFailedRawNSErrorNormalizesToUnrecognizedModelLoad() async {
      let raw = NSError(domain: "com.acme.vendor", code: 42)
      let (_, wrapper) = makeWrapper(behavior: .failLoad(raw))
      let kernel = wrapper.testKernel

      await apply(.start, to: wrapper)

      #expect(kernel.recordingOutcome == .failed(.modelLoadFailed))
      // The write site normalizes the non-conforming error instead of dropping
      // it to nil — its bridged domain#code survives as the Sentry identity.
      #expect(
        wrapper.telemetryState.modelLoadError?.sentryFingerprintDescriptor
          == "com.acme.vendor#42")

      var capturedIdentity: String?
      var capturedDescriptor: String?
      var captureCount = 0
      let sink = KernelLifecycleTelemetrySink(
        backend: .parakeet,
        audioCapture: FakeAudioCapture(),
        context: KernelSessionContext(),
        captureTelemetry: CaptureTelemetryState(),
        telemetryState: wrapper.telemetryState,
        captureError: { error, _, _, _ in
          captureCount += 1
          capturedIdentity = error.sentrySemanticID
          capturedDescriptor = error.sentryFingerprintDescriptor
        })
      sink.emit(.failed(.modelLoadFailed))

      #expect(captureCount == 1)
      #expect(capturedDescriptor == "com.acme.vendor#42")
      #expect(capturedIdentity == "asr.unrecognized_model_load_failure")
    }

    // MARK: #959 — seam routing: ordinary terminal uses cheap cancel(), wedge uses recoverFromWedge()

    @Test("#959 an ordinary terminal routes through cheap cancel(), never recoverFromWedge()")
    func ordinaryTerminalUsesCheapCancel() async {
      let (context, wrapper) = makeWrapper()
      await apply(.start, to: wrapper)
      await apply(.cancel, to: wrapper)  // recording → cancelled (an ordinary discard)

      #expect(wrapper.testKernel.recordingOutcome == .cancelled)
      #expect(context.engine.cancelCallCount >= 1, "ordinary discard must call cheap cancel()")
      #expect(
        context.engine.recoverFromWedgeCallCount == 0,
        "ordinary discard must NOT invoke heavy wedge recovery — that was the #959 bug")
    }

    @Test("#959 a load wedge routes through recoverFromWedge(), never cheap cancel()")
    func loadWedgeUsesRecoverFromWedge() async {
      let (context, wrapper) = makeWrapper(behavior: .wedgeOnLoad)
      await apply(.start, to: wrapper)
      context.clock.advance(by: 4)  // let the wedge watcher fire
      await wrapper.drainReadyWork()

      #expect(wrapper.testKernel.recordingOutcome == .failed(.modelWedged))
      #expect(
        context.engine.recoverFromWedgeCallCount == 1,
        "a genuine load wedge must invoke heavy recovery")
      #expect(
        context.engine.cancelCallCount == 0,
        "the wedge path must NOT also run the cheap discard (no session was begun)")

      context.clock.drainPending()
    }

    // MARK: Heart/limbs — raw text survives a limb failure

    @Test("a polish-limb failure still delivers the transcript")
    func limbFailureStillDelivers() async {
      let (context, wrapper) = makeWrapper(behavior: .batchSuccess(text: "raw asr text"))
      let kernel = wrapper.testKernel

      wrapper.inject(.polishFails)
      await apply(.start, to: wrapper)
      context.capture.deliverBuffer()
      await wrapper.drainReadyWork()
      await apply(.stop, to: wrapper)

      #expect(kernel.recordingOutcome == .completed)
      #expect(kernel.deliveredTranscript == "raw asr text")
      #expect(kernel.pasteCount == 1)
    }

    // MARK: #1393 — recordingElapsedSeconds (reuses recordingStartedAtTick)

    @Test("recordingElapsedSeconds is nil before recording begins")
    func recordingElapsedSecondsNilBeforeRecording() async {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      #expect(kernel.state == .idle)
      #expect(kernel.recordingElapsedSeconds == nil)
    }

    @Test("recordingElapsedSeconds is near-zero immediately at the recording transition")
    func recordingElapsedSecondsNearZeroAtTransition() async {
      let (context, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToLive(context, wrapper)
      #expect(kernel.state == .live)
      #expect(kernel.recordingElapsedSeconds == 0)
    }

    @Test("recordingElapsedSeconds advances by exactly tickDelta × tickDurationSeconds")
    func recordingElapsedSecondsAdvancesByExactTickDelta() async {
      let (context, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToLive(context, wrapper)
      #expect(kernel.state == .live)

      context.clock.advance(by: 30)  // 30 ticks × 0.1s = 3.0s
      #expect(kernel.recordingElapsedSeconds == 3.0)

      context.clock.advance(by: 20)  // +20 ticks = 5.0s total
      #expect(kernel.recordingElapsedSeconds == 5.0)
    }

    @Test("recordingElapsedSeconds preserves the same origin throughout one session")
    func recordingElapsedSecondsPreservesOriginThroughoutSession() async {
      let (context, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToLive(context, wrapper)
      context.clock.advance(by: 10)
      let firstReading = kernel.recordingElapsedSeconds

      // Reading twice in a row (no state change, no new session) must not
      // re-stamp the origin — this is the r2/r3 characterization of the exact
      // per-view reset bug #1393 fixes, asserted at the kernel level.
      let secondReading = kernel.recordingElapsedSeconds
      #expect(firstReading == secondReading)
      #expect(firstReading == 1.0)  // 10 ticks × 0.1s
    }

    @Test(
      "recordingElapsedSeconds goes nil the instant state leaves .recording, and a fresh session starts at zero"
    )
    func recordingElapsedSecondsNilOutsideRecordingAndFreshOnNextStart() async {
      let (context, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToLive(context, wrapper)
      context.clock.advance(by: 10)
      #expect(kernel.recordingElapsedSeconds != nil)

      // r2 (cloud review P2, PR #1507): gated on `state == .recording`, not
      // merely on `recordingStartedAtTick` being set. `recordingStartedAtTick`
      // itself still isn't cleared until the NEXT session's `start(config:)`
      // (unchanged internal lifecycle — the discard gate at `:2247`/`:2660`
      // still needs it), but the PUBLIC `recordingElapsedSeconds` value now
      // correctly goes nil the moment state leaves `.recording`, closing the
      // exact stale-value window the overlay's first pill push could hit.
      await apply(.cancel, to: wrapper)  // recording → cancelled (terminal)
      #expect(kernel.recordingElapsedSeconds == nil, "gated on .recording, not on the raw tick")

      await apply(.reset, to: wrapper)  // cancelled → idle
      #expect(kernel.state == .idle)
      #expect(kernel.recordingElapsedSeconds == nil)

      // A fresh session starts its own origin at zero again, not carrying
      // the prior session's elapsed time forward.
      await startToLive(context, wrapper)
      #expect(kernel.recordingElapsedSeconds == 0)
    }

    // Note: the r3 checked-comparison guard (`guard now >= start else { return
    // 0 }`) protects against a broken/adversarially-injected clock returning a
    // tick below the stamped start. This is not exercised here: the shared
    // `FakeClock` this suite (and the wider simulator harness) depends on is
    // intentionally monotonic-only (`advance(by:)`, no way to move backward),
    // and Codex Grounded Review round 3 confirmed no production path can
    // regress `currentTick()` below `recordingStartedAtTick` either (monotonic
    // `systemUptime`, same-process, non-decreasing quantization). Adding
    // backward-clock capability to the shared `FakeClock` for this one
    // defensive-only branch was judged disproportionate; the guard's
    // correctness is covered by code inspection (Grounded Review r3) instead
    // of an automated test.
  }

#endif  // DEBUG (RecordingSessionKernel FSM-invariant tests — testForceTransition / testActiveTaskCount hooks)
