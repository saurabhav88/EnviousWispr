import Foundation

// MARK: - Learn-from-edits correction-pair identity (#996 §4)
//
// The one pure value the live learn path shares: the identity of an
// (original, corrected) pair. The candidate filter keys each run by it, the
// watcher dedupes what it has already sent to the judge by it, and the learned
// coordinator uses its normalisation to match a mishearing against a word's
// aliases. Nothing here writes vocabulary or decides anything.

/// The ordered pair a correction is about, as ONE string that is safe to compare
/// and to persist. `v1:` plus the UTF-8 JSON encoding of the two-element array
/// `[NFC-casefolded original, NFC-casefolded corrected]` (§4): a JSON array
/// cannot be forged by an original that happens to contain a separator, and
/// casefolding means "Saira"/"saira" are one pair while "Saira"/"Sarah" are two.
package enum CorrectionPairKey {
  package static let version = "v1"

  package static func make(original: String, corrected: String) -> String {
    // Encoded by hand rather than through JSONEncoder so the key's bytes do
    // not depend on an encoder option (JSONEncoder escapes "/" by default):
    // minimal JSON string escaping, which every JSON decoder reads back as
    // exactly the two normalised strings. A key must never be a plausible
    // default, and this path cannot throw.
    "\(version):[" + jsonString(normalise(original)) + "," + jsonString(normalise(corrected)) + "]"
  }

  /// A JSON string literal with the minimal escaping the grammar requires.
  static func jsonString(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case let s where s.value < 0x20:
        out += String(format: "\\u%04X", s.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }

  /// NFC first (so the casefold sees one composed form), then casefold.
  package static func normalise(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.folding(
      options: [.caseInsensitive], locale: nil)
  }
}
