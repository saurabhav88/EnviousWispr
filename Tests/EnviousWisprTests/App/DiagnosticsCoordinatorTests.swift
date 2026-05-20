import Testing

@testable import EnviousWispr

/// Issue #768 (PR3 of epic #763) — pins the `DiagnosticsCoordinator` contract
/// that was extracted from the former root state.
@MainActor
@Suite("DiagnosticsCoordinator — benchmark ownership")
struct DiagnosticsCoordinatorTests {

  @Test("coordinator owns a fresh BenchmarkSuite")
  func ownsBenchmarkSuite() {
    let coordinator = DiagnosticsCoordinator()
    #expect(coordinator.benchmark.isRunning == false)
    #expect(coordinator.benchmark.results.isEmpty)
    #expect(coordinator.benchmark.pipelineResult == nil)
    #expect(coordinator.benchmark.progress.isEmpty)
  }

  @Test("two coordinators own independent BenchmarkSuite instances")
  func independentInstances() {
    let a = DiagnosticsCoordinator()
    let b = DiagnosticsCoordinator()
    #expect(a.benchmark !== b.benchmark)
  }
}
