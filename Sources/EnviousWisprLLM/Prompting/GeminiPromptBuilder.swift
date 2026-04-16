import EnviousWisprCore

/// Builds prompts for Gemini models using V2 sandwich framing.
/// System prompt defines the editor role and allowed edits; user message wraps the transcript
/// in <transcript> tags with an anti-instruction clause. Resists injection and jailbreak shapes.
/// Retains mode-specific formatting, appName context, short-text guard, and custom vocabulary.
public struct GeminiPromptBuilder: PromptBuilder {
  public init() {}

  public func build(input: PromptBuildInput, mode: PolishMode) -> PromptEnvelope {
    // legacyTemplate: minimal wrapping, preserves user intent. Opts out of V2 defense by design.
    if input.customPromptMode == .legacyTemplate, let customPrompt = input.customSystemPrompt {
      return buildLegacyTemplate(customPrompt: customPrompt, language: input.language)
    }

    var system = V2SystemBase

    // Context block
    if let appName = input.appName {
      system += "\n\n# Context\nApp: \(appName)"
    }

    // Formatting
    system += "\n\n"
    system += formattingClause(for: mode)

    // Short-text guard (pipeline gate skips <=3 words; this covers 4-10 word inputs).
    let wordCount = input.transcript.split(whereSeparator: \.isWhitespace).count
    if wordCount <= 10 {
      system += "\n\nIMPORTANT: Very short input. Return as-is with only minimal punctuation fixes."
    }

    // Custom vocabulary
    if let vocab = CustomVocabularyFormatter.render(input.customWords) {
      system += "\n\n\(vocab)"
    }

    system += "\n\nReturn only the final polished text."

    // User message: sandwich-wrapped transcript with anti-instruction clause.
    let userMessage = buildSandwichUserMessage(transcript: input.transcript)

    return PromptEnvelope(messages: [
      PromptMessage(role: .system, content: system),
      PromptMessage(role: .user, content: userMessage),
    ])
  }

  /// Minimal wrapping for the `${transcript}` placeholder path
  /// (`customPromptMode == .legacyTemplate`). The caller supplied a custom system prompt
  /// with a literal `${transcript}` placeholder that `LLMPolishStep` substitutes with
  /// the raw transcript before this call. This mode EXPLICITLY OPTS OUT OF V2
  /// ANTI-INSTRUCTION DEFENSE: we do not wrap in `<transcript>` tags, we do not add
  /// allowed-edits or multilingual clauses. The user owns prompt safety for their custom
  /// prompt.
  ///
  /// Wrapping we still apply: optional language prefix (non-English transcripts) and a
  /// trailing "Return only the final text." sentence as a minimum format safety net.
  /// See docs/feature-requests/polish-prompt-v2.md §3.5 and
  /// Sources/EnviousWisprCore/PolishStyleConfig.swift for `CustomPromptMode.legacyTemplate`.
  private func buildLegacyTemplate(customPrompt: String, language: String?) -> PromptEnvelope {
    var system = ""
    if let language = language, !language.isEmpty {
      system += "LANGUAGE: This transcript is in \(language).\n"
      system += "Rewrite it in \(language). Do NOT translate to English.\n\n"
    }
    system += customPrompt
    system += "\nReturn only the final text."

    return PromptEnvelope(messages: [
      PromptMessage(role: .system, content: system),
      PromptMessage(role: .user, content: ""),
    ])
  }
}
