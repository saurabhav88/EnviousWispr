/// Prompt style family. Maps (provider, modelID) to prompt construction strategy.
/// Builder selection goes through PromptFamily, not raw provider, so Ollama
/// running non-Gemma models gets the correct prompt style.
public enum PromptFamily: String, Sendable {
  /// Prose-style prompt with bulleted formatting rules (OpenAI, Ollama non-Gemma).
  case openAIProse

  /// Plain-label TASK/CONTEXT blocks with markdown structure (Gemini).
  case geminiPlain

  /// Few-shot examples that teach formatting by demonstration (Gemma via Ollama).
  case gemmaFewShot
}
