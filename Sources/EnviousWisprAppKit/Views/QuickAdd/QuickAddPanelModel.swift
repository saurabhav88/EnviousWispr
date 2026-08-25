import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation

/// The Quick Add panel's state machine (#2381).
///
/// **Everything about which row owns the Return key lives here, and nothing about windows does.**
/// A focused search field and a preselected row both want Return, and the collision is invisible
/// until someone types — so the rule is one place, written down, and unit-tested without a panel.
///
/// The two ranking calls are injected rather than reached for. That is not ceremony: it keeps this
/// type free of the word library and lets every keyboard rule be exercised against candidate lists
/// chosen to make the rule visible, instead of whatever the real scorer happens to return.
@MainActor
@Observable
final class QuickAddPanelModel {

  /// What the user selected. **Immutable for the panel's lifetime** — typing in the search field
  /// changes which candidates are SHOWN and never what would be written.
  let heard: String

  /// Why there is no selection, or nil when there is one. The panel opens either way; it never
  /// silently does nothing.
  let refusal: SelectionReader.Refusal?

  /// What the user has typed. Navigation only.
  private(set) var query: String = ""

  /// The rows on screen, and which one Return would accept.
  private(set) var ranking: QuickAddRanker.Ranking

  private let rankHeard: (String) -> QuickAddRanker.Ranking
  private let searchLibrary: (String, String) -> QuickAddRanker.Ranking

  init(
    heard: String,
    refusal: SelectionReader.Refusal? = nil,
    rankHeard: @escaping (String) -> QuickAddRanker.Ranking,
    searchLibrary: @escaping (String, String) -> QuickAddRanker.Ranking
  ) {
    self.heard = heard
    self.refusal = refusal
    self.rankHeard = rankHeard
    self.searchLibrary = searchLibrary
    // A refusal has no heard string to rank, so the panel opens on an empty list and a stated
    // reason rather than on a ranking of nothing.
    self.ranking = refusal == nil ? rankHeard(heard) : .empty
  }

  // MARK: - The search field

  /// Re-rank for what the user has typed.
  ///
  /// Clearing the field restores the HEARD ranking, including its confidence-based preselection —
  /// not an empty list, and not the last search's results.
  func updateQuery(_ newQuery: String) {
    query = newQuery
    guard refusal == nil else { return }
    let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    ranking =
      trimmed.isEmpty
      ? rankHeard(heard)
      : searchLibrary(newQuery, heard)
  }

  // MARK: - The keyboard contract

  /// Move the highlight without leaving the search field.
  ///
  /// Clamped rather than wrapping: wrapping from the last row to the first is a surprise when the
  /// list is short and the user is holding the key, and this list is at most a handful of rows.
  func moveHighlight(by offset: Int) {
    guard !ranking.candidates.isEmpty else { return }
    let current = ranking.candidates.firstIndex { $0.id == ranking.preselectedID }
    // No highlight yet means the bar was not cleared, so an arrow press is the user OPTING IN to a
    // row. Down starts at the top; up starts at the bottom.
    let next: Int
    if let current {
      next = min(max(current + offset, 0), ranking.candidates.count - 1)
    } else {
      next = offset >= 0 ? 0 : ranking.candidates.count - 1
    }
    ranking = QuickAddRanker.Ranking(
      candidates: ranking.candidates, preselectedID: ranking.candidates[next].id)
  }

  /// The row Return would accept, or nil when Return must write nothing.
  var acceptTarget: QuickAddRanker.Candidate? { ranking.preselected }

  /// What gets written if the user accepts. **Always the original selection, never the query.**
  ///
  /// The distinction is the whole safety property of the search field: accepting a searched-for row
  /// must save what the user SELECTED, not what they typed to find it. Without this the escape
  /// hatch built to recover from a wrong ranking becomes a way to write an arbitrary string.
  var spellingToWrite: String { heard }
}
