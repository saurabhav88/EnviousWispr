import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Harness self-test (epic #827, PR-2 plan §11.2 item H).
/// Exercises `ScenarioRunner` against `StubRecordingSession` and proves the
/// assertion library reports pass and fail correctly. The 37-scenario
/// inventory does NOT execute in PR-2 (no kernel) — this proves the runner
/// mechanics so PR-3 inherits a trusted harness.
@MainActor
@Suite("ScenarioRunner — harness self-test", .tags(.harnessContract))
struct ScenarioRunnerTests {

  /// Build a context whose SUT is a stub scripted to model a clean success:
  /// `start → recording`, `stop → completed` with one pasted transcript.
  private func successContext() -> SimulatorContext {
    let stub = StubRecordingSession { trigger, session in
      switch trigger {
      case .start:
        session.setState(.recording)
      case .stop:
        var effects = SessionEffects()
        effects.pasteCount = 1
        effects.pasteOutcome = .pasted
        effects.transcript = "hello"
        effects.resourcesReleased = true
        session.setEffects(effects)
        session.setState(.completed)
      case .cancel, .reset, .preWarm:
        break
      }
    }
    return makeContext(sut: stub)
  }

  private func makeContext(
    sut: RecordingSessionDriving,
    clock: FakeClock = FakeClock()
  ) -> SimulatorContext {
    return SimulatorContext(
      sut: sut,
      engine: FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock),
      capture: FakeAudioCapture(),
      vad: FakeVADSignalSource(),
      clock: clock,
      paste: FakePasteTarget())
  }

  @Test("a scenario whose outcome matches the SUT passes with zero failures")
  func passingScenarioReportsPass() async {
    let scenario = Scenario(
      id: "SELFTEST-PASS",
      name: "stub success path",
      steps: [
        .trigger(.start), .expectState(.recording), .trigger(.stop),
      ],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 1, pasteOutcome: .pasted,
        transcript: .nonEmpty))
    let result = await ScenarioRunner().run(scenario, context: successContext())
    #expect(result.passed, "failures: \(result.failures)")
  }

  @Test("a mid-scenario state mismatch is reported")
  func midScenarioStateMismatchIsReported() async {
    let scenario = Scenario(
      id: "SELFTEST-MIDFAIL",
      name: "wrong mid-scenario state",
      steps: [
        .trigger(.start), .expectState(.warmingUp),
      ],
      expected: ExpectedOutcome(
        terminalState: .recording, pasteCount: 0, pasteOutcome: .none,
        transcript: .none))
    let result = await ScenarioRunner().run(scenario, context: successContext())
    #expect(!result.passed)
    #expect(result.failures.contains { $0.contains("expected state warmingUp") })
  }

  @Test("a wrong expected terminal state is reported")
  func wrongTerminalStateIsReported() async {
    let scenario = Scenario(
      id: "SELFTEST-TERMFAIL",
      name: "wrong terminal state expectation",
      steps: [.trigger(.start), .trigger(.stop)],
      expected: ExpectedOutcome(
        terminalState: .cancelled, pasteCount: 0, pasteOutcome: .none,
        transcript: .none))
    let result = await ScenarioRunner().run(scenario, context: successContext())
    #expect(!result.passed)
    #expect(result.failures.contains { $0.contains("final state") })
  }

  @Test("a duplicate paste is reported as a failure")
  func duplicatePasteIsReported() async {
    let stub = StubRecordingSession { trigger, session in
      if trigger == .stop {
        var effects = SessionEffects()
        effects.pasteCount = 2
        effects.pasteOutcome = .pasted
        effects.transcript = "x"
        effects.resourcesReleased = true
        session.setEffects(effects)
        session.setState(.completed)
      }
    }
    let scenario = Scenario(
      id: "SELFTEST-DUPPASTE",
      name: "duplicate paste detection",
      steps: [.trigger(.stop)],
      expected: ExpectedOutcome(
        terminalState: .completed, pasteCount: 2, pasteOutcome: .pasted,
        transcript: .nonEmpty))
    let result = await ScenarioRunner().run(scenario, context: makeContext(sut: stub))
    #expect(!result.passed)
    #expect(result.failures.contains { $0.contains("duplicate paste") })
  }

  @Test("triggers are dispatched to the SUT in order")
  func triggersDispatchedInOrder() async {
    let stub = StubRecordingSession { _, _ in }
    let scenario = Scenario(
      id: "SELFTEST-DISPATCH",
      name: "trigger dispatch order",
      steps: [.trigger(.start), .trigger(.stop), .trigger(.reset)],
      expected: ExpectedOutcome(
        terminalState: .idle, pasteCount: 0, pasteOutcome: .none, transcript: .none))
    _ = await ScenarioRunner().run(scenario, context: makeContext(sut: stub))
    #expect(stub.triggerLog == [.start, .stop, .reset])
  }

  // MARK: - #1868: the runner waits on the asserted signal, not on quiescence

  /// Records which drain the runner chose. The contention tests in
  /// `DrainReadyWorkSettleTests` are honest that they cannot prove
  /// red-without-fix (cooperative executor ordering is not controllable from
  /// test code), so the ROUTING is what gets locked deterministically here.
  @MainActor
  private final class DrainSpy: RecordingSessionDriving {
    private(set) var state: FSMState = .idle
    private(set) var effects = SessionEffects()
    private(set) var concludedCalls = 0
    private(set) var readyWorkCalls = 0

    func apply(_ trigger: SessionTrigger) async {}
    func drainReadyWork() async { readyWorkCalls += 1 }
    func drainUntilConcluded() async {
      concludedCalls += 1
      await drainReadyWork()
    }
    func inject(_ limb: LimbDirective) {}
  }

  @Test("a scenario asserting a TERMINAL state waits for the conclusion signal")
  func terminalAssertingScenarioWaitsForConclusion() async {
    let spy = DrainSpy()
    let scenario = Scenario(
      id: "SELFTEST-1868-TERMINAL",
      name: "terminal-asserting scenario routes to the conclusion wait",
      steps: [.trigger(.start), .trigger(.stop)],
      expected: ExpectedOutcome(
        terminalState: .failed(.asrFailed), pasteCount: 0, pasteOutcome: .none,
        transcript: .none))
    _ = await ScenarioRunner().run(scenario, context: makeContext(sut: spy))
    #expect(
      spy.concludedCalls == 1,
      """
      #1868: the teardown drain must wait for the kernel's own conclusion signal \
      when a terminal is asserted. Quiescence alone let A14 read a stale \
      `transcribing` and report a stuck session on a healthy kernel.
      """)
  }

  @Test("a scenario asserting a NON-terminal state must not wait for a conclusion")
  func nonTerminalScenarioDoesNotWaitForConclusion() async {
    let spy = DrainSpy()
    // A16's shape: `stop` with no active session, so no session is ever minted
    // and no conclusion is ever published. Waiting would burn the livelock cap
    // and record a give-up failure on a scenario that is behaving correctly.
    let scenario = Scenario(
      id: "SELFTEST-1868-IDLE",
      name: "no-session scenario keeps the plain drain",
      steps: [.trigger(.stop)],
      expected: ExpectedOutcome(
        terminalState: .idle, pasteCount: 0, pasteOutcome: .none, transcript: .none))
    _ = await ScenarioRunner().run(scenario, context: makeContext(sut: spy))
    #expect(
      spy.concludedCalls == 0,
      "#1868: `.idle` is not terminal, so A16 and its kin must keep the plain drain.")
    #expect(spy.readyWorkCalls > 0, "the plain drain must still run")
  }

  @Test("a clock-gated trigger waits for its sleeper to register before the next step")
  func clockGatedTriggerWaitsForRegistration() async {
    let clock = FakeClock()
    var sleeper: Task<Void, Never>?
    let stub = StubRecordingSession { trigger, _ in
      guard trigger == .stop else { return }
      sleeper = Task { @MainActor in await clock.sleep(ticks: 1) }
    }
    let scenario = Scenario(
      id: "SELFTEST-1868-CLOCK-REGISTRATION",
      name: "clock advance waits for the sleeper it is meant to drive",
      steps: [
        .triggerAwaitingClockRegistration(.stop),
        .advanceClock(ticks: 1),
      ],
      expected: ExpectedOutcome(
        terminalState: .idle, pasteCount: 0, pasteOutcome: .none, transcript: .none))

    _ = await ScenarioRunner().run(
      scenario,
      context: makeContext(sut: stub, clock: clock))

    let registrationsBeforeCleanup = clock.registeredWaiterCount
    #expect(
      registrationsBeforeCleanup == 1,
      """
      #1868: the runner must not advance to the next step until the trigger's \
      sleeper has actually registered. Without that wait, this deterministic \
      stub leaves the count at zero when the runner returns.
      """)

    // Keep the negative mutation non-hanging: if the runner returned early,
    // let the orphaned sleeper register, then release it before this test exits.
    if registrationsBeforeCleanup == 0 {
      await clock.waitForRegistrations(1)
      clock.drainPending()
    }
    if let sleeper { await sleeper.value }
  }

  @Test("A13 binds STOP to registration before it advances the wedge clock")
  func a13WaitsForWedgeWatcherRegistration() {
    let a13 = ScenarioInventory.all.first { $0.id == "A13" }
    let hasBoundStop = a13?.steps.indices.dropLast().contains { index in
      guard case .triggerAwaitingClockRegistration(.stop) = a13?.steps[index],
            case .advanceClock = a13?.steps[index + 1]
      else { return false }
      return true
    } ?? false

    #expect(
      hasBoundStop,
      """
      A13 must wait for the finalize wedge watcher to register before advancing \
      the logical clock; a plain STOP reopens the CI-only spawn-to-register race.
      """)
  }
}
