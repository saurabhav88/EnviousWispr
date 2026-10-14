import EnviousWisprCore
import Foundation

/// #3737 Casual mode: leave off the full stop at the very end of a dictation.
///
/// The sole owner of "which final mark Casual mode removes". `CasualEndingStep` (Pipeline) applies it
/// to both text fields of a take; nothing else decides it.
///
/// What is removed: the LAST non-whitespace character, when it is a full stop (`.`, `。` or `।`) and
/// none of the exceptions below holds. Everything else stays: `?` and `!` (they change meaning), commas,
/// full stops inside the text, and a full stop that a closing quote or bracket follows (`(see above.)`),
/// because then the full stop is not the last character.
///
/// Exceptions, each one a dot that is not a sentence end or that the user asked for:
/// - an ellipsis (`...`, `…`);
/// - a dotted abbreviation as the final word (`a.m.`, `U.S.`, `e.g.`, `Ph.D.`);
/// - a dot right after a digit outside English, where it can be an ordinal (German "am 3."). This is
///   the same rule the recogniser-mark cleanup applies (`digitIsOrdinal`, #3594); an unknown language
///   keeps the dot;
/// - a full stop the user SAID ("... period"), reported by the spoken-punctuation pass (`spokenFinalFullStop`);
/// - a text that would be left blank.
///
/// Accepted in the casual register the user opted into: a final `etc.`, `Dr.` or `Inc.` loses its dot.
package enum CasualEnding {

  /// The full stops Casual mode removes: Latin, CJK ideographic, Devanagari danda.
  static let fullStops: Set<Character> = [".", "\u{3002}", "\u{0964}"]

  /// A final word made only of one- or two-letter pieces each followed by a dot, at least two pieces.
  private static let dottedAbbreviation = try! NSRegularExpression(
    pattern: #"^(?:\p{L}{1,2}\.){2,}$"#)

  /// Opening marks that may sit in front of the final word and are not part of it.
  private static let leadingOpeners: Set<Character> = ["(", "[", "\"", "'", "\u{201C}", "\u{2018}"]

  /// - Parameters:
  ///   - text: the take's text.
  ///   - language: ITN-route language when available; otherwise the resolved language. Any form
  ///     (`en`, `en-GB`); normalised here.
  ///   - spokenFinalFullStop: the spoken-punctuation pass converted a "period" command at the end.
  /// - Returns: `text` without its final full stop, or `text` unchanged.
  package static func removingFinalFullStop(
    _ text: String, language: String?, spokenFinalFullStop: Bool
  ) -> String {
    guard !spokenFinalFullStop,
      let lastIndex = text.lastIndex(where: { !$0.isWhitespace }),
      fullStops.contains(text[lastIndex])
    else { return text }

    let before = text[..<lastIndex]
    let mark = text[lastIndex]
    // An ellipsis written as dots, or a dot run ending in another script's full stop. (A `…` is not a
    // full stop, so it never reaches here.)
    if before.last == "." { return text }
    if mark == "." {
      // A dot right after a digit is an ordinal outside English.
      if let previous = before.last, previous.isNumber,
        LanguageNormalizer.baseCode(language) != "en"
      {
        return text
      }
      // A dotted abbreviation as the final word.
      if isDottedAbbreviation(finalWord(of: text[...lastIndex])) { return text }
    }

    let remaining = String(before) + String(text[text.index(after: lastIndex)...])
    guard remaining.contains(where: { !$0.isWhitespace }) else { return text }
    return remaining
  }

  /// The final whitespace-delimited word, without opening quotes or brackets in front of it.
  private static func finalWord(of text: Substring) -> Substring {
    let start =
      text.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
    var word = text[start...]
    while let first = word.first, leadingOpeners.contains(first) { word = word.dropFirst() }
    return word
  }

  private static func isDottedAbbreviation(_ word: Substring) -> Bool {
    let candidate = String(word)
    let range = NSRange(candidate.startIndex..., in: candidate)
    return dottedAbbreviation.firstMatch(in: candidate, range: range) != nil
  }
}
