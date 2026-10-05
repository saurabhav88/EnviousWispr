import Foundation

/// #2450: the spoken-punctuation setting as ONE value.
///
/// Replaces the loose `spokenPunctuationEnabled: Bool` that used to be copied through the settings
/// store, both pipeline drivers, the ITN step, file import and the recovery snapshot. A second
/// parallel field would have meant a second copy at every one of those sites; one value means a new
/// site cannot forget half of it.
///
/// `startWordOverrides` is SPARSE: it holds only the languages the user changed, keyed by lowercased
/// ISO base code (`"de"`). The default start word for a language comes from `SpokenPunctuationRules`
/// (also in Core), so a default we ever change reaches every user who never customised. Every value
/// stored here has passed `SpokenPunctuationStartWord.validate`; a caller that loads persisted data
/// re-validates before constructing this value.
public struct SpokenPunctuationSettings: Sendable, Equatable {
  public var enabled: Bool
  public var startWordOverrides: [String: String]

  public init(enabled: Bool, startWordOverrides: [String: String]) {
    self.enabled = enabled
    self.startWordOverrides = startWordOverrides
  }

  /// The shipped default: off, nothing customised. Named so a call site that wants "the default"
  /// says so instead of repeating two literals.
  public static let off = SpokenPunctuationSettings(enabled: false, startWordOverrides: [:])
}

/// #2450: the single owner of "is this an acceptable start word".
///
/// Pure. It receives the language's complete spoken command forms as DATA, so the function itself
/// depends on no table and stays testable with any set of forms. Callers supply them from
/// `SpokenPunctuationRules`, which now lives beside it in Core.
///
/// Ambiguous input is REFUSED, not coerced: a start word that is two words, or a word with a digit in
/// it, has no single right reading, so the field keeps the last valid value instead of guessing.
///
/// What this CANNOT do is tell a good start word from a bad one. We cannot enumerate the ordinary words
/// of four languages, so a valid word such as "der" is accepted and will turn "der Punkt" into a
/// command. The settings row warns about that; this function does not pretend to close it.
public enum SpokenPunctuationStartWord {

  public enum Refusal: String, Sendable, Equatable {
    /// Nothing left after trimming.
    case empty
    /// More than one token (whitespace inside).
    case notOneToken
    /// A character that is not a letter, or a separator in a place that is not inside the word.
    case invalidCharacters
    /// Fewer than 2 Unicode scalars after normalisation.
    case tooShort
    /// More than 20 Unicode scalars after normalisation.
    case tooLong
    /// Equals one of the language's command forms, or the first word of one.
    case collidesWithCommand
    /// The language has no command table, so it has no start word. Never produced by `validate`
    /// (which is handed forms as data); produced by the settings boundary that looks the forms up.
    case unsupportedLanguage
  }

  public enum Outcome: Sendable, Equatable {
    /// The normalised (NFC, trimmed) word to store and match.
    case accepted(String)
    case refused(Refusal)
  }

  /// Inclusive bounds, in Unicode scalars of the NFC form.
  public static let minimumLength = 2
  public static let maximumLength = 20

  /// - Parameters:
  ///   - raw: what the user typed.
  ///   - language: the language the word is for (any BCP-47 or ISO tag); only used so case folding
  ///     follows that language's rules.
  ///   - spokenForms: every spoken command form of that language, e.g. `["Punkt", "neue Zeile"]`.
  public static func validate(
    _ raw: String, language: String, spokenForms: [String]
  ) -> Outcome {
    // NFC first: a decomposed "Place" typed on some keyboards must match NFC text from the engine,
    // and every length and character check below is defined on the NFC form.
    let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    if word.isEmpty { return .refused(.empty) }

    if word.unicodeScalars.contains(where: { $0.properties.isWhitespace }) {
      return .refused(.notOneToken)
    }

    let scalars = Array(word.unicodeScalars)
    if scalars.count < minimumLength { return .refused(.tooShort) }
    if scalars.count > maximumLength { return .refused(.tooLong) }

    // Letters only, plus ASCII apostrophe and hyphen strictly INSIDE the word and never doubled.
    for (index, scalar) in scalars.enumerated() {
      if isLetter(scalar) { continue }
      let isSeparator = scalar == "'" || scalar == "-"
      let isInside = index > 0 && index < scalars.count - 1
      let previousIsLetter = index > 0 && isLetter(scalars[index - 1])
      if isSeparator && isInside && previousIsLetter { continue }
      return .refused(.invalidCharacters)
    }

    let locale = Locale(identifier: LanguageNormalizer.baseCode(language) ?? "en")
    let folded = word.lowercased(with: locale)
    for form in spokenForms {
      let normalizedForm = form.precomposedStringWithCanonicalMapping.lowercased(with: locale)
      if normalizedForm == folded { return .refused(.collidesWithCommand) }
      // The first word of a form: split on whitespace and hyphen, so "point-virgule" yields "point".
      let first = normalizedForm.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).first
      if let first, String(first) == folded { return .refused(.collidesWithCommand) }
    }
    return .accepted(word)
  }

  private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
      return true
    default:
      return false
    }
  }
}
