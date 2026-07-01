import EnviousWisprCore

/// Builds prose-style prompts for the `.openAIProse` family. Since #1255 this serves ONLY
/// Ollama non-Gemma models (llama3.2, qwen, mistral, phi, ...); the OpenAI and Gemini cloud
/// providers moved to `CloudFixedPromptBuilder`. It keeps the per-mode formatting rules
/// because weaker local models still benefit from the explicit scaffolding.
/// Uses the shared `buildSandwichUserMessage` helper from PromptV2Support.swift for
/// user-message wrapping, plus its own mode-specific allowed-edits list, ASR-awareness
/// clause, appName context block, language override prefix, short-text guard, and custom
/// vocabulary rendering.
struct OpenAIPromptBuilder: PromptBuilder {
  init() {}

  func build(input: PromptBuildInput, mode: PolishMode) -> PromptEnvelope {
    var system = ""

    // Language override (prepended for non-English transcripts).
    if let language = input.language, !language.isEmpty {
      system += "LANGUAGE: This transcript is in \(language).\n"
      system += "Clean it in \(language). Do NOT translate to English.\n\n"
    }

    // Base instruction + mode-specific editing rules.
    switch mode {
    case .inline:
      system += """
        Clean up this dictated transcript for direct paste. Make minimal changes:
        - Fix punctuation, capitalization, and grammar
        - Remove filler words (um, uh, like, you know), stutters, repeated words, and false starts
        - When the speaker revises or replaces earlier wording (e.g., "X, actually Y", "not X, I mean Y", "X, no wait, Y"), keep only the final intended wording
        - Correct misheard words based on context
        - Format numbers, dates, times, phone numbers, emails, and URLs when unambiguous; if uncertain, preserve the spoken form
        - Keep as one paragraph, no formatting
        Do NOT rephrase, expand, or add content. Preserve named entities, dates, and \
        numbers exactly.
        Do NOT include any preamble or commentary. Return only the cleaned text.
        """
    case .message:
      system += """
        Clean up this dictated transcript for direct paste. Make minimal changes:
        - Fix punctuation, capitalization, and grammar
        - Remove filler words (um, uh, like, you know), stutters, repeated words, and false starts
        - When the speaker revises or replaces earlier wording (e.g., "X, actually Y", "not X, I mean Y", "X, no wait, Y"), keep only the final intended wording
        - Correct misheard words based on context
        - Format numbers, dates, times, phone numbers, emails, and URLs when unambiguous; if uncertain, preserve the spoken form
        - For lists of 3+ items: use bullet points (- item)
        - For multiple topics: use paragraph breaks
        - For short casual messages: keep as one paragraph, no formatting
        Do NOT rephrase, expand, or add content. Preserve named entities, dates, and \
        numbers exactly.
        Do NOT include any preamble or commentary. Return only the cleaned text.
        """
    case .structured:
      system += """
        Clean up this dictated transcript for direct paste. Make minimal changes:
        - Fix punctuation, capitalization, and grammar
        - Remove filler words (um, uh, like, you know), stutters, repeated words, and false starts
        - When the speaker revises or replaces earlier wording (e.g., "X, actually Y", "not X, I mean Y", "X, no wait, Y"), keep only the final intended wording
        - Correct misheard words based on context
        - Format numbers, dates, times, phone numbers, emails, and URLs when unambiguous; if uncertain, preserve the spoken form
        - Organize into readable paragraphs
        - Use bullet points (- item) for lists of 3+ items
        - Use short section labels if content clearly has sections
        Do NOT rephrase, expand, or add content. Preserve named entities, dates, and \
        numbers exactly.
        Do NOT include any preamble or commentary. Return only the cleaned text.
        """
    case .edit:
      system += """
        Clean up this dictated transcript for direct paste. Make minimal changes:
        - Fix punctuation, capitalization, and grammar
        - Remove filler words (um, uh, like, you know), stutters, repeated words, and false starts
        - When the speaker revises or replaces earlier wording (e.g., "X, actually Y", "not X, I mean Y", "X, no wait, Y"), keep only the final intended wording
        - Correct misheard words based on context
        - Format numbers, dates, times, phone numbers, emails, and URLs when unambiguous; if uncertain, preserve the spoken form
        - For lists of 3+ items: use bullet points (- item)
        - For multiple topics: use paragraph breaks
        - For short casual messages: keep as one paragraph, no formatting
        Do NOT rephrase, expand, or add content. Preserve named entities, dates, and \
        numbers exactly.
        Do NOT include any preamble or commentary. Return only the cleaned text.
        """
    }

    // ASR-awareness
    system += "\n\n"
    system += """
      This is speech-to-text output. Fix phonetically similar but contextually wrong words. \
      Keep edits minimal. If unsure, leave unchanged.
      """

    // Context block
    if let appName = input.appName {
      system += "\n\nThe user is dictating in \(appName)."
    }

    // Short-text guard (pipeline gate skips <=3 words; this covers 4-10 word inputs).
    let wordCount = input.transcript.split(whereSeparator: \.isWhitespace).count
    if wordCount <= 10 {
      system += "\n\nIMPORTANT: Very short input. Return as-is with only minimal punctuation fixes."
    }

    // Custom vocabulary
    if let vocab = CustomVocabularyFormatter.render(input.polishVocabulary.terms) {
      system += "\n\n\(vocab)"
    }

    // User message: V2 sandwich (shared helper from PromptV2Support.swift).
    let userMessage = buildSandwichUserMessage(transcript: input.transcript)

    return PromptEnvelope(messages: [
      PromptMessage(role: .system, content: system),
      PromptMessage(role: .user, content: userMessage),
    ])
  }

}
