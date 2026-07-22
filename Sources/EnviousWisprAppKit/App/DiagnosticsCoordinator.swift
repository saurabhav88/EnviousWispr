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
}
