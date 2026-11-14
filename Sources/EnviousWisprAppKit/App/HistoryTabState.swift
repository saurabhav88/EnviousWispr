import EnviousWisprCore
import Foundation

/// The App filter of the Dictations tab (#3147 §3.3): the app each dictation went to, as
/// `ExecutionMetrics.targetApp` recorded it.
enum HistoryAppFilter: Hashable, Sendable {
  case all
  /// Dictations with no recorded app.
  case unknown
  /// The exact recorded `targetApp` value. `HistoryAppName` handles its display label.
  case named(String)
}

/// One History tab's own state (#3147 §3.3): its search, filters, open item, scroll place and
/// how many rows it has paged in. Each tab keeps its own; switching tabs never resets another.
struct HistoryTabState: Equatable, Sendable {
  var query = ""
  /// Dictations tab.
  var app: HistoryAppFilter = .all
  /// Every tab: items created inside this interval, start-inclusive, end-exclusive.
  var dateInterval: DateInterval?
  /// Meetings tab.
  var callApp: CallAppFamily?
  var openItemID: HistoryItemID?
  var scrollAnchorID: HistoryItemID?
  var requestedCount = HistoryTabState.pageSize

  /// Rows paged in per step (`HistoryPaging`).
  static let pageSize = 30

  /// The parts of the state that decide which items match.
  var listFilter: HistoryListFilter {
    HistoryListFilter(
      app: app, dateInterval: dateInterval, callApp: callApp)
  }
}

/// The filters that decide which items a History tab lists, beside its kind and search.
struct HistoryListFilter: Equatable, Sendable {
  var app: HistoryAppFilter = .all
  var dateInterval: DateInterval?
  var callApp: CallAppFamily?

  static let none = HistoryListFilter()
}
