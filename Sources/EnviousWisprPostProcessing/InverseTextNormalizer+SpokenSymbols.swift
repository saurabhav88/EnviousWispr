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
  /// - Returns: the text and how many commands were rewritten.
  static func applySymbolCommands(
    _ text: String, rules: [SpokenPunctuationRule], startWord: String?, guardDeterminers: Bool
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
    // A command is a whole phrase: no letter, digit, underscore or joining hyphen directly before or
    // after it, so "underscores" and "re-tilde" are not commands.
    let pattern =
      #"(?<![\p{L}\p{N}_-])"# + lead + "(" + alternation(forms) + #")(?![\p{L}\p{N}_])"#
    let matches = reMatches(pattern, text)
    guard !matches.isEmpty else { return (text, 0) }

    let ns = text as NSString
    var out = ""
    var cursor = 0
    var skipLeadingSpace = false
    var lastWasSpaced = false
    var fired = 0
    for match in matches {
      let range = match.result.range
      guard range.location >= cursor else { continue }
      var gap = ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
      if skipLeadingSpace { gap = String(gap.drop(while: isHorizontalSpace)) }
      skipLeadingSpace = false
      let matched = ns.substring(with: range)
      guard let form = match.g(1), let rule = ruleByKey[formKey(form)],
        let spacing = rule.command.spacing
      else {
        out += gap + matched
        cursor = NSMaxRange(range)
        lastWasSpaced = false
        continue
      }
      if guardDeterminers, symbolDeterminers.contains(lastWord(of: out + gap).lowercased()) {
        out += gap + matched
        cursor = NSMaxRange(range)
        lastWasSpaced = false
        continue
      }
      out += gap
      lastWasSpaced = spacing == .spaced
      switch spacing {
      case .opens:
        out += rule.replacement
        skipLeadingSpace = true
      case .closes:
        out = trimmingTrailingSpace(out) + rule.replacement
      case .joins:
        out = trimmingTrailingSpace(out) + rule.replacement
        skipLeadingSpace = true
      case .spaced:
        let left = trimmingTrailingSpace(out)
        out = left + (left.isEmpty || left.last == "\n" ? "" : " ") + rule.replacement + " "
        skipLeadingSpace = true
      }
      fired += 1
      cursor = NSMaxRange(range)
    }
    var tail = ns.substring(from: cursor)
    if skipLeadingSpace { tail = String(tail.drop(while: isHorizontalSpace)) }
    // A spaced symbol at the very end leaves no space dangling after it.
    if tail.isEmpty, lastWasSpaced { out = trimmingTrailingSpace(out) }
    out += tail
    return (out, fired)
  }

  /// The English bare-word route (#3738): the recogniser glues a spoken hyphen to the word before it
  /// ("well-hyphen known", "well-hyphened known", measured with Parakeet Ultra); read that as the
  /// command, then run the shared pass with the determiner guard.
  static func applyEnglishSymbolCommands(_ text: String) -> String {
    let unglued = reSub(#"(\p{L})-hyphen(?:ed)?\b"#, text) { m in (m.g(1) ?? "") + " hyphen" }
    return applySymbolCommands(
      unglued, rules: SpokenPunctuationRules.englishSymbolRules, startWord: nil,
      guardDeterminers: true
    ).text
  }

  // MARK: - Helpers

  private static func isHorizontalSpace(_ character: Character) -> Bool {
    character == " " || character == "\t" || character == "\u{00A0}"
  }

  private static func trimmingTrailingSpace(_ text: String) -> String {
    var end = text.endIndex
    while end > text.startIndex, isHorizontalSpace(text[text.index(before: end)]) {
      end = text.index(before: end)
    }
    return String(text[..<end])
  }

  /// The last run of letters before the end of `text`, ignoring trailing whitespace.
  private static func lastWord(of text: String) -> String {
    let trimmed = text.reversed().drop(while: { $0.isWhitespace })
    return String(trimmed.prefix(while: { $0.isLetter }).reversed())
  }
}
