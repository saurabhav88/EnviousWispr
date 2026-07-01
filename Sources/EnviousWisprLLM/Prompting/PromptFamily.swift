/// Prompt style family. Maps (provider, modelID) to prompt construction strategy.
/// Builder selection goes through PromptFamily, not raw provider, so Ollama
/// running non-Gemma models gets the correct prompt style.
public enum PromptFamily: String, Sendable {
  /// Prose-style prompt with bulleted formatting rules (Ollama non-Gemma models).
  /// Since #1255 the OpenAI/Gemini cloud providers use `.cloudFixed` instead.
  case openAIProse

  /// Few-shot examples that teach formatting by demonstration (Gemma via Ollama).
  case gemmaFewShot

  /// One fixed prompt for the strong cloud providers (OpenAI, Gemini). No per-transcript
  /// mode selection — formatting is decided by in-prompt rules, like Apple Intelligence (#1255).
  case cloudFixed
}
