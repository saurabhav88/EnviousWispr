import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - RecordingSessionKernel — external entry methods (epic #827, PR-4b.1)
//
// PR-4b.1 removed the kernel's direct subscriptions to the shared
// `AudioCaptureInterface` callbacks (`onEngineInterrupted`,
// `onCaptureStalled`). The App-side routers stay as sole subscribers; the
// driver (PR-4b.2) forwards their signals into the kernel's three new
// internal entry methods. These tests pin the contract for each entry:
//
//   1. routes the correct FSM transition while the kernel is in `.recording`
//   2. is idempotent — a second call after the first reached terminal no-ops
//   3. is a no-op when the kernel is at `.idle` (between sessions)
//   4. is a no-op when the kernel is in any terminal state
//   5. covers a back-to-back double-fire — one entry wins, the other no-ops
//   6. tolerates a `CaptureStallContext` whose `sessionID` is a `UInt64`
//      capture counter from a different domain than the kernel's UUID
//      `SessionID` (the guard is on kernel terminal state, not ID equality)
//
// `#if DEBUG`-gated like the FSM-invariant suite — these tests reuse the
// `KernelRecordingSession` simulator wrapper, which uses `testForceTransition`
// in places and depends on the `#if DEBUG`-only test hooks already gated on
// `RecordingSessionKernel`.

#if DEBUG

  @MainActor
  @Suite("RecordingSessionKernel — external entry methods (PR-4b.1)")
  struct RecordingSessionKernelExternalInterruptionTests {

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

    /// Start a session and drive it to `.live`. #1548 D1: reaching `.live` now
    /// requires the FIRST converted buffer (the transport gate), delivered via
    /// an async @MainActor hop — so deliver one buffer and drain until the
    /// Arming → Live commit lands. Callers that then interrupt do so from `.live`.
    private func startToRecording(_ context: SimulatorContext) async {
      await context.sut.apply(.start)
      await context.sut.drainReadyWork()
      context.capture.deliverBuffer()
      await context.sut.drainReadyWork()
    }

    // MARK: 1. Routing — each entry produces the right terminal

    @Test("externalEngineInterrupted floors an empty salvage to the audio-interrupted terminal")
    func engineInterruptedRoutes() async {
      // #1548 D1: reaching `.live` requires a buffer, so an interrupt from `.live`
      // enters the #1408 salvage. Use a NON-salvageable engine so the empty
      // decode floors to `.audioInterrupted` — proving the routing, not salvage
      // (salvage-completes has its own coverage in the salvage suite).
      let (context, wrapper) = makeWrapper(behavior: .empty(hadSpeechEvidence: false))
      let kernel = wrapper.testKernel

      await startToRecording(context)
      #expect(kernel.state == .live)

      kernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()

      #expect(kernel.recordingOutcome == .audioInterrupted(.engineLost))
    }

    @Test("externalASRInterrupted floors a failed salvage to the ASR-interrupted terminal")
    func asrInterruptedRoutes() async {
      // #1707: `.asrInterruption` now falls through into the salvage tail
      // (same shape as `.audioInterruption`, see `engineInterruptedRoutes`
      // above) — force the recovery capability to fail so this test proves
      // routing to the floor's failure target, not a successful salvage
      // (which has its own dedicated coverage in the salvage suite).
      let (context, wrapper) = makeWrapper()
      context.engine.asrInterruptionRecoveryResult = .failed
      let kernel = wrapper.testKernel

      await startToRecording(context)
      #expect(kernel.state == .live)

      kernel.externalASRInterrupted()
      await wrapper.drainReadyWork()

      // From `.live` the outcome carries `wasRecording: true` — pin the payload,
      // not just the category, so the kernel can't silently drop/invert it
      // (#1548 D1; the observer-side pass-through is proven separately).
      #expect(kernel.recordingOutcome == .asrInterrupted(wasRecording: true))
      #expect(context.engine.recoverFromASRInterruptionCallCount == 1)
      #expect(
        kernel.lastASRSalvageOutcome == .rewarmFailed,
        "Codex code-diff r2: telemetry must distinguish a rewarm failure from a decode failure")
    }

    @Test("externalASRInterrupted salvage succeeds and completes normally")
    func asrInterruptedSalvageSucceeds() async {
      // #1707: the counterpart to the routing test above — recovery succeeds
      // (the `FakeEngine` default) and decode succeeds, so the session
      // completes exactly like any ordinary recording, proving the new
      // fall-through actually reaches delivery, not just the right enum case.
      let (context, wrapper) = makeWrapper(behavior: .batchSuccess(text: "hello"))
      let kernel = wrapper.testKernel

      await startToRecording(context)
      #expect(kernel.state == .live)

      kernel.externalASRInterrupted()
      await wrapper.drainReadyWork()

      #expect(kernel.recordingOutcome == .completed)
      #expect(context.paste.pasteCount == 1)
      #expect(context.engine.recoverFromASRInterruptionCallCount == 1)
      #expect(kernel.lastASRSalvageOutcome == .rewarmSucceeded)
    }

    @Test("externalASRInterrupted while delivering(.transcribing) records wasRecording false")
    func asrInterruptedWhileTranscribingCarriesFalse() {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      // The ASR-service crash arriving during the transcribe phase (not `.live`)
      // must stamp `wasRecording: false`, the distinction `isLegalConclusion`
      // enforces per state.
      kernel.testForceState(.delivering)
      kernel.testSetDeliveringPhase(.transcribing)

      kernel.externalASRInterrupted()

      #expect(kernel.recordingOutcome == .asrInterrupted(wasRecording: false))
    }

    @Test(
      "a genuine user cancel while ASR recovery is in flight stamps the salvage outcome cancelled")
    func cancelDuringASRRecoveryStampsSalvageOutcome() async {
      // Codex code-diff r3: a user cancelling before recovery has returned must
      // NOT leave `lastASRSalvageOutcome` nil (misreporting an unresolved
      // salvage as an ordinary cancel). Hold recovery in flight on the fake
      // clock so the test can interleave a real `cancel()` mid-await, exactly
      // the race the floor's `.asr` `.cancelled` branch now covers.
      let (context, wrapper) = makeWrapper()
      context.engine.asrInterruptionRecoveryDelayTicks = 1
      let kernel = wrapper.testKernel

      await startToRecording(context)
      #expect(kernel.state == .live)

      kernel.externalASRInterrupted()
      await wrapper.drainReadyWork()
      // Recovery is parked on the fake clock — the session must still be
      // in flight, not yet concluded, for this test to prove anything.
      #expect(kernel.recordingOutcome == nil)
      #expect(kernel.state == .delivering)

      kernel.cancel()

      #expect(kernel.recordingOutcome == .cancelled)
      #expect(
        kernel.lastASRSalvageOutcome == .cancelled,
        "a user cancel while recovery is in flight must overwrite the salvage signal, got \(String(describing: kernel.lastASRSalvageOutcome))"
      )

      // Release the parked recovery task so its continuation doesn't leak;
      // the kernel's own `recordingOutcome != nil` guard makes its resumption
      // a no-op (RecordingSessionKernelTests.swift established idiom).
      context.clock.drainPending()
      await wrapper.drainReadyWork()
    }

    @Test("externalCaptureStalled routes to the capture-stalled failed terminal")
    func captureStalledRoutes() async {
      let (context, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToRecording(context)
      #expect(kernel.state == .live)

      kernel.externalCaptureStalled(context.capture.makeStallContext())
      await wrapper.drainReadyWork()

      #expect(kernel.recordingOutcome == .failed(.captureStalled))
    }

    // MARK: 2. Idempotency — a second call after terminal no-ops

    @Test("a second externalEngineInterrupted after the first reached terminal is a no-op")
    func engineInterruptedIdempotent() async {
      let (context, wrapper) = makeWrapper(behavior: .empty(hadSpeechEvidence: false))
      let kernel = wrapper.testKernel

      await startToRecording(context)
      kernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()
      let firstOutcome = kernel.recordingOutcome
      #expect(firstOutcome == .audioInterrupted(.engineLost))

      kernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()
      #expect(kernel.recordingOutcome == firstOutcome)
    }

    @Test("a second externalASRInterrupted after the first reached terminal is a no-op")
    func asrInterruptedIdempotent() async {
      // #1707: force a failed salvage (mirrors `engineInterruptedIdempotent`
      // above using a non-salvageable engine) so this test observes the
      // `.asrInterrupted` terminal it's pinning, not a successful salvage.
      let (context, wrapper) = makeWrapper()
      context.engine.asrInterruptionRecoveryResult = .failed
      let kernel = wrapper.testKernel

      await startToRecording(context)
      kernel.externalASRInterrupted()
      await wrapper.drainReadyWork()
      let firstOutcome = kernel.recordingOutcome
      #expect(firstOutcome.kind == .asrInterrupted)

      kernel.externalASRInterrupted()
      await wrapper.drainReadyWork()
      #expect(kernel.recordingOutcome == firstOutcome)
    }

    @Test("a second externalCaptureStalled after the first reached terminal is a no-op")
    func captureStalledIdempotent() async {
      let (context, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToRecording(context)
      kernel.externalCaptureStalled(context.capture.makeStallContext())
      await wrapper.drainReadyWork()
      let firstOutcome = kernel.recordingOutcome
      #expect(firstOutcome == .failed(.captureStalled))

      kernel.externalCaptureStalled(context.capture.makeStallContext())
      await wrapper.drainReadyWork()
      #expect(kernel.recordingOutcome == firstOutcome)
    }

    // MARK: 3. Idle no-op — non-terminal but non-recording

    @Test("each external entry is a no-op at .idle (non-terminal, non-recording)")
    func idleNoOp() async {
      let (context, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel
      #expect(kernel.state == .idle)

      kernel.externalEngineInterrupted(.engineLost)
      kernel.externalASRInterrupted()
      kernel.externalCaptureStalled(context.capture.makeStallContext())
      await wrapper.drainReadyWork()

      #expect(kernel.state == .idle)
    }

    // MARK: 4. Terminal no-op — every terminal short-circuits the guard

    @Test("each external entry is a no-op once the kernel is in a terminal state")
    func terminalNoOp() async {
      let (context, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToRecording(context)
      await wrapper.apply(.cancel)  // → cancelled
      await wrapper.drainReadyWork()
      #expect(kernel.recordingOutcome == .cancelled)

      kernel.externalEngineInterrupted(.engineLost)
      kernel.externalASRInterrupted()
      kernel.externalCaptureStalled(context.capture.makeStallContext())
      await wrapper.drainReadyWork()

      #expect(kernel.recordingOutcome == .cancelled)
    }

    // MARK: 5. Double-fire — one entry wins, the other no-ops

    @Test("an engine interruption followed by an ASR interruption preserves the FIRST exit")
    func doubleFireOneWins() async {
      let (context, wrapper) = makeWrapper(behavior: .empty(hadSpeechEvidence: false))
      let kernel = wrapper.testKernel

      await startToRecording(context)
      // The engine interruption synchronously latches the first recording-exit
      // (`recordingExitLatched`); the ASR interruption's exit is then rejected.
      // With a non-salvageable engine the empty salvage floors to
      // `.audioInterrupted(.engineLost)` — the FIRST exit, deterministically.
      kernel.externalEngineInterrupted(.engineLost)
      kernel.externalASRInterrupted()
      await wrapper.drainReadyWork()

      #expect(kernel.recordingOutcome == .audioInterrupted(.engineLost))
    }

    @Test("a second engine interruption in the post-latch window preserves the FIRST cause")
    func doubleEngineFirstCauseWins() async {
      // #1207 cloud review: the exit is first-wins via `recordingExitLatched`, so
      // the stamped `lastAudioInterruptionCause` must be first-wins too. A second
      // callback arriving after the first latched the exit (state still
      // `.recording`) must NOT overwrite the cause the `.audioInterrupted` terminal
      // will use — else a verified `.deviceRemoved` could be replaced by a stale
      // `.engineLost` and mislabel the loss (or vice-versa).
      let (context, wrapper) = makeWrapper(behavior: .empty(hadSpeechEvidence: false))
      let kernel = wrapper.testKernel

      await startToRecording(context)
      // First (latching) interruption: a verified device removal → must be the
      // cause the terminal carries.
      kernel.externalEngineInterrupted(.deviceRemoved)
      // Second, in the post-latch / pre-transition window: a generic engine loss.
      // Its exit is ignored; it must NOT overwrite the stamped cause.
      kernel.externalEngineInterrupted(.engineLost)
      await wrapper.drainReadyWork()

      #expect(kernel.recordingOutcome == .audioInterrupted(.deviceRemoved))
      #expect(
        kernel.lastAudioInterruptionCause == .deviceRemoved,
        "the FIRST (latching) cause must survive; got \(String(describing: kernel.lastAudioInterruptionCause))"
      )
    }

    // MARK: 6. Capture-stall cross-domain sessionID

    @Test("externalCaptureStalled tolerates an arbitrary UInt64 capture sessionID")
    func captureStallCrossDomainSessionID() async {
      let (context, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToRecording(context)

      // The capture-layer sessionID is a `UInt64` capture counter — a different
      // domain than the kernel's UUID `SessionID`. The guard is on kernel
      // terminal state, not ID equality.
      let crossDomain = CaptureStallContext(
        sessionID: UInt64.max,
        armedAtUptimeNs: 0,
        firedAtUptimeNs: 0,
        route: "fake-cross-domain",
        sourceType: "hal_device_input",
        engineStartedSuccessfully: true,
        tapInstalled: true,
        formatMismatchObserved: false,
        inputDeviceUIDPreferred: nil,
        inputDeviceUIDSystemDefault: nil,
        failureMode: .noBuffers)
      kernel.externalCaptureStalled(crossDomain)
      await wrapper.drainReadyWork()

      #expect(kernel.recordingOutcome == .failed(.captureStalled))
    }
  }

#endif  // DEBUG (RecordingSessionKernel external-entry tests — share the testForceTransition gating posture)
