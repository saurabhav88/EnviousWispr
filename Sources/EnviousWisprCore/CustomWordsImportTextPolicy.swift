import Foundation

/// What characters may appear in imported text, for EVERY source (#1683).
///
/// This lives in Core, not in the plain-text parser that first needed it,
/// because the policy is about the STORE and not about one door into it. While
/// it lived beside the text parser, words arriving from an exported file
/// skipped it entirely: the same hardening that refused an invisible control
/// character from a pasted list happily accepted one from JSON (Codex import
/// taxonomy audit, #1683 — class C04/C09).
///
/// Every rule here therefore applies to plain text, exported files, and any
/// future source, or it does not belong here.
package enum CustomWordsImportTextPolicy {
  /// The two format scalars that are word-forming.
  ///
  /// Load-bearing in Hindi, Persian, and emoji sequences, so they survive.
  /// The rest of the format category must not: a mid-file byte-order mark is
  /// invisible, and a bidi override makes a word render as something other
  /// than what it is. Both would be stored INSIDE a word, where nothing
  /// downstream strips them.
  private static let wordFormingInvisibles: Set<UInt32> = [0x200C, 0x200D]

  /// Whether text is plausibly text at all — no controls, surrogates,
  /// private-use, unassigned, or non-word-forming format scalars.
  ///
  /// Asks Unicode rather than hand-rolling ranges: a numeric approximation
  /// (`< 0x20 || == 0x7F`) missed the entire C1 block, so `C2 85` imported an
  /// invisible character inside a word.
  package static func isPlausiblyText(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy(isAcceptable)
  }

  /// Whether text looks like WORDS rather than merely printable characters.
  ///
  /// Stricter than `isPlausiblyText`: non-ASCII must be a letter, mark, or
  /// digit. Symbols are the tell that an encoding was misread — `qg¬N` rather
  /// than `Beyoncé` — and no one puts a maths symbol in a vocabulary entry.
  /// ASCII passes freely so `C++` and `.NET` are unaffected.
  package static func looksLikeWords(_ text: String) -> Bool {
    guard !text.isEmpty, isPlausiblyText(text) else { return false }
    return text.unicodeScalars.allSatisfy { scalar in
      if scalar.isASCII { return true }
      if wordFormingInvisibles.contains(scalar.value) { return true }
      switch scalar.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
        .otherLetter, .nonspacingMark, .spacingMark, .decimalNumber, .otherNumber:
        return true
      default:
        return false
      }
    }
  }

  /// Whether a single stored value — a canonical or an alias — is acceptable.
  ///
  /// Line breaks and tabs are separators BETWEEN words, never content within
  /// one, so they are refused here even though `isPlausiblyText` allows them
  /// while scanning a whole file.
  /// Scalar-level form of `isAcceptableStoredValue`, for callers inspecting
  /// one character at a time.
  ///
  /// Needed because the whole-value check also rejects blank values, so
  /// testing a single space through it reports the space as rejected — which
  /// made the error sanitiser label ordinary spaces as bad characters (Codex
  /// review, #1683).
  package static func isAcceptableInStoredValue(_ scalar: Unicode.Scalar) -> Bool {
    guard scalar != "\n", scalar != "\r", scalar != "\t" else { return false }
    return isAcceptable(scalar)
  }

  package static func isAcceptableStoredValue(_ value: String) -> Bool {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    return value.unicodeScalars.allSatisfy(isAcceptableInStoredValue)
  }

  private static func isAcceptable(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == "\n" || scalar == "\r" || scalar == "\t" { return true }
    if wordFormingInvisibles.contains(scalar.value) { return true }
    switch scalar.properties.generalCategory {
    case .control, .surrogate, .privateUse, .unassigned, .format,
      // U+2028 and U+2029 are line and paragraph breaks with their OWN
      // categories, so a control-only check let them through — invisible,
      // inside a stored word, despite the separator policy saying otherwise
      // (Codex review, #1683).
      .lineSeparator, .paragraphSeparator:
      return false
    default:
      return true
    }
  }
}
