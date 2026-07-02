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

  /// The exact training prompt for EG-1, the EnviousWispr-tuned local model served via
  /// Ollama (#1269). Mode-independent like `cloudFixed`; the tuned behaviors live in the
  /// model weights, and the prompt must match training byte-for-byte.
  case egOneFixed
}
