import Foundation

/// #2450: the spoken-punctuation command grammar, per language.
///
/// **Sole owner of "which spoken phrase becomes which mark".** Before this file the
/// answer lived in three hand-maintained places — the regex table inside
/// `InverseTextNormalizer`, `SpokenPunctuationCopy.phrases` in AppKit, and a third
/// copy inside `SpokenPunctuationToggleTests`. The help panel and the tests now RENDER
/// and GENERATE from here, so there is nothing left to keep in step by hand.
///
/// ## English and everything else are deliberately different
///
/// **English keeps BARE words** — "period" becomes "." with nothing in front of it —
/// because that is what shipped in #1794 and what 37 users switched on expecting. Its
/// nine patterns are carried here VERBATIM from the table they came from; they are not
/// regenerated, because two of them use `\b` where the rest use `\s+` and that
/// difference is behaviour, not style.
///
/// **Every other language requires a START WORD.** "Punkt" is an ordinary German noun;
/// "Setze Punkt" is a command. This is the FluidVoice design (their setting is
/// `PunctuationDictionaryPrefix`, default "literal"; their own copy says a start word
/// is how you "safely" insert punctuation), and it is why this file carries no
/// determiner lists, no idiom lists and no contextual guard policy. There is no
/// ambiguous case left to classify — a false positive is not made unlikely, it is made
/// unrepresentable.
///
/// That distinction is what lets #2450 exist at all. #1367 shelved the general
/// deterministic command layer after measuring 43.9% false-positive corruption on real
/// text, and named "content words can trigger it" as one of two causes. A start word
/// removes that cause by construction, so #1367's number does not transfer to this
/// design. Its other cause — recogniser punctuation colliding with ours — is a
/// disclosed product trade: this feature is for dictating with AI polish off, and the
/// help copy says so.
///
/// ## Provenance of the non-English rows
///
/// Read off Apple's own `DictationTranscriber` behaviour, not authored: 83 synthesised
/// clips across five languages, one candidate phrase per clip inside a carrier
/// sentence. Rows that Apple did not convert are marked so at the row. Full tables and
/// receipts: issue #2450.
package enum SpokenPunctuationCommand: String, Sendable, CaseIterable {
  case period, comma, questionMark, exclamationMark
  case colon, semicolon, lineBreak, paragraphBreak
}

/// One command, its spoken forms in one language, and the regex that recognises them.
package struct SpokenPunctuationRule: Sendable {
  package let command: SpokenPunctuationCommand
  /// Display forms, in the order the help panel should show them.
  package let spokenForms: [String]
  /// The compiled-on-use pattern. Held explicitly rather than derived at match time so
  /// English can carry its shipped patterns verbatim while other languages carry
  /// generated start-word patterns.
  package let pattern: String
  package let replacement: String
  /// What the help panel prints in its "you get" column. Not the replacement: a line
  /// break cannot be rendered meaningfully in a table cell.
  package let displayResult: String
}

/// One row of the in-app help panel.
package struct SpokenPunctuationPhrase: Identifiable, Equatable, Sendable {
  package let spoken: String
  package let result: String
  package var id: String { spoken }
}

package enum SpokenPunctuationRules {

  // MARK: - Public surface

  /// Languages with a table, in the order the help panel lists them under Auto.
  package static let supportedLanguages = ["en", "de", "fr", "es", "it"]

  /// The rules for a language, or `nil` when we have none.
  ///
  /// **`nil`, never an empty array.** The caller must be able to tell "we do not
  /// support this language" from "we support it and nothing matched"; collapsing the
  /// two is how a positively-identified Dutch take would silently receive the English
  /// table.
  package static func table(for language: String) -> [SpokenPunctuationRule]? {
    switch normalized(language) {
    case "en": return english
    case "de": return german
    case "fr": return french
    case "es": return spanish
    case "it": return italian
    default: return nil
    }
  }

  /// The word a user must say before a command in this language, or `nil` when the
  /// language uses bare commands. Only English is bare.
  package static func startWord(for language: String) -> String? {
    switch normalized(language) {
    case "en": return nil
    case "de": return "setze"
    case "fr": return "insère"
    case "es": return "pon"
    case "it": return "metti"
    default: return nil
    }
  }

  /// The help panel's rows for a language: every spoken form, paired with what it
  /// produces, in table order. Empty for a language we do not support.
  package static func phrases(for language: String) -> [SpokenPunctuationPhrase] {
    guard let rules = table(for: language) else { return [] }
    return rules.flatMap { rule in
      rule.spokenForms.map {
        SpokenPunctuationPhrase(spoken: $0, result: rule.displayResult)
      }
    }
  }

  // MARK: - Language tables

  /// **Verbatim from the shipped table (#1794), and it must stay verbatim.**
  /// Nine rules, TEN phrases: `exclamation (mark|point)` yields two. Two rules anchor
  /// with `\b` and the rest with `\s+`; that asymmetry is shipped behaviour and is not
  /// tidied here. Matching is case-INSENSITIVE, so "Period" at a sentence start
  /// converts too.
  ///
  /// Spoken symbol words in CONTEXTUAL conversions (email at/dot, URL dot/slash,
  /// numeric slash, percent, decimal dot) are NOT here and are never gated.
  private static let english: [SpokenPunctuationRule] = [
    .init(
      command: .paragraphBreak, spokenForms: ["new paragraph"],
      pattern: #"\bnew paragraph\b"#, replacement: "\n\n", displayResult: "a blank line"),
    .init(
      command: .lineBreak, spokenForms: ["new line"],
      pattern: #"\bnew line\b"#, replacement: "\n", displayResult: "a line break"),
    .init(
      command: .comma, spokenForms: ["comma"],
      pattern: #"\s+comma\b"#, replacement: ",", displayResult: ","),
    .init(
      command: .period, spokenForms: ["period"],
      pattern: #"\s+period\b"#, replacement: ".", displayResult: "."),
    .init(
      command: .period, spokenForms: ["full stop"],
      pattern: #"\s+full stop\b"#, replacement: ".", displayResult: "."),
    .init(
      command: .questionMark, spokenForms: ["question mark"],
      pattern: #"\s+question mark\b"#, replacement: "?", displayResult: "?"),
    .init(
      command: .exclamationMark, spokenForms: ["exclamation mark", "exclamation point"],
      pattern: #"\s+exclamation (mark|point)\b"#, replacement: "!", displayResult: "!"),
    .init(
      command: .colon, spokenForms: ["colon"],
      pattern: #"\s+colon\b"#, replacement: ":", displayResult: ":"),
    .init(
      command: .semicolon, spokenForms: ["semicolon"],
      pattern: #"\s+semicolon\b"#, replacement: ";", displayResult: ";"),
  ]

  /// German. `Neuabsatz` is in the table because it is what the reporting user actually
  /// said; a textbook-authored list would have carried only `neuer Absatz`. Apple
  /// converts both. `Strichpunkt` and `Semikolon` both convert.
  private static let german = startWordTable(
    startWord: "setze",
    [
      (.paragraphBreak, ["neuer Absatz", "Neuabsatz"], "\n\n", "a blank line"),
      (.lineBreak, ["neue Zeile"], "\n", "a line break"),
      (.questionMark, ["Fragezeichen"], "?", "?"),
      (.exclamationMark, ["Ausrufezeichen"], "!", "!"),
      (.colon, ["Doppelpunkt"], ":", ":"),
      (.semicolon, ["Semikolon", "Strichpunkt"], ";", ";"),
      (.comma, ["Komma"], ",", ","),
      (.period, ["Punkt"], ".", "."),
    ])

  /// French. **`nouveau paragraphe` is AUTHORED, not measured** — Apple converts both
  /// French line-break forms and no paragraph form across eight candidates tested, so
  /// there was nothing to read off. It is included because French speakers say it and,
  /// behind a start word, an unrecognised command costs nothing. Marked so the next
  /// reader does not mistake it for measured evidence.
  private static let french = startWordTable(
    startWord: "insère",
    [
      (.paragraphBreak, ["nouveau paragraphe"], "\n\n", "a blank line"),
      (.lineBreak, ["nouvelle ligne", "à la ligne"], "\n", "a line break"),
      (.questionMark, ["point d'interrogation"], "?", "?"),
      (.exclamationMark, ["point d'exclamation"], "!", "!"),
      (.semicolon, ["point-virgule"], ";", ";"),
      (.colon, ["deux points"], ":", ":"),
      (.comma, ["virgule"], ",", ","),
      (.period, ["point"], ".", "."),
    ])

  /// Spanish. Apple emits only the CLOSING `?` and `!`, never the opening `¿` `¡`, so
  /// neither does this table. The start word is `pon` rather than `signo`, which is
  /// already the head of `signo de interrogación`.
  private static let spanish = startWordTable(
    startWord: "pon",
    [
      (.paragraphBreak, ["nuevo párrafo"], "\n\n", "a blank line"),
      (.lineBreak, ["nueva línea"], "\n", "a line break"),
      (.questionMark, ["signo de interrogación"], "?", "?"),
      (.exclamationMark, ["signo de exclamación"], "!", "!"),
      (.semicolon, ["punto y coma"], ";", ";"),
      (.colon, ["dos puntos"], ":", ":"),
      (.comma, ["coma"], ",", ","),
      (.period, ["punto"], ".", "."),
    ])

  /// Italian.
  private static let italian = startWordTable(
    startWord: "metti",
    [
      (.paragraphBreak, ["nuovo paragrafo"], "\n\n", "a blank line"),
      (.lineBreak, ["nuova riga"], "\n", "a line break"),
      (.questionMark, ["punto interrogativo"], "?", "?"),
      (.exclamationMark, ["punto esclamativo"], "!", "!"),
      (.semicolon, ["punto e virgola"], ";", ";"),
      (.colon, ["due punti"], ":", ":"),
      (.comma, ["virgola"], ",", ","),
      (.period, ["punto"], ".", "."),
    ])

  // MARK: - Pattern construction

  /// Build a start-word table, **sorted longest spoken form first.**
  ///
  /// **The ordering is correctness, not tidiness.** Non-English commands NEST where
  /// English's do not: `point d'interrogation` contains `point`, `punto e virgola`
  /// contains both `punto` and `virgola`, `dos puntos` contains `puntos`. A
  /// shortest-first pass turns "insère point d'interrogation" into ". d'interrogation"
  /// and destroys the command it was asked to honour. English never exposed this
  /// because "question mark" does not contain "period".
  private static func startWordTable(
    startWord: String,
    _ rows: [(SpokenPunctuationCommand, [String], String, String)]
  ) -> [SpokenPunctuationRule] {
    rows
      .map { command, forms, replacement, display in
        // Longest form first WITHIN a rule too, for the same reason.
        let ordered = forms.sorted { $0.count > $1.count }
        return SpokenPunctuationRule(
          command: command, spokenForms: forms,
          pattern: pattern(startWord: startWord, forms: ordered),
          replacement: replacement, displayResult: display)
      }
      .sorted {
        ($0.spokenForms.map(\.count).max() ?? 0) > ($1.spokenForms.map(\.count).max() ?? 0)
      }
  }

  /// `<boundary> startWord <space> (form|form) <boundary>`, consuming the whitespace
  /// before the start word so the mark lands tight against the preceding word.
  ///
  /// **Boundaries are explicit Unicode lookarounds, NOT `\b`.** `reSub` compiles
  /// without `.useUnicodeWordBoundaries`, so `\b` treats `ß`, `ä` and `é` as non-word
  /// characters — `\bpunkt\b` would match INSIDE `Fußpunkt`. `(?<![\p{L}\p{N}_])` is
  /// correct for every language here and needs no change to the shared helper.
  private static func pattern(startWord: String, forms: [String]) -> String {
    let alternation = forms.map { escape($0) }.joined(separator: "|")
    return #"(?:\s+|^)"# + escape(startWord) + #"\s+(?:"# + alternation
      + #")(?![\p{L}\p{N}_])"#
  }

  /// Escape regex metacharacters in a spoken form. Apostrophes and accents are literal
  /// and need no escaping; hyphens do outside a character class only in some flavours,
  /// so they are escaped for safety.
  private static func escape(_ s: String) -> String {
    NSRegularExpression.escapedPattern(for: s)
  }

  /// Accept `de`, `de-DE`, `de_DE` and any casing. Mirrors how the pipeline's language
  /// gate reads a code, so a locale-shaped value from the resolver still finds a table.
  private static func normalized(_ language: String) -> String {
    let lowered = language.lowercased()
    guard let separator = lowered.firstIndex(where: { $0 == "-" || $0 == "_" }) else {
      return lowered
    }
    return String(lowered[lowered.startIndex..<separator])
  }
}
