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
