import Foundation
import Testing

/// Interleaving-sweep tests (epic #827, PR-2 plan §11.2 item H, §3.5).
/// Proves the sweep is reproducible and the committed 64-seed array covers
/// every named schedule class — the metric N = 64 is justified by, not the
/// raw count.
@MainActor
@Suite("InterleavingSweep")
struct InterleavingSweepTests {

  @Test("the committed seed array holds exactly interleavingSweepCount seeds")
  func seedCountMatchesConstant() {
    #expect(interleavingSweepCount == 64)
    #expect(interleavingSweepSeeds.count == interleavingSweepCount)
    #expect(interleavingSweepSchedules.count == interleavingSweepCount)
  }

  @Test("the committed seeds are unique")
  func seedsAreUnique() {
    #expect(Set(interleavingSweepSeeds).count == interleavingSweepSeeds.count)
  }

  @Test("schedule derivation is reproducible — same seed, same schedule")
  func deriveIsReproducible() {
    for seed in interleavingSweepSeeds {
      let first = InterleavingSchedule.derive(seed: seed)
      let second = InterleavingSchedule.derive(seed: seed)
      #expect(first == second, "seed 0x\(String(seed, radix: 16)) derived two ways")
    }
  }

  @Test("different seeds produce a varied schedule population")
  func seedsProduceVariety() {
    let granularities = Set(interleavingSweepSchedules.map(\.clockGranularity))
    let orders = Set(interleavingSweepSchedules.map(\.suspensionOrder))
    #expect(granularities.count > 1, "seeds must not all derive the same granularity")
    #expect(orders.count > 1, "seeds must not all derive the same suspension order")
  }

  /// ScheduleCoverageTest — the committed 64-seed array hits all four schedule
  /// classes (PR-2 plan §3.5). This is the test that justifies N = 64.
  @Test("the 64 committed schedules cover every named schedule class")
  func scheduleCoverageIsComplete() {
    let coverage = ScheduleCoverage.evaluate(interleavingSweepSchedules)
    #expect(coverage.coversAllClockGranularities, "missing a clock-granularity class")
    #expect(coverage.coversAllCancellationTimings, "missing a cancellation-timing class")
    #expect(coverage.coversBothLateAsyncSides, "missing a late-async side")
    #expect(
      coverage.coversAllPairwiseSuspensionOrderings,
      "missing a pairwise suspension-point ordering")
    #expect(coverage.isComplete)
  }

  @Test("sweep runner reruns a concurrency scenario once per committed schedule")
  func sweepRunsOncePerSchedule() async {
    let scenario = ScenarioInventory.all.first { $0.id == "A7" }!
    let results = await InterleavingSweepRunner().runSweep(scenario) { _ in
      let clock = FakeClock()
      let stub = StubRecordingSession { trigger, session in
        if trigger == .cancel { session.setState(.cancelled) }
      }
      return SimulatorContext(
        sut: stub,
        engine: FakeEngine(behavior: .batchSuccess(text: "x"), clock: clock),
        capture: FakeAudioCapture(),
        vad: FakeVADSignalSource(),
        clock: clock,
        paste: FakePasteTarget())
    }
    #expect(results.count == interleavingSweepCount)
    // Each result carries its schedule's seed, so a failure reproduces exactly.
    #expect(Set(results.map(\.schedule.seed)).count == interleavingSweepCount)
  }
}
