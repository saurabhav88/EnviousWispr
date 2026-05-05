/// All inputs needed by the prompt planner to produce a PolishPlan.
/// Bundles user settings, transcript, and context into a single immutable snapshot.
///
/// Phase 0 (#640) — `customWords: [CustomWord]` removed; replaced by
/// `polishVocabulary: PolishVocabulary` so a pack-to-prompt leak is a compile
/// error. Bible §2.2.
public struct PromptBuildInput: Sendable {
  public let transcript: String
  public let provider: LLMProvider
  public let modelID: String
  public let appName: String?
  public let language: String?

  /// Polish-prompt vocabulary. Built-in defaults + user-typed terms only;
  /// pack terms are NEVER included by construction (Phase 0, bible §2.2).
  /// Builders read `polishVocabulary.terms`.
  public let polishVocabulary: PolishVocabulary

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
    appName: String?,
    language: String?,
    polishVocabulary: PolishVocabulary,
    focusSnapshot: FocusSnapshot? = nil,
    customVocabulary: PromptVocabulary? = nil,
    languageDetection: LanguageDetectionResult? = nil,
    backend: ASRBackendType? = nil
  ) {
    self.transcript = transcript
    self.provider = provider
    self.modelID = modelID
    self.appName = appName
    self.language = language
    self.polishVocabulary = polishVocabulary
    self.focusSnapshot = focusSnapshot
    // Migration default: if no explicit customVocabulary is passed, derive it
    // from the polish lane terms (built-in + user). Pack terms (corrector
    // lane only) deliberately do NOT influence the polish-side vocabulary.
    self.customVocabulary = customVocabulary ?? PromptVocabulary.fromLegacy(polishVocabulary.terms)
    self.languageDetection = languageDetection
    self.backend = backend
  }

  /// Returns a copy of this input with `polishVocabulary` replaced. Used by
  /// the planner to hand the builders a filtered vocabulary after applying
  /// the confidence-tiered + script-guardrail policy.
  public func withPolishVocabulary(_ newPolishVocabulary: PolishVocabulary) -> PromptBuildInput {
    PromptBuildInput(
      transcript: transcript,
      provider: provider,
      modelID: modelID,
      appName: appName,
      language: language,
      polishVocabulary: newPolishVocabulary,
      focusSnapshot: focusSnapshot,
      customVocabulary: customVocabulary,
      languageDetection: languageDetection,
      backend: backend
    )
  }
}
