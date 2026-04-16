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

  /// Legacy flat list of user-configured custom words (with aliases, priority).
  /// Kept for rollback safety and because existing builders render aliases.
  /// Deprecated: prefer `customVocabulary` + `languageDetection` so the planner
  /// can apply confidence-tiered, language-aware injection. Builders still read
  /// `customWords` after the planner has already filtered it to the set
  /// permitted by the active tier.
  public let customWords: [CustomWord]

  public let focusSnapshot: FocusSnapshot?

  // MARK: - Multilingual v1 (W3)

  /// Confidence-tiered, language-aware prompt vocabulary. Migration default on
  /// v1 upgrade: all existing `CustomWord` canonical spellings are placed in
  /// `global`. A per-entry language tag in the UI is a v2 enhancement.
  public let customVocabulary: PromptVocabulary

  /// Language detection outcome from the autodetect stack (W2). Nil if the
  /// callsite has not yet been wired to the detector. In that case the
  /// planner falls back to `.locked` tier (legacy behavior: inject all custom
  /// words as-is).
  public let languageDetection: LanguageDetectionResult?

  /// Active ASR backend for this polish request. Set explicitly by the
  /// pipeline so the planner can dispatch on engine identity rather than
  /// inferring it from `languageDetection == nil` (fragile: a WhisperKit
  /// codepath that forgets to run the detector would silently fall through
  /// to the English-centric legacy prompt). Nil means "unknown callsite"
  /// and preserves legacy passthrough behavior as a safety net.
  public let backend: ASRBackendType?

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
    focusSnapshot: FocusSnapshot? = nil,
    customVocabulary: PromptVocabulary? = nil,
    languageDetection: LanguageDetectionResult? = nil,
    backend: ASRBackendType? = nil
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
    // Migration default: if no explicit customVocabulary is passed, fall
    // back to deriving a global-only PromptVocabulary from customWords.
    self.customVocabulary = customVocabulary ?? PromptVocabulary.fromLegacy(customWords)
    self.languageDetection = languageDetection
    self.backend = backend
  }

  /// Returns a copy of this input with `customWords` replaced. Used by the
  /// planner to hand the builders a filtered list after applying the
  /// confidence-tiered + script-guardrail policy.
  public func withCustomWords(_ newCustomWords: [CustomWord]) -> PromptBuildInput {
    PromptBuildInput(
      transcript: transcript,
      provider: provider,
      modelID: modelID,
      stylePreset: stylePreset,
      customSystemPrompt: customSystemPrompt,
      customPromptMode: customPromptMode,
      appName: appName,
      language: language,
      customWords: newCustomWords,
      focusSnapshot: focusSnapshot,
      customVocabulary: customVocabulary,
      languageDetection: languageDetection,
      backend: backend
    )
  }
}
