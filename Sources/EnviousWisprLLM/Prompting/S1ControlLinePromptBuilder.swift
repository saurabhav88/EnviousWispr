import EnviousWisprCore

/// Builds S1-mini's published input format (#2649).
///
/// S1-mini is a third-party ASR-output normalizer (`superwhisper/s1-mini`, a
/// Qwen3-0.6B fine-tune). Its model card states the input format as a hard
/// requirement: the system prompt below, then a user message whose FIRST line is
/// a control line and whose remainder is the raw transcript. Skipping either
/// part, rewording the system prompt, or sending a value outside the trained
/// sets makes the model hallucinate or garble its output.
///
/// **The difference from every other builder here is that we cannot fix a
/// mistake by retraining.** `EGOnePromptBuilder`'s text is a contract we own
/// both halves of; this one we only own the reproduction of. So the constants
/// below are transcribed from the published card and pinned by a byte-identity
/// test against `scripts/eval/prompts/s1-mini-control-line-v1.txt`, which was
/// itself checked against the card at the pinned revision.
///
/// This builder serves BOTH routes — the managed `.s1Mini` provider and an
/// S1-mini a user pulled through Ollama themselves. The transport differs and
/// the prompt must not, so nothing downstream may carry a second copy of this
/// text; the Ollama path serialises the envelope this builder returns.
///
/// Custom vocabulary is deliberately dropped, same reasoning as EG-1 and Apple
/// Intelligence: the model never saw a vocabulary section in training, and
/// `WordCorrector` applies preferred spellings deterministically before polish.
struct S1ControlLinePromptBuilder: PromptBuilder {
  init() {}

  /// The card's exact system prompt. Verified verbatim against the published
  /// card at the pinned revision `34add00a…`, the same revision the delivery
  /// manifest pins the weights to.
  static let systemPrompt =
    "You are a text normalizer for speech-to-text transcripts. The input begins "
    + "with a control line specifying the styling, structure, and context settings; "
    + "clean the transcript to match those settings and output only the cleaned text."

  // The three control-line values used to be constants here. Since the founder
  // decision of 2026-09-04 they are user settings, carried on
  // `PromptBuildInput.s1Control` and composed by `S1ControlSettings.controlLine`,
  // which is where the reasoning behind each default now lives. The trained
  // value sets are closed enums in that type, so this builder cannot be handed
  // a value the model was not trained on.

  func build(input: PromptBuildInput, mode: PolishMode) -> PromptEnvelope {
    // `mode` is intentionally unused: this model's formatting behaviour is in
    // its weights and in the control line, not in per-transcript prompt rules.
    _ = mode

    // No tag wrapper, deliberately, and this is NOT an oversight copied from
    // `EGOnePromptBuilder`. That builder wraps the transcript in `<TRANSCRIPT>`
    // because EG-1 was tuned on that wrapper. S1-mini was tuned on a BARE
    // transcript after the control line; adding a wrapper would be exactly the
    // off-distribution drift the card warns about, and the model would be free
    // to echo the tags into the user's text.
    let userMessage = "\(input.s1Control.controlLine)\n\(input.transcript)"

    return PromptEnvelope(messages: [
      PromptMessage(role: .system, content: Self.systemPrompt),
      PromptMessage(role: .user, content: userMessage),
    ])
  }
}
