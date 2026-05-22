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

    // `idle → recording` skips `preparing` — forbidden (PR-1 §B.1.2).
    let applied = kernel.testForceTransition(to: .recording)

    #expect(!applied)
    #expect(kernel.state == .idle)
    #expect(kernel.forbiddenTransitionRejected)
  }

  @Test("a terminal → terminal transition is refused")
  func terminalToTerminalRefused() async {
    let (_, wrapper) = makeWrapper()
    let kernel = wrapper.testKernel

    await apply(.start, to: wrapper)
    await apply(.cancel, to: wrapper)  // → cancelled
    #expect(kernel.state == .cancelled)

    let applied = kernel.testForceTransition(to: .completed)
    #expect(!applied)
    #expect(kernel.state == .cancelled)
    #expect(kernel.forbiddenTransitionRejected)
  }

  // MARK: Invariant 3 — exactly one terminal state per session

  @Test("post-terminal triggers are ignored — the terminal state holds")
  func oneTerminalStatePerSession() async {
    let (_, wrapper) = makeWrapper()
    let kernel = wrapper.testKernel

    await apply(.start, to: wrapper)
    await apply(.cancel, to: wrapper)
    #expect(kernel.state == .cancelled)

    // Every further trigger except start / reset is ignored.
    await apply(.cancel, to: wrapper)
    await apply(.stop, to: wrapper)
    #expect(kernel.state == .cancelled)
  }

  // MARK: Invariant 5 — the safe point is inviolable

  @Test("cancel from finalizing is ignored — the safe point holds")
  func cancelDuringFinalizingIgnored() async {
    let (_, wrapper) = makeWrapper()
    let kernel = wrapper.testKernel

    // Walk the FSM to `finalizing` through legal transitions.
    kernel.testForceTransition(to: .preparing)
    kernel.testForceTransition(to: .warmingUp)
    kernel.testForceTransition(to: .recording)
    kernel.testForceTransition(to: .stopping)
    kernel.testForceTransition(to: .transcribing)
    kernel.testForceTransition(to: .finalizing)
    #expect(kernel.state == .finalizing)

    kernel.cancel()
    #expect(kernel.state == .finalizing)  // transcript in hand — cancel refused
  }

  // MARK: §3.1a — no active task references remain after a terminal state

  @Test("the task bag is drained on reaching a terminal state")
  func taskBagDrainedAtTerminal() async {
    let (_, wrapper) = makeWrapper()
    let kernel = wrapper.testKernel

    await apply(.start, to: wrapper)
    await apply(.cancel, to: wrapper)
    #expect(kernel.state == .cancelled)
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

    #expect(kernel.state == .failed(.modelWedged))
    // The wedged warm-up task ignored cooperative cancellation, yet the kernel
    // holds NO task reference — it cancelled and cleared the bag (§3.1a).
    #expect(kernel.testActiveTaskCount == 0)

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

    #expect(kernel.state == .completed)
    #expect(kernel.deliveredTranscript == "raw asr text")
    #expect(kernel.pasteCount == 1)
  }
}
