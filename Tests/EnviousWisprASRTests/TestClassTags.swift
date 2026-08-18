import Testing

/// The four test classes, for the `EnviousWisprASRTests` target.
///
/// Owner: `.claude/rules/testing-philosophy.md`
/// RULE: every-test-declares-which-of-four-things-it-protects
///
/// **This duplicates `Tests/EnviousWisprTests/Support/TestClassTags.swift` and must.** `Tag` is resolved
/// per MODULE, and `EnviousWisprASRTests` is a separate `.testTarget` (`Package.swift`) that does not
/// depend on `EnviousWisprTests`. Without this file a new ASR suite could not name the tag that
/// `scripts/test-inventory.sh --check` requires of it, so the ratchet would demand something the target
/// cannot compile. Caught by Codex review of the #2141 PR.
///
/// Keep the two files identical in tag names. The inventory reads tag NAMES out of the source, so a
/// divergence here silently mis-sorts every suite in this target rather than failing loudly.
///
/// Decide with one sentence: **"when this fails, the user sees ___."** Finish it, and the suite is
/// `.productOutcome`. Cannot finish it, and it is one of the other three.
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
  /// Gate every one with `@Test(.enabled(if:))` on the resource, so it RUNS on the dev machine and is
  /// reported SKIPPED on the hosted runner, which has no audio input device. **A skipped receipt is not a
  /// passed receipt** — the release gate reads the dev-machine run.
  @Tag static var realBoundary: Self
}
