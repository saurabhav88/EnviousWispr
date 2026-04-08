import EnviousWisprCore

/// Builds a provider-specific PromptEnvelope from a PromptBuildInput and PolishMode.
public protocol PromptBuilder: Sendable {
    func build(input: PromptBuildInput, mode: PolishMode) -> PromptEnvelope
}
