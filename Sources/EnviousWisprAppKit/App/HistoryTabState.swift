import EnviousWisprCore
import Foundation

/// The App filter of the Dictations tab (#3147 §3.3): the app each dictation went to, as
/// `ExecutionMetrics.targetApp` recorded it.
enum HistoryAppFilter: Hashable, Sendable {
  case all
  /// Dictations with no recorded app.
  case unknown
  /// The exact recorded `targetApp` value, never a guessed bundle ID.
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
  /// Transcripts tab: speaker count from the row's speaker analysis (One speaker = 1).
  var speakerCount: ClosedRange<Int>?
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
      app: app, dateInterval: dateInterval, speakerCount: speakerCount, callApp: callApp)
  }
}

/// The filters that decide which items a History tab lists, beside its kind and search.
struct HistoryListFilter: Equatable, Sendable {
  var app: HistoryAppFilter = .all
  var dateInterval: DateInterval?
  var speakerCount: ClosedRange<Int>?
  var callApp: CallAppFamily?

  static let none = HistoryListFilter()
}

extension Transcript {
  /// How many speakers History counts for this row, or nil when no speaker analysis says.
  var historySpeakerCount: Int? {
    switch speakerAnalysis {
    case .single: return 1
    case .labeled(let count): return count
    case .unanalyzed, .failed, nil: return nil
    }
  }
}
