/// The output of a prompt planner: a routing mode, a ready-to-send prompt envelope, and the
/// prompt family that produced it.
public struct PolishPlan: Sendable {
  public let mode: PolishMode
  public let envelope: PromptEnvelope

  /// The family the planner selected. Carried rather than recomputed: before #1948 the
  /// pipeline derived the family a SECOND time purely to stamp telemetry, so two
  /// derivations of one decision could diverge and the breadcrumb could report a family
  /// that was never used. With execution location as an input that duplication would also
  /// have needed the same new argument threaded to both call sites. One computation, one
  /// authority, and telemetry reports what was actually sent.
  public let family: PromptFamily

  public init(mode: PolishMode, envelope: PromptEnvelope, family: PromptFamily) {
    self.mode = mode
    self.envelope = envelope
    self.family = family
  }
}
