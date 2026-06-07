import EnviousWisprCore

/// Builds prompts for Gemini models using V2 sandwich framing.
/// System prompt defines the editor role and allowed edits; user message wraps the transcript
/// in <transcript> tags with an anti-instruction clause. Resists injection and jailbreak shapes.
/// Retains mode-specific formatting, appName context, short-text guard, and custom vocabulary.
struct GeminiPromptBuilder: PromptBuilder {
  init() {}

  func build(input: PromptBuildInput, mode: PolishMode) -> PromptEnvelope {
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
    if let vocab = CustomVocabularyFormatter.render(input.polishVocabulary.terms) {
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

}
