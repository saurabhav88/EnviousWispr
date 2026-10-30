import Foundation
import Testing

/// The four things a test can protect, plus the real-boundary marker.
///
/// Owner: `.claude/rules/testing-philosophy.md`
/// RULE: every-test-declares-which-of-four-things-it-protects
///
/// The #2141 audit found 978 tests counted as safety for the user that protect something else, and ZERO
/// tests crossing a real boundary. All four classes are legitimate; the defect was arithmetic. Tag the
/// suite so `scripts/test-inventory.sh` reports the split instead of inferring it from filenames.
///
/// Decide with one sentence: **"when this fails, the user sees ___."** Finish it, and the suite is
/// `.productOutcome`. Cannot finish it, and it is one of the other three.
///
/// A tag needs an explicit `@Suite` attribute. A plain `struct` holding `@Test` functions is an IMPLICIT
/// suite and carries no tag, so add `@Suite(.tags(...))` when tagging one.
extension Tag {

  /// What the user gets: audio captured, text produced, text delivered, or a limb degrading to the last
  /// SUCCESSFUL text. Fails when a person would notice. The only class that counts as product coverage.
  @Tag static var productOutcome: Self

  /// An internal property deliberately frozen — file shape, call-site inventory, build topology, public
  /// surface. Fails when we change our own code, which is the point. Never user-facing safety.
  @Tag static var driftGuard: Self

  /// Telemetry schema, Sentry grouping, log labels: the ability to DIAGNOSE. Fails when a dashboard or an
  /// alert would lie. Protects us, not the user.
  @Tag static var observabilityContract: Self

  /// Our own fakes, simulator, and scenario inventory — the instrument itself. Fails when the instrument
  /// is wrong. A test of a test.
  @Tag static var harnessContract: Self

  /// Applied IN ADDITION to a class tag when the test crosses a REAL boundary: a real microphone, a
  /// shipped model decoding committed audio, or text landing in a real foreground app.
  ///
  /// Gate every one with `.realBoundaryRun` (runs only in `scripts/xcode-test.sh --real-boundary`, at
  /// feature validation and before a release) and with `@Test(.enabled(if:))` on the resource. **A
  /// skipped receipt is not a passed receipt**: the release gate reads the `--real-boundary` run.
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
