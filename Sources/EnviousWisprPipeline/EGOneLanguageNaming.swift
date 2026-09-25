import EnviousWisprCore
import EnviousWisprLLM

/// Whether EG-1 may be TOLD which language a dictation is in (#3111).
///
/// EG-1 1.2 sometimes translates non-English dictation into English. In the measured set,
/// naming the language reduced English outputs from 41/480 to 0/480. Naming the WRONG
/// language is worse than naming none: it translates the dictation INTO that language
/// (Polish labelled German came back German on 31 of 40 sentences). So a name is given
/// only on positive, agreeing evidence, and every doubt falls back to today's prompt.
///
/// Pure: every input is frozen in the context at resolution time, before any cleanup
/// step runs, so the answer is about what the recogniser WROTE rather than what cleanup
/// made of it.
package enum EGOneLanguageNaming {

  package enum Decision: Equatable, Sendable {
    /// Name this base code in the prompt.
    case named(String)
    /// Send today's prompt, for this reason.
    case notNamed(Reason)

    /// The code to put in `PromptBuildInput.namedLanguage`, or nil.
    package var namedLanguage: String? {
      if case .named(let code) = self { return code }
      return nil
    }
  }

  package enum Reason: String, Sendable {
    /// The text alone did not identify a language at the resolver's floor.
    case unsure
    /// The text is English. Never named: naming it changed 29 of 1,462 English
    /// benchmark outputs, and not naming it keeps the English prompt byte for byte.
    case english
    /// A lock or a detecting engine says a different language than the text.
    case conflict
    /// The text's language was never measured with the named prompt.
    case untested
  }

  /// - Parameters:
  ///   - textLanguage: `TextProcessingContext.textLanguage`, the raw ASR text's own answer.
  ///   - resolvedLanguage: `TextProcessingContext.language`.
  ///   - source: `TextProcessingContext.languageSource`, which rung answered it.
  package static func decide(
    textLanguage: String?,
    resolvedLanguage: String?,
    source: DictationLanguageResolver.Resolution.Source?
  ) -> Decision {
    guard let text = LanguageNormalizer.baseCode(textLanguage) else { return .notNamed(.unsure) }
    if text == "en" { return .notNamed(.english) }
    // A lock is intent and an engine answer can come from its first window only, so
    // either one disagreeing with the text is doubt, never a tie-break in its favour.
    switch source {
    case .locked, .engine:
      if LanguageNormalizer.baseCode(resolvedLanguage) != text { return .notNamed(.conflict) }
    // `.some(.none)`, not a bare `.none`: in a switch over an Optional a bare `.none`
    // is Optional's nil, and the resolver's own abstention case would go unmatched.
    case .dictation, .document, .some(.none), nil:
      break
    }
    guard EGOneNamedLanguages.names[text] != nil else { return .notNamed(.untested) }
    return .named(text)
  }
}
