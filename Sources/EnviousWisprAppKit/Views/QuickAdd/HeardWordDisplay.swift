import Foundation

/// Bounds a heard selection for DISPLAY in fixed chrome.
///
/// **One algorithm, because there are two places that render the heard word and they had drifted.**
/// The menu row solved this first (PR #2427): a selection spanning two document lines carries a
/// newline, and a newline in an `NSMenuItem` title renders as a malformed multi-line row. The Quick
/// Add panel header interpolated the same value into a `Text` with no bound at all, so the same
/// selection produced a header as tall as the selection was long — up to
/// `SelectionReader.maximumSelectionScalars`, which permits a paragraph and strips only SURROUNDING
/// whitespace.
///
/// **Display only, and the distinction is load-bearing.** What gets written to the library is always
/// the ORIGINAL selection; this value exists to fit inside a row or a header. Every caller must keep
/// the unbounded value for the write path — the same separation this cluster has had to relearn more
/// than once, where a sentence was composed from a neighbouring value instead of from what the write
/// path was given.
enum HeardWordDisplay {
  /// The character ceiling. A count of CHARACTERS, so a family emoji or a base-plus-combining-mark
  /// letter counts once, however many scalars it carries.
  static let characters = 24

  /// The scalar ceiling, which bounds the worst case a character count cannot: one character can
  /// carry many scalars. Both limits apply and the tighter one wins.
  static let scalars = 96

  /// Trim, collapse internal whitespace, then truncate — in that order.
  ///
  /// **Collapsed BEFORE truncating**, so the limit counts characters the user can actually see
  /// rather than the newlines and tab runs that will not render.
  static func bounded(
    _ selection: String,
    characters characterLimit: Int = HeardWordDisplay.characters,
    scalars scalarLimit: Int = HeardWordDisplay.scalars
  ) -> String {
    let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
    // **Collapse INTERNAL whitespace, not just the ends.** Tabs and runs of spaces are the same
    // problem as a newline, one character over.
    let collapsed = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
      .joined(separator: " ")
    guard
      collapsed.count > characterLimit || collapsed.unicodeScalars.count > scalarLimit
    else { return collapsed }
    // **Truncate on CHARACTERS, not scalars.** Cutting between the scalars of one character renders
    // a broken glyph.
    var out = ""
    for character in collapsed {
      guard out.count < characterLimit,
        out.unicodeScalars.count + character.unicodeScalars.count <= scalarLimit
      else { break }
      out.append(character)
    }
    return out + "\u{2026}"
  }
}
