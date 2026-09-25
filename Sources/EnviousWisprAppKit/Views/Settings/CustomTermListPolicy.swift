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
    // The same trim `filtered` applies: a whitespace-only query is no search.
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !query.isEmpty {
      return String(
        localized: "No matches for \"\(query)\".",
        comment:
          "Your Words: empty search result. %@ is what the user typed; use this language's quotation marks."
      )
    }
    if autoLearnedOnly {
      return category == nil
        ? CustomTermProvenanceCopy.noAutoLearnedWordsYet
        : CustomTermProvenanceCopy.noAutoLearnedWordsInCategory
    }
    if category != nil {
      return String(
        localized: "No words in this category.",
        comment: "Your Words: empty list for a chosen category.")
    }
    return String(
      localized: "No words yet. Add one with the button above.",
      comment: "Your Words: empty word list.")
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
  static let filterPill = String(
    localized: "Auto-learned",
    comment: "Your Words: filter that shows only words learned automatically.")
  static let noAutoLearnedWordsYet = String(
    localized: "No auto-learned words yet.",
    comment: "Your Words: empty list with the Auto-learned filter.")
  /// The Auto-learned pill AND a category pill, with nothing in both.
  static let noAutoLearnedWordsInCategory = String(
    localized: "No auto-learned words in this category.",
    comment: "Your Words: empty list with the Auto-learned filter and a category.")
  static let learnedFromYourEdits = String(
    localized: "learned from your edits",
    comment:
      "Your Words, VoiceOver: said after a learned word or mishearing; lowercase, as a phrase.")
  static let learnedAliasesHelper = String(
    localized: "Sparkled sound-alikes were learned from your edits.",
    comment:
      "Your Words: note under the list of mishearings. Sparkled means marked with a sparkle icon.")
}

/// A category's name on screen (#3142). The raw value is the stored identity and stays English;
/// the English name is the raw value capitalized, as before.
extension WordCategory {
  var displayName: String {
    switch self {
    // Its own key: "General" is also an S1-mini writing context, a different meaning (#3142).
    case .general:
      return String(
        localized: "wordCategory.general", defaultValue: "General",
        comment: "Your Words: the category for words without a specific field.")
    case .person:
      return String(localized: "Person", comment: "Your Words: a word category, a person's name.")
    case .brand:
      return String(
        localized: "Brand", comment: "Your Words: a word category, a brand or product name.")
    case .acronym: return String(localized: "Acronym", comment: "Your Words: a word category.")
    case .domain:
      return String(
        localized: "Domain", comment: "Your Words: a word category, a subject area's jargon.")
    }
  }
}
