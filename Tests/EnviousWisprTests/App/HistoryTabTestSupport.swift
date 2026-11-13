import EnviousWisprCore
import Foundation

@testable import EnviousWisprAppKit

/// Test shorthands over the History tab API (#3147 PR2), so tests that used the retired single
/// search, filter and selection say the same thing through one tab's state.
extension TranscriptCoordinator {
  /// Sets `tab`'s search, leaving its other state alone.
  func setHistoryQuery(_ query: String, in tab: HistoryTab) {
    var state = historyState(for: tab)
    state.query = query
    setHistoryState(state, for: tab)
  }

  /// Opens `id` on `tab`, as clicking its card does.
  func openHistoryItem(_ id: HistoryItemID?, in tab: HistoryTab) {
    var state = historyState(for: tab)
    state.openItemID = id
    setHistoryState(state, for: tab)
  }

  /// The item open on `tab`, or nil when none is open or it is no longer listed.
  func openHistoryItemID(in tab: HistoryTab) -> HistoryItemID? {
    historyState(for: tab).openItemID
  }

  /// Completed items across the three tabs under their current searches and filters: every
  /// listed item except held Escape Recovery rows (a meeting with no row yet counts). The
  /// count the retired sidebar showed, for tests about held rows and Delete All.
  var completedItemCount: Int {
    HistoryTab.allCases.reduce(0) { total, tab in
      total + matchingHistoryItems(in: tab).filter { $0.row?.escapeRecoveredAt == nil }.count
    }
  }

  /// The row IDs `tab` lists now under its search and filters, all pages.
  func matchingRowIDs(in tab: HistoryTab) -> [UUID] {
    matchingHistoryItems(in: tab).compactMap(\.row?.id)
  }
}
