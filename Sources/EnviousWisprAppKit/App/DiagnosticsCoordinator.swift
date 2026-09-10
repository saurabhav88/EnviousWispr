import EnviousWisprASR
import Observation

/// Owns the diagnostics-tab benchmark surface that the Settings →
/// Diagnostics view drives. Extracted from the former root state per epic #763
/// (PR3, issue #768). Lifetime equals the app process; created by
/// AppDelegate and injected into the main Window scene via SwiftUI
/// environment.
@MainActor
@Observable
final class DiagnosticsCoordinator {
  let benchmark: BenchmarkSuite

  /// #1741 Chunk 5 — threads the one shared `EngineMutationScope`
  /// `WisprBootstrapper` constructs straight into `BenchmarkSuite`; not
  /// stored here, since nothing else in this home needs it after
  /// construction.
  init(engineMutationScope: EngineMutationScope) {
    benchmark = BenchmarkSuite(engineMutationScope: engineMutationScope)
  }

  /// #2648 — takes an ALREADY-BUILT suite, so the shared workload lease reaches
  /// the benchmark without this home learning what a lease is.
  ///
  /// The import ceiling refused the obvious version, and correctly: this type
  /// exists to own the benchmark surface, and threading a pipeline type through
  /// it to reach the suite is the coupling that cap is there to prevent. The
  /// composition root holds both already.
  init(benchmark: BenchmarkSuite) {
    self.benchmark = benchmark
  }
}
