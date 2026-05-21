import Foundation

// MARK: - Interleaving sweep (epic #827, PR-2 plan §3.5; epic §3a)
//
// The sweep reruns each concurrency-tagged scenario under N fixed schedules.
// N = 64 is a SPARSE, REPRODUCIBLE baseline — NOT a saturated net (council
// caught the false "dense" claim: 6 suspension points alone give 6! = 720
// orderings). N is justified by NAMED schedule-class coverage plus exact
// reproducibility, not by the raw count:
//
//   - reproducibility: each schedule derives deterministically from a
//     committed `UInt64` seed; a failure prints its seed and reruns identically.
//   - schedule-class coverage: the 64 seeds are chosen so their derived
//     schedules hit every class — `ScheduleCoverage` + `ScheduleCoverageTest`
//     assert this.
//
// PR-3, once scenarios execute against the real kernel, may raise N with
// measured saturation evidence.

/// The fixed property-test iteration count (PR-2 plan §3.5). A single named
/// constant — one place to change, with the rationale above.
let interleavingSweepCount = 64

/// Number of suspension points modelled per concurrency-sensitive scenario.
/// PR-1's concurrency scenarios each have a small set; 4 is the representative
/// count the schedule's `suspensionOrder` permutes.
let interleavingSuspensionPointCount = 4

/// The 64 committed sweep seeds (PR-2 plan §3.5). A fixed `UInt64` literal
/// array, never time-seeded — generated as a SplitMix64 stream from base
/// `0x9E3779B97F4A7C15` and frozen here so every run and every machine derives
/// the identical 64 schedules.
let interleavingSweepSeeds: [UInt64] = [
  0x6E78_9E6A_A1B9_65F4, 0x06C4_5D18_8009_454F, 0xF88B_B8A8_724C_81EC,
  0x1B39_896A_51A8_749B,
  0x53CB_9F0C_747E_A2EA, 0x2C82_9ABE_1F45_32E1, 0xC584_133A_C916_AB3C,
  0x3EE5_7890_41C9_8AC3,
  0xF3B8_488C_368C_B0A6, 0x657E_ECDD_3CB1_3D09, 0xC2D3_26E0_055B_DEF6,
  0x8621_A03F_E0BB_DB7B,
  0x8E1F_7555_983A_A92F, 0xB54E_0F16_00CC_4D19, 0x84BB_3F97_971D_80AB,
  0x7D29_825C_7552_1255,
  0xC3CF_1710_2B7F_7F86, 0x3466_E9A0_8391_4F64, 0xD81A_8D2B_5A44_85AC,
  0xDB01_602B_100B_9ED7,
  0xA903_8A92_1825_F10D, 0xEDF5_F1D9_0DCA_2F6A, 0x5449_6AD6_7BD2_634C,
  0xDD7C_01D4_F540_7269,
  0x935E_82F1_DB4C_4F7B, 0x69B8_2EBC_9223_3300, 0x40D2_9EB5_7DE1_D510,
  0xA2F0_9DAB_B45C_6316,
  0xEE52_1D7A_0F4D_3872, 0xF169_52EE_72F3_454F, 0x377D_35DE_A8E4_0225,
  0x0C7D_E806_4963_BAB0,
  0x0558_2D37_111A_C529, 0xD254_741F_599D_C6F7, 0x6963_0F75_93D1_08C3,
  0x417E_F961_81DA_A383,
  0x3C3C_41A3_B433_43A1, 0x6E19_905D_CBE5_31DF, 0x4FA9_FA73_2485_1729,
  0x84EB_4454_A792_922A,
  0x134F_7096_9181_75CE, 0x07DC_930B_3022_78A8, 0x12C0_15A9_7019_E937,
  0xCC06_C316_52EB_F438,
  0xECEE_6563_0A69_1E37, 0x3E84_ECB1_763E_79AD, 0x690E_D476_743A_AE49,
  0x7746_15D7_B1A1_F2E1,
  0x22B3_53F0_4F4F_52DA, 0xE3DD_D86B_A71A_5EB1, 0xDF26_8ADE_B651_3356,
  0x2098_EB73_D436_7D77,
  0x03D6_8453_23CE_3C71, 0xC952_C562_0043_C714, 0x9B19_6BCA_844F_1705,
  0x3026_0345_DD9E_0EC1,
  0xCF44_8A58_82BB_9698, 0xF4A5_78DC_CBC8_7656, 0xBFDE_AED9_A17B_3C8F,
  0xED79_402D_1D5C_5D7B,
  0x55F0_70AB_1CBB_F170, 0x3E00_A349_29A8_8F1D, 0xE255_B237_B8BB_18FB,
  0x2A7B_67AF_6C6A_D50E,
]

// MARK: - Schedule-class DOF (the four randomized degrees of freedom, epic §3a)

/// Fake-clock advancement granularity — the fourth randomized DOF.
enum ClockGranularity: CaseIterable, Equatable, Sendable {
  case zeroTick
  case singleTick
  case multiTick
  case finalizeWithoutProgress
}

/// Where a cancellation lands relative to a suspension point — the third DOF.
enum CancellationTiming: CaseIterable, Equatable, Sendable {
  case beforeSuspension
  case atSuspension
  case afterSuspension
}

/// One deterministic interleaving schedule, derived purely from a seed
/// (PR-2 plan §3.5). Same seed → identical schedule (the reproducibility
/// property `InterleavingSweepTests` asserts).
struct InterleavingSchedule: Equatable, Sendable {
  let seed: UInt64
  /// DOF 4 — fake-clock advancement granularity.
  let clockGranularity: ClockGranularity
  /// DOF 3 — cancellation timing.
  let cancellationTiming: CancellationTiming
  /// DOF — late async completion sampled before vs after the terminal state.
  let lateAsyncBeforeTerminal: Bool
  /// DOF 1/2 — a permutation of the suspension points (task-interleaving +
  /// suspension-point ordering).
  let suspensionOrder: [Int]

  /// Derive the schedule for `seed`. Pure — no wall clock, no global state.
  static func derive(seed: UInt64) -> InterleavingSchedule {
    var rng = SplitMix64(state: seed)
    let granularity = ClockGranularity.allCases[
      Int(rng.next() % UInt64(ClockGranularity.allCases.count))]
    let timing = CancellationTiming.allCases[
      Int(rng.next() % UInt64(CancellationTiming.allCases.count))]
    let lateAsync = (rng.next() & 1) == 0
    var order = Array(0..<interleavingSuspensionPointCount)
    // Fisher-Yates with the seeded RNG.
    var index = order.count - 1
    while index > 0 {
      let swap = Int(rng.next() % UInt64(index + 1))
      order.swapAt(index, swap)
      index -= 1
    }
    return InterleavingSchedule(
      seed: seed,
      clockGranularity: granularity,
      cancellationTiming: timing,
      lateAsyncBeforeTerminal: lateAsync,
      suspensionOrder: order)
  }
}

/// The committed 64 schedules.
let interleavingSweepSchedules: [InterleavingSchedule] =
  interleavingSweepSeeds.map(InterleavingSchedule.derive(seed:))

// MARK: - Schedule-class coverage (the metric N is justified by, PR-2 plan §3.5)

/// Reports whether a set of schedules covers every named schedule class.
/// `ScheduleCoverageTest` asserts `isComplete` over `interleavingSweepSchedules`.
struct ScheduleCoverage {
  let coversAllClockGranularities: Bool
  let coversAllCancellationTimings: Bool
  let coversBothLateAsyncSides: Bool
  /// Every ordered pair (i before j, i ≠ j) of suspension points appears in at
  /// least one schedule.
  let coversAllPairwiseSuspensionOrderings: Bool

  var isComplete: Bool {
    coversAllClockGranularities && coversAllCancellationTimings
      && coversBothLateAsyncSides && coversAllPairwiseSuspensionOrderings
  }

  static func evaluate(_ schedules: [InterleavingSchedule]) -> ScheduleCoverage {
    let granularities = Set(schedules.map(\.clockGranularity))
    let timings = Set(schedules.map(\.cancellationTiming))
    let lateAsyncSides = Set(schedules.map(\.lateAsyncBeforeTerminal))

    var seenPairs: Set<[Int]> = []
    for schedule in schedules {
      let order = schedule.suspensionOrder
      for i in 0..<order.count {
        for j in (i + 1)..<order.count {
          seenPairs.insert([order[i], order[j]])
        }
      }
    }
    let n = interleavingSuspensionPointCount
    var allPairs: Set<[Int]> = []
    for i in 0..<n {
      for j in 0..<n where i != j {
        allPairs.insert([i, j])
      }
    }

    return ScheduleCoverage(
      coversAllClockGranularities: granularities.count == ClockGranularity.allCases.count,
      coversAllCancellationTimings: timings.count == CancellationTiming.allCases.count,
      coversBothLateAsyncSides: lateAsyncSides.count == 2,
      coversAllPairwiseSuspensionOrderings: allPairs.isSubset(of: seenPairs))
  }
}

// MARK: - Sweep runner

/// Reruns one concurrency-sensitive scenario under all 64 committed schedules.
@MainActor
struct InterleavingSweepRunner {

  init() {}

  /// Run `scenario` once per committed schedule. `contextFactory` builds a
  /// fresh `SimulatorContext` for each schedule so runs do not share fake
  /// state. The failing seed is carried in each `ScenarioResult` indirectly via
  /// the returned tuple, so a failure reproduces exactly.
  func runSweep(
    _ scenario: Scenario,
    contextFactory: @MainActor (InterleavingSchedule) -> SimulatorContext
  ) async -> [(schedule: InterleavingSchedule, result: ScenarioResult)] {
    let runner = ScenarioRunner()
    var results: [(InterleavingSchedule, ScenarioResult)] = []
    for schedule in interleavingSweepSchedules {
      let context = contextFactory(schedule)
      // Apply the schedule to the step script so each of the 64 runs genuinely
      // varies (clock cadence + cancel timing) — not 64 identical copies.
      let scheduledScenario = scenario.applying(schedule)
      let result = await runner.run(scheduledScenario, context: context)
      results.append((schedule, result))
    }
    return results
  }
}

// MARK: - SplitMix64

/// A tiny, fast, fully deterministic PRNG. Used only to derive a schedule from
/// a seed — never for anything that needs cryptographic quality.
struct SplitMix64 {
  private var state: UInt64

  init(state: UInt64) {
    self.state = state
  }

  mutating func next() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
