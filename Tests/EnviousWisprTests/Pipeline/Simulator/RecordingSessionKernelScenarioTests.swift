import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - Kernel scenario-execution suite (epic #827, PR-3 plan §11.2)
//
// Runs every `ScenarioInventory` scenario against the REAL `RecordingSessionKernel`
// through the `KernelRecordingSession` wrapper. From PR-3 this is the
// merge-blocking heart-path gate (epic §3a): a state-machine bug fails here,
// at PR CI, without a live mic. The PR-2 fake / harness / normalizer unit
// tests are a separate, unchanged suite.

@MainActor
@Suite("RecordingSessionKernel — scenario inventory", .tags(.localParallel))
struct RecordingSessionKernelScenarioTests {

  /// Build a fresh fakes + kernel-wrapper bundle. Each scenario runs against
  /// its own context — the kernel carries no state across scenarios.
  private func makeContext() -> SimulatorContext {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "default"), clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let paste = FakePasteTarget()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
    return SimulatorContext(
      sut: wrapper, engine: engine, capture: capture, vad: vad, clock: clock, paste: paste)
  }

  @Test("every inventory scenario passes against the kernel", arguments: ScenarioInventory.all)
  func runScenario(_ scenario: Scenario) async {
    let result = await ScenarioRunner().run(scenario, context: makeContext())
    #expect(result.passed, "scenario \(scenario.id) (\(scenario.name)): \(result.failures)")
  }

  /// #3834: the exact-source assertion BINDS on the real kernel. A22 (a short
  /// silent tap, `.vadGateSilent`) run with a deliberately wrong expectation of
  /// `.vadGate` must fail with the source named; if the runner ever stopped
  /// comparing, A22/A22b/A22c would pass whatever the kernel chose.
  @Test("#3834: a wrong no-speech source expectation fails against the kernel")
  func wrongNoSpeechSourceFailsAgainstKernel() async throws {
    let a22 = try #require(ScenarioInventory.all.first { $0.id == "A22" })
    let wrong = Scenario(
      id: "A22-WRONG-SOURCE", name: a22.name, steps: a22.steps,
      expected: ExpectedOutcome(
        terminalState: .noSpeech, pasteCount: 0, pasteOutcome: .none,
        transcript: .none, noSpeechSource: .vadGate, finalizeCallCount: 0))
    let result = await ScenarioRunner().run(wrong, context: makeContext())
    #expect(result.passed == false)
    #expect(
      result.failures.contains { $0.contains("expected .noSpeech(vadGate)") },
      "failures: \(result.failures)")
  }

  /// Interleaving sweep against the kernel (PR-3 plan §11.2). Each
  /// concurrency-sensitive scenario is re-run under all 64 committed
  /// schedules; the schedule rewrites clock cadence, so the kernel walks the
  /// same path with different logical-time spacing.
  @Test("concurrency-sensitive scenarios survive the 64-schedule sweep")
  func interleavingSweep() async {
    let runner = InterleavingSweepRunner()
    for scenario in ScenarioInventory.concurrencySensitive {
      let results = await runner.runSweep(scenario) { _ in self.makeContext() }
      for (schedule, result) in results {
        #expect(
          result.passed,
          "swept \(scenario.id) seed \(String(schedule.seed, radix: 16)): \(result.failures)")
      }
    }
  }
}
