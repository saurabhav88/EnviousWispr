/// Immutable snapshot of the user's polish style settings.
/// Built at runtime from persisted settings. No persistence/schema changes.
public struct PolishStyleConfig: Sendable {
    public let writingStylePreset: WritingStylePreset
    public let customSystemPrompt: String
    public let customPromptMode: CustomPromptMode

    public init(
        writingStylePreset: WritingStylePreset,
        customSystemPrompt: String,
        customPromptMode: CustomPromptMode
    ) {
        self.writingStylePreset = writingStylePreset
        self.customSystemPrompt = customSystemPrompt
        self.customPromptMode = customPromptMode
    }
}

/// Whether the user's custom prompt uses the ${transcript} placeholder pattern.
public enum CustomPromptMode: String, Sendable {
    /// Standard preset or custom system prompt without placeholder.
    case normal

    /// Custom prompt uses ${transcript} placeholder. Minimal wrapping, preserve user intent.
    case legacyTemplate
}
