import Foundation

/// On-device safety classifier for Apple Intelligence polish output.
///
/// `score` returns the sigmoid probability that the polished output is a
/// composed artifact (instruction-execution) rather than a cleaned dictation.
/// Probability `>= OutputClassifierManifest.discardThreshold` ⇒ discard the
/// polish and fall back to the raw transcript.
///
/// The classifier is a LIMB, never the heart: every failure mode (missing
/// resources, contract mismatch, load failure, inference error, timeout, NaN)
/// fails open. `score` may throw; callers treat any throw as "keep the polish".
public protocol OutputClassifierProtocol: Sendable {
  func score(input: String, polished: String) async throws -> Double
}

/// Reference holder so the async-prewarmed classifier becomes visible to the
/// per-polish construction site once loading completes.
///
/// The classifier loads off the heart path AFTER the dictation factory and the
/// app composition root have already wired `LLMPolishStep`. `LLMPolishStep`
/// constructs `AppleIntelligenceConnector` per polish call (on the main actor),
/// reading `classifier` at that moment — so a value set after prewarm is picked
/// up by the next polish. `@MainActor` matches the `makePolisher` isolation;
/// no lock needed (set on main from the prewarm hop, read on main at polish).
/// Mirrors the `CoordinatorHolder` pattern (swift-patterns nsapp-delegate-env).
@MainActor
public final class OutputClassifierHolder {
  public var classifier: OutputClassifierProtocol?

  public init(classifier: OutputClassifierProtocol? = nil) {
    self.classifier = classifier
  }
}
