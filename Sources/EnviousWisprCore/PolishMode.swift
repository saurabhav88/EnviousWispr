/// Output formatting mode for LLM polish, determined by TranscriptAnalyzer.
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
