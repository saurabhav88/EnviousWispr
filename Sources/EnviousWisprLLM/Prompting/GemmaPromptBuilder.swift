import EnviousWisprCore

/// Builds prompts optimized for Gemma models running via Ollama.
/// Uses few-shot examples to teach formatting (Gemma mirrors demonstrated format).
/// No context block (eval showed no quality difference for Gemma).
/// No separate ASR clause (few-shot examples implicitly teach correction).
public struct GemmaPromptBuilder: PromptBuilder {
  public init() {}

  public func build(input: PromptBuildInput, mode: PolishMode) -> PromptEnvelope {
    // Weak model override: simplified prompt, no formatting, no few-shot
    if OllamaSetupService.isWeakModel(input.modelID) {
      return buildWeakModel(transcript: input.transcript)
    }

    var system = ""

    // 6. Language override (PREPENDED, minimal for small models)
    if let language = input.language, !language.isEmpty {
      system += "LANGUAGE: \(language). Keep the same language.\n\n"
    }

    // 1. Base instruction (intentionally short)
    system += """
      You rewrite dictated text for direct paste. Fix grammar and punctuation. \
      Remove filler words. Keep the same language. Return only the final text.
      """

    // 3. Few-shot examples (these ARE the formatting specification)
    system += "\n\n"
    switch mode {
    case .inline:
      system += """
        Example:
        Input: hey just wanted to let you know im running about ten minutes late traffic \
        is really bad on the highway
        Output:
        Hey, just wanted to let you know I'm running about ten minutes late. Traffic is \
        really bad on the highway.
        """

    case .message, .structured, .edit:
      system += """
        Example 1:
        Input: things i need to do today uh call the dentist pick up groceries and um \
        finish the report for sarah
        Output:
        Things I need to do today:
        - Call the dentist
        - Pick up groceries
        - Finish the report for Sarah

        Example 2:
        Input: hey just wanted to let you know im running about ten minutes late traffic \
        is really bad on the highway
        Output:
        Hey, just wanted to let you know I'm running about ten minutes late. Traffic is \
        really bad on the highway.
        """
    }

    // 4. Custom vocabulary (simplified format for small models)
    if let vocab = CustomVocabularyFormatter.renderSimplified(input.polishVocabulary.terms) {
      system += "\n\n\(vocab)"
    }

    // 5. Transcript prompt
    system += "\n\nNow clean up this text:"

    // User message: plain transcript, no wrapping
    return PromptEnvelope(messages: [
      PromptMessage(role: .system, content: system),
      PromptMessage(role: .user, content: input.transcript),
    ])
  }

  private func buildWeakModel(transcript: String) -> PromptEnvelope {
    PromptEnvelope(messages: [
      PromptMessage(
        role: .system,
        content: "Fix grammar and punctuation. Return only the corrected text."
      ),
      PromptMessage(role: .user, content: transcript),
    ])
  }

}
