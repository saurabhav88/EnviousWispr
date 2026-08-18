import EnviousWisprLivePreview
import Foundation

/// #2080: how the language-pack list is split for display.
///
/// Fifty-four languages in one flat list buries the handful a user actually has behind forty-odd
/// they do not, so the two states get their own groups: what is on this Mac, and what is a
/// download away.
///
/// Modelled on `OllamaCatalogPresentation`, which solved the same problem for the Manage Models
/// list, including the reason it is a TYPE rather than an inline filter in the view: an earlier
/// version of those tests wrote their own predicate, so they proved only that the copy worked and
/// changing the real split could not fail them. A mutation to this type does fail its tests.
///
/// The boundary that buys, stated exactly: these tests protect the GROUPING POLICY and the
/// headings. They do NOT protect the SwiftUI wiring — if the view stopped calling this, or
/// rendered the groups in the wrong order, the tests would still pass. That half is a Live UAT
/// item.
enum LivePreviewPackPresentation {

  /// The language list, split for display.
  struct Groups: Equatable {
    /// Packs macOS reports as present. First, because they are the ones that work right now.
    let installed: [LivePreviewPack]
    /// Everything else Apple supports on this Mac.
    let available: [LivePreviewPack]

    var isEmpty: Bool { installed.isEmpty && available.isEmpty }
  }

  /// Headings. Statements of where the language IS, not instructions — the row's own button
  /// already says what pressing it does, and repeating that in a heading reads as nagging.
  ///
  /// Rendered as SECTION headers rather than rows: styled as a row label they carried the same
  /// visual weight as a language name and disappeared into the list, so the boundary between
  /// "installed" and "downloadable" was invisible after ten rows (founder, 2026-08-16).
  static let installedGroupTitle = "On this Mac"
  static let availableGroupTitle = "Available to download"

  /// Rows matching `query`, or all of them when it is empty.
  ///
  /// Lives here rather than on the model for the same reason the grouping does: it is
  /// presentation policy, it is pure, and it has no business being `@MainActor`-isolated — which
  /// is what stopped a test calling it directly.
  ///
  /// Matches the same three fields as `LanguageLockSheet`: the name in the user's language, the
  /// endonym, and the tag. Somebody looking for German may type "German", "Deutsch", or "de".
  ///
  /// **Diacritic-insensitive, which the older sheet is not.** In a 54-language list the endonyms
  /// are full of accents, so typing "francais" must find "Français"; requiring the accent means
  /// the search fails for exactly the languages a search is most needed for. Worth the small
  /// inconsistency with the sheet, which is a candidate to align later.
  static func matching(_ packs: [LivePreviewPack], query: String) -> [LivePreviewPack] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return packs }
    let needle = fold(trimmed)
    return packs.filter { pack in
      fold(pack.localizedName).contains(needle)
        || fold(pack.nativeName).contains(needle)
        || fold(pack.tag).contains(needle)
    }
  }

  private static func fold(_ value: String) -> String {
    value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
  }

  /// What the table's Availability cell shows for a pack.
  ///
  /// #2154. **Named for what it COMPUTES, after a first draft called it
  /// "Source" and was wrong about its own meaning.** It reads `isInstalled` and
  /// nothing else, so downloading a language through this page flipped its cell
  /// from "Apple" to "System" — telling the user the pack had come with macOS
  /// when they had fetched it from Apple moments before. The model carries no
  /// provenance to report; every one of these is an Apple pack either way.
  ///
  /// What it does answer is the question somebody scanning 54 rows is actually
  /// asking: do I already have this. That is also the honest answer to "why
  /// does this look like the list in System Settings" — it IS that list
  /// (`live-preview.md` FACT: language-pack-downloads).
  ///
  /// A named function rather than an inline ternary in the view, so the rule is
  /// testable and has one home — the same reason `groups(from:)` is here.
  static func availability(for pack: LivePreviewPack) -> String {
    pack.isInstalled
      ? LivePreviewSettingsCopy.sourceSystem
      : LivePreviewSettingsCopy.sourceApple
  }

  /// Split, preserving the incoming order within each group.
  ///
  /// The catalogue already sorts alphabetically by the name the user reads, so re-sorting here
  /// would either duplicate that decision or silently disagree with it.
  static func groups(from packs: [LivePreviewPack]) -> Groups {
    Groups(
      installed: packs.filter(\.isInstalled),
      available: packs.filter { !$0.isInstalled }
    )
  }
}
