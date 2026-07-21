import EnviousWisprCore
import Foundation

/// Phase 4 (#634) — pure helper for filtering + paginating the Custom Terms
/// list. Extracted so the search/pagination math is unit-testable without
/// SwiftUI ViewInspector. Bible §10.6.
enum CustomTermListPolicy {
  static let pageSize = 50

  /// Filter `all` against `query` (case + diacritic insensitive substring
  /// across canonical, aliases, category). Empty query returns the full
  /// list. Sort is alphabetical by canonical, localized + case-insensitive.
  static func filtered(_ all: [CustomWord], query: String) -> [CustomWord] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return all.sorted {
        $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending
      }
    }
    let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    let locale = Locale.current
    return all.filter { word in
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

  /// Number of pages required to display `count` items.
  static func pageCount(of count: Int) -> Int {
    max(1, (count + pageSize - 1) / pageSize)
  }

  /// Slice of `filtered` for `page` (0-indexed). Returns empty if page is
  /// out of range. Caller is responsible for clamping `page` after a search
  /// changes the filtered count.
  static func paged(_ filtered: [CustomWord], page: Int) -> [CustomWord] {
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
