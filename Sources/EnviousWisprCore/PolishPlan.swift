/// The output of a prompt planner: a routing mode and a ready-to-send prompt envelope.
public struct PolishPlan: Sendable {
  public let mode: PolishMode
  public let envelope: PromptEnvelope

  public init(mode: PolishMode, envelope: PromptEnvelope) {
    self.mode = mode
    self.envelope = envelope
  }
}
