import EnviousWisprCore

/// Produces a PolishPlan (mode + envelope) from a PromptBuildInput.
/// Never throws. Bad inputs degrade gracefully.
public protocol PromptPlanning: Sendable {
  func plan(input: PromptBuildInput) -> PolishPlan
}
