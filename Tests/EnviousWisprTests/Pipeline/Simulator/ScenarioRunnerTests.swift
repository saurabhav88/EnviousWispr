import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Harness self-test (epic #827, PR-2 plan §11.2 item H).
/// Exercises `ScenarioRunner` against `StubRecordingSession` and proves the
/// assertion library reports pass and fail correctly. The 38-scenario
/// inventory does NOT execute in PR-2 (no kernel) — this proves the runner
/// mechanics so PR-3 inherits a trusted harness.
@MainActor
@Suite("ScenarioRunner — harness self-test")
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

  private func makeContext(sut: RecordingSessionDriving) -> SimulatorContext {
    let clock = FakeClock()
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
}
