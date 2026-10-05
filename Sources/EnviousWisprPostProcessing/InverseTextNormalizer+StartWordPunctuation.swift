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
  /// of the next word is uppercased (all four languages capitalise sentence starts), and only there.
  /// Other sentence starts are never touched. A protected sentinel is skipped.
  ///
  /// Input is assumed NFC, which is what the engines emit. A decomposed (NFD) text does not match an
  /// accented command form: that is a MISSED command, never a corrupted word.
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
    let trailingMark = #"(?:[.,](?=\s|$))?"#
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
        pattern += NSRegularExpression.escapedPattern(for: String(character))
      }
    }
    return pattern
  }

  /// The lookup key of a form or of the text that matched it: lowercase, whitespace runs collapsed to
  /// one space, typographic apostrophe folded to the plain one.
  private static func formKey(_ text: String) -> String {
    var key = ""
    var previousWasSpace = false
    for character in text.lowercased() {
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
  /// `pending` stays true only while the gap is horizontal whitespace, because the word has not
  /// started yet; any other first character settles it, capitalised or not.
  private static func capitalizing(_ gap: String, sentinels: [String], pending: inout Bool)
    -> String
  {
    var index = gap.startIndex
    while index < gap.endIndex, isHorizontalSpace(gap[index]) {
      index = gap.index(after: index)
    }
    if index == gap.endIndex { return gap }
    pending = false
    let rest = gap[index...]
    if sentinels.contains(where: { !$0.isEmpty && rest.hasPrefix($0) }) { return gap }
    let character = gap[index]
    let upper = String(character).uppercased()
    // A letter whose uppercase form is longer than one character (ß becomes SS) is left as written.
    guard character.isLowercase, upper.count == 1 else { return gap }
    return String(gap[..<index]) + upper + String(gap[gap.index(after: index)...])
  }

  private static func isHorizontalSpace(_ character: Character) -> Bool {
    character == " " || character == "\t" || character == "\u{00A0}"
  }
}
