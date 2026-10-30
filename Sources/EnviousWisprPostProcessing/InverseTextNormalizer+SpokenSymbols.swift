import EnviousWisprCore
import Foundation

/// #3738: spoken symbols ("open paren", "underscore", "close quote") on both spoken-punctuation routes.
///
/// The one renderer for symbol spacing (`SpokenPunctuationCommand.spacing`). The legacy marks and breaks
/// keep their own matchers; this pass touches only commands whose role is `.symbol`, so it never
/// absorbs, merges or drops a sentence mark next to a symbol.
extension InverseTextNormalizer {

  /// Words that make the symbol name a NOUN being talked about rather than a command: "use an asterisk
  /// for the footnote", "type a dollar sign". Measured shape: every such sentence in the #3738 Parakeet
  /// run had one (`docs/audits/2026-10-14-3738-symbol-shapes/README.md`). Applied on the English
  /// bare-word route only; behind a start word the start word marks the command.
  static let symbolDeterminers: Set<String> = [
    "a", "an", "the", "this", "that", "each", "every", "my", "your", "our", "their", "his", "her",
    "its",
  ]

  /// Rewrite every complete symbol command in `text`.
  ///
  /// - Parameters:
  ///   - rules: the language's rules; only those whose role is `.symbol` are used.
  ///   - startWord: nil or empty for bare words (English default); otherwise the start word that must
  ///     come first ("Diktiere linke Klammer").
  ///   - guardDeterminers: leave a command preceded by one of `symbolDeterminers` as words.
  ///   - joinerGap: keep a `joinerGapCharacter`, instead of no space, between a symbol and a spoken
  ///     slash or backslash whose word boundary that symbol would break. True only where the joiner
  ///     pass runs after this one (English bare words, `applyPunct`), which removes every leftover gap.
  /// - Returns: the text and how many commands were rewritten.
  static func applySymbolCommands(
    _ text: String, rules: [SpokenPunctuationRule], startWord: String?, guardDeterminers: Bool,
    joinerGap: Bool
  ) -> (text: String, fired: Int) {
    let symbols = rules.filter { $0.command.role == .symbol && $0.command.spacing != nil }
    guard !symbols.isEmpty else { return (text, 0) }
    var ruleByKey: [String: SpokenPunctuationRule] = [:]
    var forms: [String] = []
    for rule in symbols {
      for form in rule.spokenForms {
        let normalized = form.precomposedStringWithCanonicalMapping
        ruleByKey[formKey(normalized)] = rule
        forms.append(normalized)
      }
    }
    let start = (startWord ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    let lead = start.isEmpty ? "" : literal(start) + #"[.,]?[ \t\x{00A0}]+"#
    // A command is a whole phrase: no letter, combining mark, digit, underscore or joining hyphen
    // directly before or after it, so "underscores", "re-tilde" and "tilde-based" are not commands.
    let pattern =
      #"(?<![\p{L}\p{M}\p{N}_-])"# + lead + "(" + alternation(forms)
      + #")(?![\p{L}\p{M}\p{N}_-])"#
    // A joining or opening symbol eats the space after it, unless a legacy command follows: removing
    // that space would glue "Insert comma" onto the symbol, where the legacy matcher's word boundary
    // can no longer see it ("Hello Insert underscore Insert comma").
    let legacyForms = alternation(
      rules.filter { $0.command.role != .symbol }.flatMap(\.spokenForms))
    func trimSymbolGap(_ value: String, after symbol: Character?) -> String {
      let legacy = #"\A[ \t\x{00A0}]*"# + lead + "(?:" + legacyForms + #")\b"#
      if firstMatch(legacy, value) != nil { return value }
      let rest = String(value.drop(while: isHorizontalSpace))
      // A spoken slash or backslash after a symbol its left boundary rejects ("<", "_") keeps a gap,
      // so the joiner pass still reads it: "open angle bracket backslash path" -> `<\path`.
      // No space test: an engine comma the symbol dropped may have been the only separator.
      if joinerGap, let symbol, !symbol.isWhitespace,
        !joinerLeftNeighbours.contains(symbol),
        firstMatch(Self.joinerWordAtStart, rest) != nil
      {
        return String(Self.joinerGapCharacter) + rest
      }
      return rest
    }
    // A closing or joining symbol right after a spoken slash or backslash keeps a gap for the same
    // reason: the joiner's right boundary rejects every symbol ("backslash close paren" -> `\)`).
    func gapBeforeClosing(_ before: String) -> String {
      joinerGap && firstMatch(Self.joinerWordAtEnd, before) != nil ? String(Self.joinerGapCharacter) : ""
    }
    let matches = reMatches(pattern, text)
    guard !matches.isEmpty else { return (text, 0) }

    let ns = text as NSString
    var out = ""
    var cursor = 0
    var skipLeadingSpace = false
    var absorbLeadingComma = false
    var lastWasSpaced = false
    // The previous rendered command was an opening symbol. A straight quote opens AND closes, so its
    // character alone cannot say which; the command can (`"+"` here, `"x" + "y"` after a closer).
    var lastOpened = false
    var fired = 0
    for match in matches {
      let range = match.result.range
      guard range.location >= cursor else { continue }
      var gap = ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
      if absorbLeadingComma { gap = droppingEngineComma(gap) }
      if skipLeadingSpace { gap = trimSymbolGap(gap, after: out.last) }
      skipLeadingSpace = false
      absorbLeadingComma = false
      let matched = ns.substring(with: range)
      guard let form = match.g(1), let rule = ruleByKey[formKey(form)],
        let spacing = rule.command.spacing
      else {
        out += gap + matched
        cursor = NSMaxRange(range)
        lastWasSpaced = false
        lastOpened = false
        continue
      }
      if guardDeterminers, symbolDeterminers.contains(lastWord(of: out + gap).lowercased()) {
        out += gap + matched
        cursor = NSMaxRange(range)
        lastWasSpaced = false
        lastOpened = false
        continue
      }
      out += gap
      let followsOpener = lastOpened && gap.allSatisfy(isHorizontalSpace)
      lastOpened = spacing == .opens
      lastWasSpaced = spacing == .spaced
      switch spacing {
      case .opens:
        out += rule.replacement
        skipLeadingSpace = true
        absorbLeadingComma = true
      case .closes:
        let before = trimmingEngineComma(out)
        out = before + gapBeforeClosing(before) + rule.replacement
      case .joins:
        let before = trimmingEngineComma(out)
        out = before + gapBeforeClosing(before) + rule.replacement
        skipLeadingSpace = true
        absorbLeadingComma = true
      case .spaced:
        // One space each side, none against a line break, the text's start or end, an opening
        // bracket or quote on the left, or sentence punctuation or a closer on the right. The
        // start-word route has no later tightening pass, so this spacing is final there (cloud
        // review PR #3755: "Set x Insert equals sign, then y" -> `Set x =, then y`).
        let left = trimmingTrailingSpace(out)
        let right = ns.substring(from: NSMaxRange(range)).drop(while: isHorizontalSpace)
        let leftSpace =
          left.isEmpty || left.last?.isNewline == true || followsOpener
            || left.last.map(Self.tightAfter.contains) == true ? "" : " "
        let rightSpace =
          right.isEmpty || right.first?.isNewline == true
            || right.first.map(Self.tightBefore.contains) == true ? "" : " "
        out = left + leftSpace + rule.replacement + rightSpace
        skipLeadingSpace = true
      }
      fired += 1
      cursor = NSMaxRange(range)
    }
    var tail = ns.substring(from: cursor)
    if absorbLeadingComma { tail = droppingEngineComma(tail) }
    if skipLeadingSpace { tail = trimSymbolGap(tail, after: out.last) }
    // A spaced symbol at the very end leaves no space dangling after it.
    if tail.isEmpty, lastWasSpaced { out = trimmingTrailingSpace(out) }
    out += tail
    return (out, fired)
  }

  /// The English bare-word route (#3738): the recogniser glues a spoken hyphen to the word before it
  /// ("well-hyphen known", "well-hyphened known", measured with Parakeet Ultra); read that as the
  /// command, then run the shared pass with the determiner guard.
  /// - Parameter joinerGap: see `applySymbolCommands`; the caller removes the gaps after its joiner pass.
  static func applyEnglishSymbolCommands(_ text: String, joinerGap: Bool, periodWord: Bool) -> String {
    let unglued = reSub(#"(\p{L})-hyphen(?:ed)?\b"#, text) { m in (m.g(1) ?? "") + " hyphen" }
    // The whole ACTIVE English table, not only its symbols: the legacy forms keep the space before a
    // legacy command ("open paren comma close paren" -> `(,)`); only symbol rows are matched here. With
    // the period switch off (#4216) "period" is an ordinary word, so it gets ordinary-word spacing.
    return applySymbolCommands(
      unglued, rules: SpokenPunctuationRules.englishRules(periodWord: periodWord), startWord: nil,
      guardDeterminers: true, joinerGap: joinerGap
    ).text
  }

  /// The gap the symbol pass leaves beside a spoken slash or backslash (HAIR SPACE). It is whitespace
  /// to `joinerCommands`, which consumes it when it writes `\` or `/`; `applyPunct` removes any left
  /// over afterwards, so the symbol ends up with its own spacing. `applyPunct` turns the gap off when
  /// the input already holds this character, so a transcript's own character is never removed.
  static let joinerGapCharacter: Character = "\u{200A}"

  /// A spaced symbol takes no space after these: opening brackets and quotes. Directional quotes
  /// only: a straight `"` opens AND closes (it is the English open and close quote), and after a
  /// closing one the space belongs (`"a" + "b"`).
  private static let tightAfter: Set<Character> = [
    "(", "[", "{", "<", "\u{201C}", "\u{2018}", "\u{201E}", "\u{00AB}",
  ]

  /// A spaced symbol takes no space before these: sentence punctuation, closing brackets and
  /// directional quotes, and the ellipsis.
  private static let tightBefore: Set<Character> = [
    ".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "\u{201D}", "\u{2019}", "\u{00BB}",
    "\u{2026}",
  ]

  /// The characters `joinerCommands` accepts directly before a spoken slash or backslash.
  private static let joinerLeftNeighbours: Set<Character> = [
    "\"", "'", "(", "[", "{", "\u{201C}", "\u{2018}", "\u{00AB}",
  ]

  /// A spoken slash or backslash at the start of the text, with the joiner's own right boundary.
  private static let joinerWordAtStart =
    #"\A(?:back[^\S\r\n]*slash|(?:forward[^\S\r\n]+)?slash)(?![^\s.,;:!?])(?![.,;:!?]\S)"#

  /// A spoken slash or backslash at the end of the text, with the joiner's own left boundary.
  private static let joinerWordAtEnd =
    #"(?<![^\s"'(\[{\x{201C}\x{2018}\x{00AB}])(?:back[^\S\r\n]*slash|(?:forward[^\S\r\n]+)?slash)\z"#

  // MARK: - Helpers

  /// Real dictation (founder History, #3738): the engine writes a comma at the pause around a spoken
  /// symbol, "open parenthesis, urgent, close parenthesis". A single comma that would land INSIDE the
  /// symbol pair (right after an opening or joining symbol, right before a closing or joining one) is
  /// the engine's, so it goes: `(urgent)`. A comma after a closing symbol stays, a full stop is never
  /// touched (`(see above.)` is real), and a SPOKEN comma is still the word "comma" when this runs on
  /// both routes, so it survives (`(x,)`).
  private static func droppingEngineComma(_ text: String) -> String {
    let rest = text.drop(while: isHorizontalSpace)
    // A single comma only: a run (",,") is not one pause mark.
    guard rest.first == ",",
      rest.dropFirst().drop(while: isHorizontalSpace).first != ","
    else { return text }
    return String(rest.dropFirst())
  }

  private static func trimmingEngineComma(_ text: String) -> String {
    let trimmed = trimmingTrailingSpace(text)
    guard trimmed.last == ",",
      trimmingTrailingSpace(String(trimmed.dropLast())).last != ","
    else { return trimmed }
    return trimmingTrailingSpace(String(trimmed.dropLast()))
  }

  private static func isHorizontalSpace(_ character: Character) -> Bool {
    character == " " || character == "\t" || character == "\u{00A0}"
  }

  /// Trailing horizontal space removed, except the no-break space a French opening guillemet
  /// carries (`«\u{00A0}`), which belongs to the guillemet.
  private static func trimmingTrailingSpace(_ text: String) -> String {
    var end = text.endIndex
    while end > text.startIndex, isHorizontalSpace(text[text.index(before: end)]) {
      end = text.index(before: end)
    }
    let trimmed = String(text[..<end])
    return trimmed.hasSuffix("\u{00AB}") && text[end...].contains("\u{00A0}")
      ? trimmed + "\u{00A0}" : trimmed
  }

  /// The last run of letters before the end of `text`, ignoring trailing whitespace.
  private static func lastWord(of text: String) -> String {
    let trimmed = text.reversed().drop(while: { $0.isWhitespace })
    return String(trimmed.prefix(while: { $0.isLetter }).reversed())
  }
}
