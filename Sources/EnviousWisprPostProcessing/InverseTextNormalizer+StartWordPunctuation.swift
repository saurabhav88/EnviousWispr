import EnviousWisprCore
import Foundation

/// What `applyStartWordPunctuation` produced: the text, and how many commands it rewrote.
///
/// The count is returned because the caller needs it for telemetry and cannot recover it by diffing: a
/// take can change for other reasons, and an unchanged take can still have run the pass.
package struct SpokenPunctuationResult: Sendable, Equatable {
  package let text: String
  package let rulesFired: Int

  package init(text: String, rulesFired: Int) {
    self.text = text
    self.rulesFired = rulesFired
  }
}

extension InverseTextNormalizer {

  /// #2450: spoken punctuation for `de`, `fr`, `es` and `it`, behind a START WORD.
  ///
  /// "Setze Punkt" becomes `.`; "Punkt" on its own is a noun and is left alone. Returns the input
  /// byte for byte when the language has no table, the start word is empty, or nothing matches.
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
  ///   so "Setze Punkt.com" keeps its dot.
  /// - Forms are tried LONGEST FIRST: non-English commands nest ("point d'interrogation" contains
  ///   "point"), and shortest-first would turn `Insère point d'interrogation` into `. d'interrogation`.
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
    guard let rules = SpokenPunctuationRules.rules(for: language) else { return unchanged }
    let start = startWord.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard !start.isEmpty else { return unchanged }

    var ruleByKey: [String: SpokenPunctuationRule] = [:]
    var breakForms: [String] = []
    var markForms: [String] = []
    for rule in rules {
      let isBreak = rule.command == .lineBreak || rule.command == .paragraphBreak
      for form in rule.spokenForms {
        let normalized = form.precomposedStringWithCanonicalMapping
        ruleByKey[Self.formKey(normalized)] = rule
        if isBreak { breakForms.append(normalized) } else { markForms.append(normalized) }
      }
    }

    let pattern = Self.startWordPattern(start: start, breakForms: breakForms, markForms: markForms)
    let matches = reMatches(pattern, text)
    guard !matches.isEmpty else { return unchanged }

    let ns = text as NSString
    var out = ""
    var cursor = 0
    var pendingCapital = false
    var fired = 0

    for match in matches {
      let range = match.result.range
      let gap = ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
      out +=
        pendingCapital
        ? Self.capitalizing(gap, sentinels: protectedSentinels, pending: &pendingCapital) : gap
      cursor = range.location + range.length

      let form = match.g(1) ?? match.g(2) ?? ""
      guard let rule = ruleByKey[Self.formKey(form)] else {
        // The pattern is built from the same forms, so this is unreachable; keep the matched text
        // rather than drop it if that ever stops being true.
        out += ns.substring(with: range)
        pendingCapital = false
        continue
      }
      // A recogniser that heard a question or a sentence end before the command may already have
      // written the SAME mark on the word before the start word ("Wie geht es dir? Setze
      // Fragezeichen", measured with Parakeet v3 on spoken German, Spanish, Italian and French).
      // One mark is what the user asked for, so the duplicate is dropped. Only an IDENTICAL mark
      // is dropped, and only when it follows a letter or digit: a different mark ("z.B. Setze
      // Komma", "1. Setze Komma") is kept, because the pass cannot tell whether the recogniser or
      // the user wrote it. Never a break command, an ellipsis, a `?!` run, or the mark the
      // previous command wrote: after a directly adjacent command the gap is empty and `out` ends
      // with that replacement, so consecutive commands still stack.
      if rule.command != .lineBreak, rule.command != .paragraphBreak, fired == 0 || !gap.isEmpty {
        Self.dropDuplicateRecogniserMark(&out, duplicating: rule.replacement)
      }
      out += rule.replacement
      fired += 1
      switch rule.command {
      case .period, .questionMark, .exclamationMark, .lineBreak, .paragraphBreak:
        pendingCapital = true
      case .comma, .colon, .semicolon:
        pendingCapital = false
      }
    }

    let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
    out +=
      pendingCapital
      ? Self.capitalizing(tail, sentinels: protectedSentinels, pending: &pendingCapital) : tail
    return SpokenPunctuationResult(text: out, rulesFired: fired)
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
    return ws + #"*\b"# + literal(start) + ws + "+(?:(" + breaks + #")\b"# + trailingMark + ws
      + "*|(" + marks + #")\b"# + trailingMark + ")"
  }

  /// Longest form first; `(?!)` (never matches) for an empty set so the group numbering stays fixed.
  private static func alternation(_ forms: [String]) -> String {
    guard !forms.isEmpty else { return "(?!)" }
    return forms.sorted { $0.count > $1.count }.map(literal).joined(separator: "|")
  }

  /// A literal as a regex: metacharacters escaped, runs of spaces accept runs of horizontal
  /// whitespace, and an apostrophe accepts the typographic one the engine may write instead.
  private static func literal(_ text: String) -> String {
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
  private static func formKey(_ text: String) -> String {
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

  /// Remove ONE mark at the end of `out` that equals `replacement` (the single mark character the
  /// command is about to write), with the space French writes before `? ! : ;`, when it sits directly
  /// after a letter or digit. Anything else, including a different mark, an ellipsis and a `?!` run,
  /// is left alone.
  private static func dropDuplicateRecogniserMark(_ out: inout String, duplicating replacement: String) {
    guard replacement.count == 1, let mark = out.last, ".,!?;:".contains(mark),
      String(mark) == replacement
    else { return }
    var rest = Substring(out).dropLast()
    if "?!:;".contains(mark), let space = rest.last,
      space == " " || space == "\u{00A0}" || space == "\u{202F}"
    {
      rest = rest.dropLast()
    }
    guard let previous = rest.last, previous.isLetter || previous.isNumber else { return }
    out = String(rest)
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
