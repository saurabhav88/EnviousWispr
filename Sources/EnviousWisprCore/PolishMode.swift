/// Output formatting mode for LLM polish.
///
/// IMPORTANT — this is INTERNAL ROUTING, not a user-facing feature. There is no
/// Settings toggle, no picker, no "choose your mode" UX.
///
/// **No prompt builder reads this any more.** #1255 moved the cloud providers to one fixed
/// prompt, #1269 did the same for EG-1, and #1948 finished the job for Ollama by deleting
/// `TranscriptAnalyzer` and its per-transcript classification — every family is now forced
/// to `.message` by `DefaultPromptPlanner` and every builder ignores the value. Formatting
/// is decided by in-prompt rules.
///
/// The ONE surviving consumer is `LLMPolishStep.validatePolishOutput`, which reads the mode
/// to pick expansion-ceiling and content-drop thresholds. So the enum still has an effect,
/// but only on the safety validator, never on what the model is asked to do. The cases below
/// describe the transcript shapes the retired classifier used, kept because the thresholds
/// were tuned against them; they no longer describe how a mode gets selected.
///
/// Treat the enum as an implementation detail of the polish pipeline — tests validate the
/// OUTPUT behavior (list → bullets, short text → one paragraph), not the enum value.
public enum PolishMode: String, Sendable {
  /// Short text (<35 words, no structure cues). One paragraph, no formatting.
  case inline

  /// Medium text (35-110 words). Paragraphs at topic shifts, bullets only if list-like.
  case message

  /// Long text (>110 words or strong structure cues). Paragraphs, bullets, section labels.
  case structured

  /// Selected text with rewrite intent (future, placeholder).
  case edit
}
