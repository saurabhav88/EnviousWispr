import Foundation

/// #2450: the spoken-punctuation command grammar for the four languages that need a start word.
///
/// **Lives in Core, not beside the matcher.** The settings store (`EnviousWisprServices`) has to validate
/// a persisted start word against these forms when it loads, and it sits below PostProcessing in the
/// target graph, so the tables are shared data in the lowest module every consumer can see, the same
/// reason `LanguageNormalizer` is here. Matching and transformation stay in PostProcessing
/// (`applyStartWordPunctuation`). Moved from PostProcessing in the same change that introduced it
/// (founder-approved placement correction, 2026-10-04).
///
/// **Sole owner of "which spoken phrase becomes which mark" for `de`, `fr`, `es` and `it`, and of each
/// language's default start word.** English is deliberately NOT here: it keeps its bare-word table,
/// `InverseTextNormalizer.punct`, byte for byte, with its own toggle position and default.
///
/// ## Why a start word
///
/// "Punkt" is an ordinary German noun; "Diktiere Punkt" is a command. Behind a start word an ordinary use of
/// a command word cannot become a mark, which is the failure a bare-word table has (#1367 measured 43.9%
/// corruption on real text for bare words). The start word is a user setting (`SpokenPunctuationSettings`)
/// with the defaults below; this file supplies only the DEFAULT and the forms.
///
/// ## Provenance of the rows
///
/// Ported from the parked branch `feat/2450-multilingual-spoken-punctuation` (`6478236f`), whose rows
/// were read off Apple's own dictation behaviour on synthesised clips (83 clips, two rounds, 2026-08-26;
/// recorded on #2450). They have NOT been re-measured for this change. Rows that were authored rather
/// than measured are marked at the row. Only the tables are ported: the branch's English half, matcher
/// and ownership claims are not.
package enum SpokenPunctuationCommand: String, Sendable, CaseIterable {
  case period, comma, questionMark, exclamationMark
  case colon, semicolon, lineBreak, paragraphBreak
}

/// One command and its spoken forms in one language.
package struct SpokenPunctuationRule: Sendable, Equatable {
  package let command: SpokenPunctuationCommand
  /// Display order. Matching is longest-first and does not depend on this order.
  package let spokenForms: [String]
  /// What the command inserts. A line break is `"\n"` and a paragraph break `"\n\n"`.
  package let replacement: String

  package init(command: SpokenPunctuationCommand, spokenForms: [String], replacement: String) {
    self.command = command
    self.spokenForms = spokenForms
    self.replacement = replacement
  }
}

package enum SpokenPunctuationRules {

  /// Languages that have a table, in help-article order.
  package static let supportedLanguages = ["de", "fr", "es", "it"]

  /// The rules for a language, or `nil` when there is no table for it.
  ///
  /// **`nil`, never an empty array, and never English.** A caller must be able to tell "unsupported
  /// language" from "supported and nothing matched"; collapsing the two is how a positively identified
  /// Dutch take would silently receive another language's table. Accepts `de`, `de-DE`, `de_DE`, any case.
  package static func rules(for language: String) -> [SpokenPunctuationRule]? {
    switch baseCode(language) {
    case "de": return german
    case "fr": return french
    case "es": return spanish
    case "it": return italian
    default: return nil
    }
  }

  /// The default start word, or `nil` for a language with no table (English included).
  ///
  /// Defaults are a public contract: once shipped they are never silently changed, because a user who
  /// never customised would find their command vocabulary different after an update (plan 3.1).
  /// Chosen for how the shipping recogniser writes them: 144 Azure Neural clips (2 voices, 2 sentences, 4 per
  /// word) through the real Parakeet v3 runner on 2026-10-05 (#2450). The first candidates "Setze", "Insère"
  /// and "Pon" were heard 0, 0 and 1 times in 4 ("Sätze", "un serre", "con"); "Diktiere", "Place" and
  /// "Añade" were each heard 4 of 4, and "Metti" stayed 4 of 4. A small synthetic sample, not human
  /// speech. Spanish avoids "signo", which already heads "signo de interrogación".
  package static func defaultStartWord(for language: String) -> String? {
    switch baseCode(language) {
    case "de": return "Diktiere"
    case "fr": return "Place"
    case "es": return "Añade"
    case "it": return "Metti"
    default: return nil
    }
  }

  /// The start word in force for each supported language: the override when there is one, else the
  /// default. An override of `""` means the user chose NO start word and is returned as `""`. The
  /// single place that derives it, used by every consumer that needs the whole set
  /// (recovery capture, file import freeze, the cleanup step, the Settings row). An override for an
  /// unsupported language is ignored.
  package static func effectiveStartWords(overrides: [String: String]) -> [String: String] {
    var words: [String: String] = [:]
    for language in supportedLanguages {
      words[language] = overrides[language] ?? defaultStartWord(for: language)
    }
    return words
  }

  /// Validate a language-keyed map of start words: the one rule both the persisted settings loader and
  /// the recovery snapshot reader use, so neither carries its own copy.
  ///
  /// Each entry stands alone. A key that is not a supported language, and a word that is
  /// malformed, over-long or colliding with a command form, are dropped without touching the others.
  /// A BLANK value is kept as the empty string: it is the user's choice of NO start word for that
  /// language (command words then work bare, as English does), and it is never the language default.
  /// Keys are normalised to the base code (`de-DE` becomes `de`) and processed in sorted order so two
  /// keys that normalise alike resolve the same way every run. Accepted words are trimmed and NFC.
  ///
  /// - Parameter dropDefaults: `true` for the settings store, which is SPARSE (a word equal to the
  ///   language's default, ignoring case, is "not customised" and is dropped). `false` for a
  ///   recovery or import snapshot, which records the EFFECTIVE word per language and must keep it
  ///   even when it equals today's default, so a later change of default cannot alter a replay.
  package static func validatedStartWords(_ raw: [String: String], dropDefaults: Bool)
    -> [String: String]
  {
    var result: [String: String] = [:]
    for key in raw.keys.sorted() {
      guard let value = raw[key],
        let code = LanguageNormalizer.baseCode(key),
        let forms = spokenForms(for: code)
      else { continue }
      if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        result[code] = ""
        continue
      }
      guard
        case .accepted(let word) = SpokenPunctuationStartWord.validate(
          value, language: code, spokenForms: forms)
      else { continue }
      if dropDefaults, let defaultWord = defaultStartWord(for: code),
        word.lowercased() == defaultWord.lowercased()
      {
        continue
      }
      result[code] = word
    }
    return result
  }

  /// Every spoken form of a language, for start-word collision checks. `nil` when unsupported.
  package static func spokenForms(for language: String) -> [String]? {
    rules(for: language)?.flatMap(\.spokenForms)
  }

  // MARK: - Tables

  /// German. `Neuabsatz` is what the reporting user actually said (#2450 transcript), so it is in the
  /// table; a textbook list would carry only "neuer Absatz". `neuen Absatz` is AUTHORED, not measured:
  /// it is the natural accusative after an imperative ("Diktiere neuen Absatz"), and behind a start word an
  /// unrecognised form costs nothing. `Strichpunkt` and `Semikolon` both convert in Apple's model.
  private static let german: [SpokenPunctuationRule] = [
    .init(
      command: .paragraphBreak, spokenForms: ["neuer Absatz", "neuen Absatz", "Neuabsatz"],
      replacement: "\n\n"),
    .init(command: .lineBreak, spokenForms: ["neue Zeile"], replacement: "\n"),
    .init(command: .questionMark, spokenForms: ["Fragezeichen"], replacement: "?"),
    .init(command: .exclamationMark, spokenForms: ["Ausrufezeichen"], replacement: "!"),
    .init(command: .colon, spokenForms: ["Doppelpunkt"], replacement: ":"),
    .init(command: .semicolon, spokenForms: ["Semikolon", "Strichpunkt"], replacement: ";"),
    .init(command: .comma, spokenForms: ["Komma"], replacement: ","),
    .init(command: .period, spokenForms: ["Punkt"], replacement: "."),
  ]

  /// French. **`nouveau paragraphe` is AUTHORED, not measured**: Apple converted both French line-break
  /// forms and no paragraph form across eight candidates, so there was nothing to read off. It is here
  /// because French speakers say it and an unrecognised command behind a start word costs nothing.
  private static let french: [SpokenPunctuationRule] = [
    .init(command: .paragraphBreak, spokenForms: ["nouveau paragraphe"], replacement: "\n\n"),
    .init(command: .lineBreak, spokenForms: ["nouvelle ligne", "à la ligne"], replacement: "\n"),
    .init(command: .questionMark, spokenForms: ["point d'interrogation"], replacement: "?"),
    .init(command: .exclamationMark, spokenForms: ["point d'exclamation"], replacement: "!"),
    .init(command: .semicolon, spokenForms: ["point-virgule"], replacement: ";"),
    .init(command: .colon, spokenForms: ["deux points"], replacement: ":"),
    .init(command: .comma, spokenForms: ["virgule"], replacement: ","),
    .init(command: .period, spokenForms: ["point"], replacement: "."),
  ]

  /// Spanish. Apple emits only the CLOSING `?` and `!`, never the opening `¿` `¡`, so neither does this
  /// table.
  private static let spanish: [SpokenPunctuationRule] = [
    .init(command: .paragraphBreak, spokenForms: ["nuevo párrafo"], replacement: "\n\n"),
    .init(command: .lineBreak, spokenForms: ["nueva línea"], replacement: "\n"),
    .init(command: .questionMark, spokenForms: ["signo de interrogación"], replacement: "?"),
    .init(command: .exclamationMark, spokenForms: ["signo de exclamación"], replacement: "!"),
    .init(command: .semicolon, spokenForms: ["punto y coma"], replacement: ";"),
    .init(command: .colon, spokenForms: ["dos puntos"], replacement: ":"),
    .init(command: .comma, spokenForms: ["coma"], replacement: ","),
    .init(command: .period, spokenForms: ["punto"], replacement: "."),
  ]

  /// Italian.
  private static let italian: [SpokenPunctuationRule] = [
    .init(command: .paragraphBreak, spokenForms: ["nuovo paragrafo"], replacement: "\n\n"),
    .init(command: .lineBreak, spokenForms: ["nuova riga"], replacement: "\n"),
    .init(command: .questionMark, spokenForms: ["punto interrogativo"], replacement: "?"),
    .init(command: .exclamationMark, spokenForms: ["punto esclamativo"], replacement: "!"),
    .init(command: .semicolon, spokenForms: ["punto e virgola"], replacement: ";"),
    .init(command: .colon, spokenForms: ["due punti"], replacement: ":"),
    .init(command: .comma, spokenForms: ["virgola"], replacement: ","),
    .init(command: .period, spokenForms: ["punto"], replacement: "."),
  ]

  /// `de`, `de-DE`, `de_DE` and any casing all name the same table.
  private static func baseCode(_ language: String) -> String {
    let lowered = language.lowercased()
    guard let separator = lowered.firstIndex(where: { $0 == "-" || $0 == "_" }) else {
      return lowered
    }
    return String(lowered[lowered.startIndex..<separator])
  }
}
