import EnviousWisprCore

/// Scheduling hint for `WordSuggestionService`'s shared permit queue (#1701).
/// Does not change what a call returns, only when it runs relative to other
/// queued calls: an `.interactive` waiter is granted the next permit ahead of
/// any already-queued `.background` waiter; two waiters of equal priority are
/// served FIFO. `public` because `WordSuggestionService.suggest(for:priority:)`
/// is a public API and Swift requires its parameter types be at least as
/// visible as the function itself.
public enum AliasSuggestionPriority: Sendable, Equatable {
  case interactive
  case background
}

/// Narrow, on-device alias generator seam. Declared `package` (same-package
/// consumers only — EnviousWisprAppKit's contacts-import enrichment), mirroring
/// Core's package narrow protocols. The sole production conformer is
/// `WordSuggestionService`; tests use a fake. (#636 follow-up.)
package protocol AliasSuggesting: Sendable {
  /// Whether on-device generation is available right now (Apple Intelligence on
  /// macOS 26+). `ContactsImportCoordinator` checks this and skips enrichment
  /// entirely when false. `BulkImportEnrichmentCoordinator` does NOT check
  /// this (#1701 D16 fail-open): it always calls `suggestAliases`, which
  /// resolves to `nil` when unavailable the same way it does on a timeout,
  /// and checkpoints that as an honest "tried, got nothing" so durable
  /// pending state is never stranded waiting for availability to change.
  var isAvailable: Bool { get }

  /// Generate spoken-variant aliases for `word`, with the category already known
  /// so no classification call is made. Returns nil when unavailable, timed out,
  /// or the model degenerated to self-echoes (mirrors `suggest(for:)`).
  /// `priority` has no default: every caller must state its own scheduling
  /// intent explicitly rather than silently inheriting `.interactive` (#1701).
  func suggestAliases(
    for word: String, category: WordCategory, priority: AliasSuggestionPriority
  ) async -> [String]?

  /// Generate aliases for `word` whose category is NOT genuinely known —
  /// classifies first, then generates from that classification (Phase 3
  /// review finding A, #1701). A word stored as `.general` because it was
  /// never explicitly categorized (the type default) must not be force-fed
  /// the general-word prompt as though `.general` were confirmed; this
  /// overload gets it a real classification pass first, matching what
  /// Add-term's `suggest(for:priority:)` already does. Returns nil under the
  /// same conditions as the known-category overload.
  func suggestAliases(
    for word: String, priority: AliasSuggestionPriority
  ) async -> [String]?
}
