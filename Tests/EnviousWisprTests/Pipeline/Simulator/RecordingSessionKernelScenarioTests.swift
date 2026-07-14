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
@Suite("RecordingSessionKernel — scenario inventory")
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

  @Test("the canonical 37-scenario inventory is intact")
  func inventoryComplete() {
    let ids = Set(ScenarioInventory.all.map(\.id))
    #expect(ids == ScenarioInventory.canonicalIDs)
    #expect(ScenarioInventory.all.count == ScenarioInventory.canonicalIDs.count)
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
