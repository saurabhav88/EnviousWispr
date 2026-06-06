import EnviousWisprCore

/// Narrow, on-device alias generator seam. Declared `package` (same-package
/// consumers only — EnviousWisprAppKit's contacts-import enrichment), mirroring
/// Core's package narrow protocols. The sole production conformer is
/// `WordSuggestionService`; tests use a fake. (#636 follow-up.)
package protocol AliasSuggesting: Sendable {
  /// Whether on-device generation is available right now (Apple Intelligence on
  /// macOS 26+). When false, callers skip enrichment entirely.
  var isAvailable: Bool { get }

  /// Generate spoken-variant aliases for `word`, with the category already known
  /// so no classification call is made. Returns nil when unavailable, timed out,
  /// or the model degenerated to self-echoes (mirrors `suggest(for:)`).
  func suggestAliases(for word: String, category: WordCategory) async -> [String]?
}
