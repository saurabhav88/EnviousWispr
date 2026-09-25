import EnviousWisprCore

/// EG-1 1.2's prompt, plus one sentence naming the dictation's language when the
/// pipeline is sure of it (#3111).
///
/// EG-1 1.2 sometimes translates non-English dictation into English: measured on the
/// shipped artifact with its shipped prompt, 41 of 480 sentences across 16 languages and
/// 9 of 81 Polish sentences came back English, although the prompt already says "keep
/// the same language". In an earlier probe on the 1.1 prompt, a stronger generic "never
/// translate" sentence made it worse (7 of 81 Polish, against 4).
/// Appending the sentence below took both to 0 and raised judged quality on the 480
/// from 88.5% to 98.5%. The weights are unchanged; this is a new prompt contract for
/// them, which is why it is its own family and template id rather than an edit to
/// `EGOneEnvelopePromptBuilder` (`eg1-operations.md` RULE: eg1-hot-swap-contract).
///
/// With no name, or a code outside the measured table, this renders exactly the 1.2
/// prompt. English is never named: naming it changed 29 of 1,462 English benchmark
/// outputs, and leaving it unnamed keeps the shipped English prompt byte for byte. A
/// language nobody measured gets today's behaviour rather than a guess.
///
/// Canonical text of record for the Polish instance:
/// `scripts/eval/prompts/eg1-polish-prompt-v2-named-language.txt`, pinned by a
/// golden-string test. Evidence: `docs/feature-requests/issue-3111-artifacts/`.
struct EGOneNamedLanguagePromptBuilder: PromptBuilder {
  init() {}

  /// The measured table, read from its one home so the pipeline's naming decision and
  /// this builder cannot disagree about which languages may be named.
  static var languageNames: [String: String] { EGOneNamedLanguages.names }

  /// The system prompt for an optional language code: the 1.2 prompt, plus the measured
  /// sentence when the code is in `languageNames`.
  static func systemPrompt(namedLanguage: String?) -> String {
    guard let namedLanguage, let name = languageNames[namedLanguage] else {
      return EGOneEnvelopePromptBuilder.systemPrompt
    }
    return EGOneEnvelopePromptBuilder.systemPrompt
      + " The transcript is in \(name); write the cleaned text in \(name)."
  }

  func build(input: PromptBuildInput, mode: PolishMode) -> PromptEnvelope {
    // `mode` is intentionally unused: EG-1's formatting behavior is in the weights.
    _ = mode

    return PromptEnvelope(messages: [
      PromptMessage(role: .system, content: Self.systemPrompt(namedLanguage: input.namedLanguage)),
      PromptMessage(
        role: .user, content: EGOneEnvelopePromptBuilder.userMessage(for: input.transcript)),
    ])
  }
}

/// The languages measured on EG-1 1.2 with the named-language sentence, and the English
/// names the sentence uses (#3111). Closed on purpose: this table IS the allowlist. Its own
/// `package` type because the pipeline's naming decision reads it from another module while
/// the builder stays internal like every other `PromptBuilder`.
package enum EGOneNamedLanguages {
  package static let names: [String: String] = [
    "pl": "Polish",
    "de": "German",
    "fr": "French",
    "es": "Spanish",
    "it": "Italian",
    "pt": "Portuguese",
    "nl": "Dutch",
    "cs": "Czech",
    "sk": "Slovak",
    "sv": "Swedish",
    "da": "Danish",
    "ru": "Russian",
    "uk": "Ukrainian",
    "ro": "Romanian",
    "hu": "Hungarian",
    "ja": "Japanese",
    "zh": "Chinese",
  ]
}
