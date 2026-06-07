import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - drainReadyWork settle race (recurring interleavingSweep flake)
//
// The 64-schedule sweep (`RecordingSessionKernelScenarioTests`) flaked on CI
// under full-suite MainActor contention with the same signature every time:
// `step N: expected <terminal>, got recording`, then a stale terminal. It
// recurred across #875 / #912 / #958 / #984 and main-post-merge `a4902ea`
// (scenario A8) and was repeatedly dismissed as a rerun-to-green contention
// flake (child of #881).
//
// Root cause (2026-06-06): a recording-exit delivered by a `stop` / `cancel`
// step bumps `workEpoch` and resumes the forward-path continuation
// synchronously inside that step — *before* `drainReadyWork` starts — so the
// lone bump is absorbed into the drain's initial `last`. Under contention the
// resumed-but-unscheduled forward-path task can lose the scheduler lottery for
// the whole 64-yield stability window, so the drain returns while the FSM is
// still observably `.recording`. The next step's `cancel` is then swallowed by
// the already-latched stop and the scenario flakes.
//
// Fix: `drainReadyWork` gates its return on `kernel.hasUnconsumedRecordingExit`
// — it never settles while a delivered exit is still unconsumed.

@MainActor
@Suite("drainReadyWork settle — recording-exit hand-off")
struct DrainReadyWorkSettleTests {

  private func makeContext(
    behavior: FakeEngineBehavior
  ) -> (wrapper: KernelRecordingSession, context: SimulatorContext, capture: FakeAudioCapture) {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: behavior, clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
    let context = SimulatorContext(
      sut: wrapper, engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
    return (wrapper, context, capture)
  }

  /// Deterministic lock on the hand-off signal: immediately after a `stop` from
  /// `.recording`, the exit is delivered and the forward-path continuation is
  /// resumed, but the forward-path task has NOT run yet — so the FSM is still
  /// `.recording` while `workEpoch` already carries the single (absorbed) bump.
  /// This is exactly the moment epoch-stability alone would falsely declare
  /// quiescence; `hasUnconsumedRecordingExit` flags it, and the signal-gated
  /// drain waits it out.
  @Test("a delivered recording-exit reads as unconsumed before the forward path runs")
  func unconsumedExitWindowIsFlagged() async {
    let (wrapper, _, capture) = makeContext(
      behavior: .slowFinalize(ticksToFinal: 3, text: "in flight"))
    let kernel = wrapper.testKernel

    // Drive to a settled `.recording`.
    await wrapper.apply(.start)
    await wrapper.drainReadyWork()
    capture.deliverBuffer()
    await wrapper.drainReadyWork()
    #expect(kernel.state == .recording)
    #expect(kernel.hasUnconsumedRecordingExit == false)

    // Stop synchronously delivers the exit + resumes the forward path, but does
    // not run it (no suspension between `requestStop()` returning and these
    // reads). The lone `bump()` is already in `workEpoch`, so epoch-stability
    // would settle here — but the exit is unconsumed.
    let epochBeforeStop = kernel.workEpoch
    kernel.requestStop()
    #expect(kernel.state == .recording)
    #expect(kernel.hasUnconsumedRecordingExit == true)
    #expect(kernel.workEpoch == epochBeforeStop + 1)

    // The signal-gated drain refuses to settle until the forward path consumes
    // the exit and transitions out of `.recording`.
    await wrapper.drainReadyWork()
    #expect(kernel.hasUnconsumedRecordingExit == false)
    #expect(kernel.state != .recording)
  }

  /// A7 shape: a lone `cancel` from `.recording` latches the exit the same way.
  /// The signal must flag it and the drain must wait for the `→ cancelled`
  /// transition.
  @Test("a cancel-delivered exit reads as unconsumed before the forward path runs")
  func cancelExitWindowIsFlagged() async {
    let (wrapper, _, capture) = makeContext(behavior: .batchSuccess(text: "x"))
    let kernel = wrapper.testKernel

    await wrapper.apply(.start)
    await wrapper.drainReadyWork()
    capture.deliverBuffer()
    await wrapper.drainReadyWork()
    #expect(kernel.state == .recording)

    kernel.cancel()
    #expect(kernel.state == .recording)
    #expect(kernel.hasUnconsumedRecordingExit == true)

    await wrapper.drainReadyWork()
    #expect(kernel.hasUnconsumedRecordingExit == false)
    #expect(kernel.state == .cancelled)
  }

  /// Load-robustness check (NOT a guaranteed red-without-fix discriminator):
  /// runs the full A8 sweep while 128 cooperative noise tasks compete for the
  /// MainActor, approximating the full-suite contention that triggered the CI
  /// flake. The deterministic locks above are the regression guarantee for the
  /// signal the gate depends on; this test cannot prove "fails without the gate"
  /// because Swift's cooperative executor ordering is not controllable from test
  /// code (a starve-the-forward-path interleaving is probabilistic, and on an
  /// idle local machine the forward path usually still gets its turn). Its value
  /// is the positive direction: with the gate, every schedule lands `.cancelled`
  /// even under sustained contention.
  @Test("A8 survives the 64-schedule sweep under heavy MainActor contention")
  func a8SurvivesSweepUnderContention() async {
    let noise = (0..<128).map { _ in
      Task { @MainActor in
        for _ in 0..<20000 {
          if Task.isCancelled { return }
          await Task.yield()
        }
      }
    }
    defer { for task in noise { task.cancel() } }

    guard let a8 = ScenarioInventory.all.first(where: { $0.id == "A8" }) else {
      Issue.record("A8 missing from inventory")
      return
    }

    for schedule in interleavingSweepSchedules {
      let (_, context, _) = makeContext(
        behavior: .slowFinalize(ticksToFinal: 3, text: "in flight"))
      let result = await ScenarioRunner().run(a8.applying(schedule), context: context)
      #expect(
        result.passed,
        "A8 seed \(String(schedule.seed, radix: 16)) under contention: \(result.failures)")
    }
  }
}
