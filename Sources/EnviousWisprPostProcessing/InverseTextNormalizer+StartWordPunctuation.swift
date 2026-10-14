import EnviousWisprCore
import Foundation

/// What `applyStartWordPunctuation` produced: the text, and how many commands it rewrote.
///
/// The count is returned because the caller needs it for telemetry and cannot recover it by diffing: a
/// take can change for other reasons, and an unchanged take can still have run the pass.
package struct SpokenPunctuationResult: Sendable, Equatable {
  package let text: String
  package let rulesFired: Int
  /// #3737: the text ENDS with a full stop the user said: the last MARK command was a period, and only
  /// whitespace and line or paragraph break commands follow it. Casual mode keeps that full stop.
  package let spokenFinalFullStop: Bool

  package init(text: String, rulesFired: Int, spokenFinalFullStop: Bool = false) {
    self.text = text
    self.rulesFired = rulesFired
    self.spokenFinalFullStop = spokenFinalFullStop
  }
}

extension InverseTextNormalizer {

  /// #2450: spoken punctuation for `de`, `fr`, `es` and `it`, behind a START WORD.
  ///
  /// "Diktiere Punkt" becomes `.`; "Punkt" on its own is a noun and is left alone. Returns the input
  /// byte for byte when the language has no table or nothing matches.
  ///
  /// An EMPTY `startWord` is the user's choice of no start word: the command forms are then matched
  /// bare, like English, so "Punkt" alone becomes `.` wherever it is said, inside a normal sentence
  /// too. Everything else (marks, breaks, capitalisation) behaves the same.
  ///
  /// - Parameters:
  ///   - language: the RESOLVED dictation language (`de`, `de-DE`, ...). No detection happens here.
  ///   - startWord: the language's effective start word, already validated by
  ///     `SpokenPunctuationStartWord.validate` (a decomposed spelling is re-normalised to NFC here).
  ///   - protectedSentinels: the exact opaque tokens a fired snippet left in the text. The pass never
  ///     edits one. Required, no default: a caller that forgot it would silently let the capitalisation
  ///     below touch a sentinel and corrupt the expansion that replaces it.
  ///
  /// What a match is, each point pinned by `MultilingualSpokenPunctuationTests`:
  /// - `\b` + start word + horizontal whitespace + a command form + `\b`, case-insensitive. A command
  ///   form's internal spaces accept runs of horizontal whitespace; its apostrophe accepts `'` and `’`.
  /// - Horizontal whitespace only (space, tab, no-break space), **never a line break**: a start word
  ///   split from its command by a newline is not a command, and the leading whitespace the match eats
  ///   can never swallow a line break a previous command just produced.
  /// - The whitespace BEFORE the start word is consumed, so a mark lands tight against the previous
  ///   word. For a line or paragraph break the whitespace AFTER is consumed too, so no line begins
  ///   with a stray space.
  /// - One `.` or `,` the recogniser attached directly after the command is consumed (the reporting
  ///   transcript shows `Punkt.` and `Neuer Absatz.`), but only when whitespace or the end follows,
  ///   so "Diktiere Punkt.com" keeps its dot.
  /// - Forms are tried LONGEST FIRST: non-English commands nest ("point d'interrogation" contains
  ///   "point"), and shortest-first would turn `Place point d'interrogation` into `. d'interrogation`.
  ///
  /// After a rewrite that produces `.`, `?`, `!`, a line break or a paragraph break, the first letter
  /// of the next word is uppercased (all four languages capitalise sentence starts), and only there:
  /// whitespace and opening punctuation (a quote, a bracket, Spanish `¿` `¡`) before the word are
  /// skipped. Other sentence starts are never touched. A protected sentinel is skipped.
  ///
  /// Canonically composed and decomposed spellings of a command form or start word both match. Text
  /// outside the matched commands keeps its original representation: the pass never normalises the
  /// transcript.
  package func applyStartWordPunctuation(
    _ text: String, language: String, startWord: String, protectedSentinels: [String]
  ) -> SpokenPunctuationResult {
    let unchanged = SpokenPunctuationResult(text: text, rulesFired: 0)
    guard let rules = SpokenPunctuationRules.startWordRules(for: language) else { return unchanged }
    let start = startWord.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping

    // #3738: symbols first, rendered by their own spacing, so a sentence capital pending from a later
    // mark command can land inside an opening bracket ("Diktiere Punkt Diktiere linke Klammer beta"
    // -> `. (Beta`), and so the legacy matcher below never sees a symbol command.
    let symbolPass = Self.applySymbolCommands(
      text, rules: rules, startWord: start, guardDeterminers: false)

    var ruleByKey: [String: SpokenPunctuationRule] = [:]
    var breakForms: [String] = []
    var markForms: [String] = []
    for rule in rules where rule.command.role != .symbol {
      let isBreak = rule.command == .lineBreak || rule.command == .paragraphBreak
      for form in rule.spokenForms {
        let normalized = form.precomposedStringWithCanonicalMapping
        ruleByKey[Self.formKey(normalized)] = rule
        if isBreak { breakForms.append(normalized) } else { markForms.append(normalized) }
      }
    }

    let pattern = Self.startWordPattern(start: start, breakForms: breakForms, markForms: markForms)
    // #3594: a command the engine wrote twice ("Diktiere Punkt. Diktiere Punkt.") is one command.
    let text = Self.mergeRepeatedCommand(
      in: symbolPass.text,
      forms: Self.alternation(breakForms + markForms),
      startWord: start.isEmpty ? "" : Self.literal(start))
    let matches = reMatches(pattern, text)
    guard !matches.isEmpty else {
      return symbolPass.fired == 0
        ? unchanged : SpokenPunctuationResult(text: text, rulesFired: symbolPass.fired)
    }

    let ns = text as NSString
    var out = ""
    var cursor = 0
    var pendingCapital = false
    var fired = symbolPass.fired
    // #3737: whether the last mark command was a period with nothing but whitespace and break commands
    // after it. Anything else that survives between or after (a mark the matcher did not consume, a
    // closer, a word) makes it false, so an untouched input dot is never attributed to a command.
    var finalFullStop = false

    for match in matches {
      let range = match.result.range
      let gap = ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
      out +=
        pendingCapital
        ? Self.capitalizing(gap, sentinels: protectedSentinels, pending: &pendingCapital) : gap
      cursor = range.location + range.length

      if gap.contains(where: { !$0.isWhitespace }) { finalFullStop = false }
      let form = match.g(1) ?? match.g(2) ?? ""
      guard let rule = ruleByKey[Self.formKey(form)] else {
        finalFullStop = false
        // The pattern is built from the same forms, so this is unreachable; keep the matched text
        // rather than drop it if that ever stops being true.
        out += ns.substring(with: range)
        pendingCapital = false
        continue
      }
      // A recogniser that heard a question or a sentence end before the command may already have
      // written a mark on the word before the start word ("Wie geht es dir? Diktiere Fragezeichen",
      // measured with Parakeet v3 on spoken German, Spanish, Italian and French). The command writes the
      // mark the user asked for, so that mark is dropped (#2450 dropped only an IDENTICAL one; #3594
      // drops a different sentence mark too, because a mark command right behind it makes the two a
      // collision whoever wrote the first: measured on Parakeet and WhisperKit in four languages). Kept:
      // a protected dot ("z.B. Diktiere Komma", "1. Diktiere Komma"), an ellipsis, a `?!` run, and
      // anything in front of a break command. Never the mark the previous command wrote: after a
      // directly adjacent command the gap is empty and `out` ends with that replacement, so
      // consecutive commands still stack.
      // Between two commands a gap of only whitespace and closing quotes or brackets holds nothing the
      // engine wrote: the mark in front of it is the previous command's own and is never dropped.
      if fired == 0 || firstMatch(#"^[\s\x{201D}\x{2019}"')\]}\x{00BB}]*$"#, gap) == nil {
        Self.dropRecogniserMark(
          &out, before: rule, startWord: start, language: language,
          protectedSentinels: protectedSentinels)
      }
      out += rule.replacement
      fired += 1
      switch rule.command {
      case .period: finalFullStop = true
      case .lineBreak, .paragraphBreak: break
      case .comma, .questionMark, .exclamationMark, .colon, .semicolon: finalFullStop = false
      // #3738: symbols never reach this matcher (filtered out of its forms above; the symbol pass
      // renders them first). Listed so a new command is a compile error here, not a silent default.
      case .openParenthesis, .closeParenthesis, .openSquareBracket, .closeSquareBracket,
        .openBrace, .closeBrace, .openAngleBracket, .closeAngleBracket, .openQuote, .closeQuote,
        .openSingleQuote, .closeSingleQuote, .hyphen, .underscore, .apostrophe, .emDash, .enDash,
        .ellipsis, .ampersand, .plusSign, .equalsSign, .verticalBar, .asterisk, .hashSign, .tilde:
        break
      }
      switch rule.command {
      case .period, .questionMark, .exclamationMark, .lineBreak, .paragraphBreak:
        pendingCapital = true
      case .comma, .colon, .semicolon:
        pendingCapital = false
      case .openParenthesis, .closeParenthesis, .openSquareBracket, .closeSquareBracket,
        .openBrace, .closeBrace, .openAngleBracket, .closeAngleBracket, .openQuote, .closeQuote,
        .openSingleQuote, .closeSingleQuote, .hyphen, .underscore, .apostrophe, .emDash, .enDash,
        .ellipsis, .ampersand, .plusSign, .equalsSign, .verticalBar, .asterisk, .hashSign, .tilde:
        break
      }
    }

    let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
    out +=
      pendingCapital
      ? Self.capitalizing(tail, sentinels: protectedSentinels, pending: &pendingCapital) : tail
    if tail.contains(where: { !$0.isWhitespace }) { finalFullStop = false }
    return SpokenPunctuationResult(
      text: out, rulesFired: fired, spokenFinalFullStop: finalFullStop)
  }

  /// #3624: whether `text` holds at least one COMPLETE start-word command of `language`: the start
  /// word, then one of that language's command forms, by the same pattern `applyStartWordPunctuation`
  /// matches. Read-only: used to decide a take's routing language before the pass runs. An empty
  /// `startWord` (the user's bare-commands choice) answers false, because a bare command word is not
  /// evidence of a command.
  package static func hasStartWordCommand(
    in text: String, language: String, startWord: String
  ) -> Bool {
    let start = startWord.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard !start.isEmpty, let rules = SpokenPunctuationRules.startWordRules(for: language) else {
      return false
    }
    var breakForms: [String] = []
    var markForms: [String] = []
    // Every command counts as evidence for routing, symbols included (#3738).
    for rule in rules {
      let isBreak = rule.command == .lineBreak || rule.command == .paragraphBreak
      for form in rule.spokenForms {
        let normalized = form.precomposedStringWithCanonicalMapping
        if isBreak { breakForms.append(normalized) } else { markForms.append(normalized) }
      }
    }
    let pattern = startWordPattern(start: start, breakForms: breakForms, markForms: markForms)
    return firstMatch(pattern, text) != nil
  }

  // MARK: - Pattern

  private static let horizontalSpace = #"[ \t\x{00A0}]"#

  private static func startWordPattern(start: String, breakForms: [String], markForms: [String])
    -> String
  {
    let ws = horizontalSpace
    // One recogniser mark attached after the command is absorbed: a dot, comma, question or
    // exclamation mark, or a French-spaced `?` or `!` (measured with Parakeet v3 on spoken French:
    // "point d'interrogation ?"). It must be followed by whitespace or the end, so a mark glued to
    // the next word is kept.
    let trailingMark = #"(?:(?:[.,!?]|[ \t\x{00A0}\x{202F}][!?])(?=\s|$))?"#
    let breaks = alternation(breakForms)
    let marks = alternation(markForms)
    // A pause can split the start word from its command and leave a mark between them
    // ("Diktiere. Punkt", "Place, virgule"); one `.` or `,` there is part of the command (#3594).
    let lead = start.isEmpty ? "" : literal(start) + "[.,]?" + ws + "+"
    return ws + #"*\b"# + lead + "(?:(" + breaks + #")\b"# + trailingMark + ws
      + "*|(" + marks + #")\b"# + trailingMark + ")"
  }

  /// Longest form first; `(?!)` (never matches) for an empty set so the group numbering stays fixed.
  static func alternation(_ forms: [String]) -> String {
    guard !forms.isEmpty else { return "(?!)" }
    return forms.sorted { $0.count > $1.count }.map(literal).joined(separator: "|")
  }

  /// A literal as a regex: metacharacters escaped, runs of spaces accept runs of horizontal
  /// whitespace, and an apostrophe accepts the typographic one the engine may write instead.
  static func literal(_ text: String) -> String {
    var pattern = ""
    var previousWasSpace = false
    for character in text {
      if character == " " {
        if !previousWasSpace { pattern += horizontalSpace + "+" }
        previousWasSpace = true
        continue
      }
      previousWasSpace = false
      if character == "'" {
        pattern += #"['\x{2019}]"#
      } else {
        // Match both canonical spellings of an accented letter, so decomposed text is not a missed
        // command, without normalising the surrounding transcript.
        let composed = String(character).precomposedStringWithCanonicalMapping
        let decomposed = composed.decomposedStringWithCanonicalMapping
        let escaped = NSRegularExpression.escapedPattern(for: composed)
        if Array(composed.unicodeScalars) == Array(decomposed.unicodeScalars) {
          pattern += escaped
        } else {
          pattern += "(?:" + escaped + "|" + NSRegularExpression.escapedPattern(for: decomposed) + ")"
        }
      }
    }
    return pattern
  }

  /// The lookup key of a form or of the text that matched it: lowercase, whitespace runs collapsed to
  /// one space, typographic apostrophe folded to the plain one.
  static func formKey(_ text: String) -> String {
    var key = ""
    var previousWasSpace = false
    for character in text.precomposedStringWithCanonicalMapping.lowercased() {
      if character == " " || character == "\t" || character == "\u{00A0}" {
        if !previousWasSpace { key.append(" ") }
        previousWasSpace = true
      } else {
        previousWasSpace = false
        key.append(character == "\u{2019}" ? "'" : character)
      }
    }
    return key
  }

  // MARK: - Capitalisation

  /// Uppercase the first letter of `gap` when it is the start of the word after a rewrite.
  /// Whitespace and opening punctuation before the word are skipped. `pending` stays true only while
  /// the gap holds nothing but those, because the word has not started yet; any other first
  /// character settles it, capitalised or not.
  private static func capitalizing(_ gap: String, sentinels: [String], pending: inout Bool)
    -> String
  {
    var index = gap.startIndex
    while index < gap.endIndex, isWhitespaceOrOpening(gap[index]) {
      index = gap.index(after: index)
    }
    if index == gap.endIndex { return gap }
    pending = false
    let rest = gap[index...]
    if sentinels.contains(where: { !$0.isEmpty && rest.hasPrefix($0) }) { return gap }
    let character = gap[index]
    guard character.isLowercase else { return gap }
    return String(gap[..<index]) + String(character).uppercased()
      + String(gap[gap.index(after: index)...])
  }

  /// Whitespace, or a character that opens a quotation or a bracket (`"`, `'`, `«`, `(`, `¿`, `¡`).
  private static func isWhitespaceOrOpening(_ character: Character) -> Bool {
    if character.isWhitespace || character == "\"" || character == "'" { return true }
    if character == "\u{00BF}" || character == "\u{00A1}" { return true }
    return character.unicodeScalars.allSatisfy {
      $0.properties.generalCategory == .openPunctuation
        || $0.properties.generalCategory == .initialPunctuation
    }
  }
}
