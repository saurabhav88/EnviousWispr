/// All inputs needed by the prompt planner to produce a PolishPlan.
/// Bundles user settings, transcript, and context into a single immutable snapshot.
public struct PromptBuildInput: Sendable {
    public let transcript: String
    public let provider: LLMProvider
    public let modelID: String
    public let stylePreset: WritingStylePreset
    public let customSystemPrompt: String?
    public let customPromptMode: CustomPromptMode
    public let appName: String?
    public let language: String?
    public let customWords: [CustomWord]
    public let focusSnapshot: FocusSnapshot?

    public init(
        transcript: String,
        provider: LLMProvider,
        modelID: String,
        stylePreset: WritingStylePreset,
        customSystemPrompt: String?,
        customPromptMode: CustomPromptMode = .normal,
        appName: String?,
        language: String?,
        customWords: [CustomWord],
        focusSnapshot: FocusSnapshot? = nil
    ) {
        self.transcript = transcript
        self.provider = provider
        self.modelID = modelID
        self.stylePreset = stylePreset
        self.customSystemPrompt = customSystemPrompt
        self.customPromptMode = customPromptMode
        self.appName = appName
        self.language = language
        self.customWords = customWords
        self.focusSnapshot = focusSnapshot
    }
}
