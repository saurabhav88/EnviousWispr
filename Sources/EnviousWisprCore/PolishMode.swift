/// Output formatting mode for LLM polish.
///
/// IMPORTANT — this is INTERNAL ROUTING, not a user-facing feature. There is no
/// Settings toggle, no picker, no "choose your mode" UX. Every dictation is
/// auto-classified by `TranscriptAnalyzer` based on length and structure cues,
/// and the resulting case drives which formatting clause is appended to the
/// polish prompt. Treat the enum as an implementation detail of the polish
/// pipeline — tests validate the OUTPUT behavior (list → bullets, short text →
/// one paragraph), not the enum value selected.
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
