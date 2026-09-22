import EnviousWisprCore
import Foundation

/// Phase 4 (#634) — pure helper for filtering + paginating the Custom Terms
/// list. Extracted so the search/pagination math is unit-testable without
/// SwiftUI ViewInspector. Bible §10.6.
enum CustomTermListPolicy {
  static let pageSize = 50

  /// Filter `all` against `query` (case + diacritic insensitive substring
  /// across canonical, aliases, category) and, independently, against
  /// `category` (#2494) and `autoLearnedOnly` (#996) — a word must satisfy
  /// ALL that are given. `category: nil` means "all categories," matching the
  /// filter pill row's default; `autoLearnedOnly: false` is the Auto-learned
  /// pill off. The auto-learned test is `CustomWord.isAutoLearned`, the one
  /// predicate the row sparkle reads too. Empty query + nil category + filter
  /// off returns the full list. Sort is alphabetical by canonical, localized
  /// + case-insensitive.
  static func filtered(
    _ all: [CustomWord], query: String, category: WordCategory? = nil,
    autoLearnedOnly: Bool = false
  ) -> [CustomWord] {
    let byProvenance = autoLearnedOnly ? all.filter(\.isAutoLearned) : all
    let byCategory =
      category.map { cat in byProvenance.filter { $0.category == cat } } ?? byProvenance
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return byCategory.sorted {
        $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending
      }
    }
    let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    let locale = Locale.current
    return byCategory.filter { word in
      if word.canonical.range(of: trimmed, options: opts, locale: locale) != nil {
        return true
      }
      if word.aliases.contains(where: {
        $0.range(of: trimmed, options: opts, locale: locale) != nil
      }) {
        return true
      }
      if word.category.rawValue.range(of: trimmed, options: opts, locale: locale) != nil {
        return true
      }
      return false
    }.sorted {
      $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending
    }
  }

  /// The empty-list message, by precedence (#2494 review, #996): a search
  /// that matched nothing beats every filter; the Auto-learned pill beats
  /// the category pill; the bare library last. One owner so the view and
  /// the tests read the same table.
  static func emptyStateMessage(
    query: String, autoLearnedOnly: Bool, category: WordCategory?
  ) -> String {
    if !query.isEmpty { return "No matches for \"\(query)\"." }
    if autoLearnedOnly { return CustomTermProvenanceCopy.noAutoLearnedWordsYet }
    if category != nil { return "No words in this category." }
    return "No words yet. Add one with the button above."
  }

  /// Number of pages required to display `count` items.
  static func pageCount(of count: Int) -> Int {
    max(1, (count + pageSize - 1) / pageSize)
  }

  /// Slice of `filtered` for `page` (0-indexed). Returns empty if page is
  /// out of range. Caller is responsible for clamping `page` after a search
  /// changes the filtered count.
  ///
  /// Generic over the element because the vocabulary-pack word list pages by
  /// the same rule and must not answer "how many words fit on a page" for
  /// itself — `pageSize` has ONE owner. It was `[CustomWord]` only because the
  /// Your Words list was the only caller; nothing in the arithmetic ever read
  /// the element.
  static func paged<Element>(_ filtered: [Element], page: Int) -> [Element] {
    let start = page * pageSize
    let end = min(start + pageSize, filtered.count)
    guard start < filtered.count else { return [] }
    return Array(filtered[start..<end])
  }

  /// IDs eligible for bulk selection (#1703) = exactly the IDs
  /// `CustomWordsExportAction.exportableWords` would back up. One authority
  /// for "the user's own," not a second one.
  static func selectableIDs(in words: [CustomWord]) -> Set<UUID> {
    Set(CustomWordsExportAction.exportableWords(from: words).map(\.id))
  }

  /// Select-All/Deselect-All toggle over the CURRENT FILTERED target — not
  /// the whole library, and not just the current page. If `target` is
  /// already fully selected, deselect exactly it; otherwise union it in.
  static func toggledSelection(current: Set<UUID>, target: Set<UUID>) -> Set<UUID> {
    target.isSubset(of: current) ? current.subtracting(target) : current.union(target)
  }
}

/// Phase 4 (#634) — Match Strictness picker mapping for `CustomWord.minSimilarityOverride`.
/// Bible §19 Q4.
enum MatchStrictness: String, CaseIterable {
  case loose
  case standard
  case strict

  var override: Double? {
    switch self {
    case .loose: return 0.72
    case .standard: return nil
    case .strict: return 0.92
    }
  }

  static func from(_ override: Double?) -> MatchStrictness {
    guard let v = override else { return .standard }
    if v <= 0.80 { return .loose }
    if v >= 0.88 { return .strict }
    return .standard
  }
}

/// Every string Your Words says about learned provenance (#996): the filter
/// pill, its empty state, the VoiceOver label/value on the sparkle and the
/// learned chips, and the helper line under the alias list. The views and
/// the tests read this table; nothing restates it.
enum CustomTermProvenanceCopy {
  static let filterPill = "Auto-learned"
  static let noAutoLearnedWordsYet = "No auto-learned words yet."
  static let learnedFromYourEdits = "learned from your edits"
  static let learnedAliasesHelper = "Sparkled sound-alikes were learned from your edits."
}
