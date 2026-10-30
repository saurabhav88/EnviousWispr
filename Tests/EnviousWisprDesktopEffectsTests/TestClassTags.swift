import Foundation
import Testing

/// This target's own tag declarations (#2455 C4).
///
/// `EnviousWisprTests` declares the same names in its own `TestClassTags.swift`.
/// Tags are target-local, so a suite moved across the boundary loses them unless
/// the new target declares its own — which is why moving a file alone does not
/// compile.
extension Tag {
  @Tag static var productOutcome: Self
  @Tag static var driftGuard: Self
  @Tag static var harnessContract: Self
  @Tag static var realBoundary: Self
}

extension Trait where Self == ConditionTrait {
  /// #4218: a real-world test (real model, microphone, GPU, live OS state or real app) runs only in
  /// the opt-in run, `scripts/xcode-test.sh --real-boundary`, used when validating a feature and
  /// before a release. The everyday local lane and CI skip it, because a busy Mac makes these flake.
  /// Every `.realBoundary` test or suite carries this trait (`TestInventoryFreezeTests`).
  static var realBoundaryRun: Self {
    .enabled(
      if: ProcessInfo.processInfo.environment["EW_REAL_BOUNDARY"] == "1",
      "real-world test: runs only in scripts/xcode-test.sh --real-boundary")
  }
}
