import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - RecordingSessionKernel — external entry methods (epic #827, PR-4b.1)
//
// PR-4b.1 removed the kernel's direct subscriptions to the shared
// `AudioCaptureInterface` callbacks (`onEngineInterrupted`, `onCaptureStalled`,
// `onXPCServiceError`). The App-side routers stay as sole subscribers; the
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

    private func makeWrapper() -> (SimulatorContext, KernelRecordingSession) {
      let clock = FakeClock()
      let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
      let capture = FakeAudioCapture()
      let vad = FakeVADSignalSource()
      let paste = FakePasteTarget()
      let wrapper = KernelRecordingSession(
        engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
      let context = SimulatorContext(
        sut: wrapper, engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
      return (context, wrapper)
    }

    private func startToRecording(_ wrapper: KernelRecordingSession) async {
      await wrapper.apply(.start)
      await wrapper.drainReadyWork()
    }

    // MARK: 1. Routing — each entry produces the right terminal

    @Test("externalEngineInterrupted routes to the audio-interrupted terminal")
    func engineInterruptedRoutes() async {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToRecording(wrapper)
      #expect(kernel.state == .recording)

      kernel.externalEngineInterrupted()
      await wrapper.drainReadyWork()

      #expect(kernel.state == .audioInterrupted)
    }

    @Test("externalASRInterrupted routes to the ASR-interrupted terminal")
    func asrInterruptedRoutes() async {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToRecording(wrapper)
      #expect(kernel.state == .recording)

      kernel.externalASRInterrupted()
      await wrapper.drainReadyWork()

      #expect(kernel.state == .asrInterrupted)
    }

    @Test("externalCaptureStalled routes to the capture-stalled failed terminal")
    func captureStalledRoutes() async {
      let (context, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToRecording(wrapper)
      #expect(kernel.state == .recording)

      kernel.externalCaptureStalled(context.capture.makeStallContext())
      await wrapper.drainReadyWork()

      #expect(kernel.state == .failed(.captureStalled))
    }

    // MARK: 2. Idempotency — a second call after terminal no-ops

    @Test("a second externalEngineInterrupted after the first reached terminal is a no-op")
    func engineInterruptedIdempotent() async {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToRecording(wrapper)
      kernel.externalEngineInterrupted()
      await wrapper.drainReadyWork()
      let firstTerminal = kernel.state
      #expect(firstTerminal == .audioInterrupted)

      kernel.externalEngineInterrupted()
      await wrapper.drainReadyWork()
      #expect(kernel.state == firstTerminal)
    }

    @Test("a second externalASRInterrupted after the first reached terminal is a no-op")
    func asrInterruptedIdempotent() async {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToRecording(wrapper)
      kernel.externalASRInterrupted()
      await wrapper.drainReadyWork()
      let firstTerminal = kernel.state
      #expect(firstTerminal == .asrInterrupted)

      kernel.externalASRInterrupted()
      await wrapper.drainReadyWork()
      #expect(kernel.state == firstTerminal)
    }

    @Test("a second externalCaptureStalled after the first reached terminal is a no-op")
    func captureStalledIdempotent() async {
      let (context, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToRecording(wrapper)
      kernel.externalCaptureStalled(context.capture.makeStallContext())
      await wrapper.drainReadyWork()
      let firstTerminal = kernel.state
      #expect(firstTerminal == .failed(.captureStalled))

      kernel.externalCaptureStalled(context.capture.makeStallContext())
      await wrapper.drainReadyWork()
      #expect(kernel.state == firstTerminal)
    }

    // MARK: 3. Idle no-op — non-terminal but non-recording

    @Test("each external entry is a no-op at .idle (non-terminal, non-recording)")
    func idleNoOp() async {
      let (context, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel
      #expect(kernel.state == .idle)

      kernel.externalEngineInterrupted()
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

      await startToRecording(wrapper)
      await wrapper.apply(.cancel)  // → cancelled
      await wrapper.drainReadyWork()
      #expect(kernel.state == .cancelled)

      kernel.externalEngineInterrupted()
      kernel.externalASRInterrupted()
      kernel.externalCaptureStalled(context.capture.makeStallContext())
      await wrapper.drainReadyWork()

      #expect(kernel.state == .cancelled)
    }

    // MARK: 5. Double-fire — one entry wins, the other no-ops

    @Test("an engine interruption followed by an ASR interruption lands a single terminal")
    func doubleFireOneWins() async {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToRecording(wrapper)
      kernel.externalEngineInterrupted()
      // Second call lands BEFORE the first has settled — the FSM is still in
      // `.recording` so the guard does not bite yet. The forward path picks
      // up one exit signal; the second is overwritten in `pendingRecordingExit`
      // OR silently discarded if a continuation already absorbed the first.
      // After draining, exactly ONE terminal must hold.
      kernel.externalASRInterrupted()
      await wrapper.drainReadyWork()

      #expect(kernel.state.isTerminal)
      #expect(
        kernel.state == .audioInterrupted || kernel.state == .asrInterrupted,
        "exactly one of the two interruption terminals must win")
    }

    // MARK: 6. Capture-stall cross-domain sessionID

    @Test("externalCaptureStalled tolerates an arbitrary UInt64 capture sessionID")
    func captureStallCrossDomainSessionID() async {
      let (_, wrapper) = makeWrapper()
      let kernel = wrapper.testKernel

      await startToRecording(wrapper)

      // The capture-layer sessionID is a `UInt64` capture counter — a different
      // domain than the kernel's UUID `SessionID`. The guard is on kernel
      // terminal state, not ID equality.
      let crossDomain = CaptureStallContext(
        sessionID: UInt64.max,
        armedAtUptimeNs: 0,
        firedAtUptimeNs: 0,
        route: "fake-cross-domain",
        sourceType: "av_audio_engine",
        engineStartedSuccessfully: true,
        tapInstalled: true,
        formatMismatchObserved: false,
        inputDeviceUIDPreferred: nil,
        inputDeviceUIDSystemDefault: nil)
      kernel.externalCaptureStalled(crossDomain)
      await wrapper.drainReadyWork()

      #expect(kernel.state == .failed(.captureStalled))
    }
  }

#endif  // DEBUG (RecordingSessionKernel external-entry tests — share the testForceTransition gating posture)
