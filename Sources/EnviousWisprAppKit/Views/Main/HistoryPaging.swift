import EnviousWisprCore
import Foundation

/// How much of a History tab's list the diary draws (#4001 step 3a, #3147 §3.3). On a 27,000-row
/// History drawing every item made each search letter and filter switch cost seconds on an M1;
/// the coordinator still decides which items match, and this only decides how many of them the
/// diary draws: 30, growing by 30. Plain value code, so the paging rules are tested without a
/// view.
///
/// The requested count is stored once, in the tab's `HistoryTabState.requestedCount`, which the
/// coordinator resets to 30 whenever the tab's search or filters change. This type keys every
/// window and load request by the tab and all of its filters, so a request made for one tab or
/// one filter is never applied to another.
enum HistoryPaging {
  static let pageSize = HistoryTabState.pageSize

  /// The tab, search and filters a requested limit was set for: a new one starts again at 30.
  struct Context: Equatable, Sendable {
    let tab: HistoryTab
    let query: String
    let filter: HistoryListFilter

    init(tab: HistoryTab, query: String, filter: HistoryListFilter) {
      self.tab = tab
      self.query = query
      self.filter = filter
    }

    /// The context `state` describes on `tab`.
    init(tab: HistoryTab, state: HistoryTabState) {
      self.init(tab: tab, query: state.query, filter: state.listFilter)
    }
  }

  /// The stored request: how many items, for which context.
  struct State: Equatable {
    var requested = HistoryPaging.pageSize
    var context: Context?
  }

  /// The paging state `tabState` carries on `tab`: its stored count, for its own context.
  static func state(_ tabState: HistoryTabState, tab: HistoryTab) -> State {
    State(requested: tabState.requestedCount, context: Context(tab: tab, state: tabState))
  }

  /// What one rendering of the list showed: its context, how many items it drew, its last item
  /// and how many items qualify.
  struct Window: Equatable {
    let context: Context
    let boundary: Int
    let tail: HistoryItemID?
    let total: Int

    var hasMore: Bool { boundary < total }
  }

  /// A request to draw the next page, made from the window that rendered its row or button.
  struct LoadRequest: Equatable {
    let context: Context
    let boundary: Int
    let tail: HistoryItemID
  }

  /// The stored limit when it was set for this context, else 30.
  static func requested(_ state: State, for context: Context) -> Int {
    state.context == context ? state.requested : pageSize
  }

  /// At least `requested`, and far enough to include an open item: its position rounded up to
  /// the next page boundary. Never more than `total`.
  static func effectiveCount(requested: Int, selectedIndex: Int?, total: Int) -> Int {
    let throughSelection = selectedIndex.map { ($0 / pageSize + 1) * pageSize } ?? 0
    return min(total, max(requested, throughSelection))
  }

  /// The window `items` give under `context`, `state` and `selected`, computed before the diary
  /// is built, so an open item is inside it without any callback having run.
  static func window(
    items: [HistoryListItem], context: Context, state: State, selected: HistoryItemID?,
    positions: [HistoryItemID: Int]? = nil
  ) -> Window {
    let selectedIndex = selected.flatMap { id in
      if let positions { return positions[id] }
      return items.firstIndex { $0.id == id }
    }
    let boundary = effectiveCount(
      requested: requested(state, for: context), selectedIndex: selectedIndex, total: items.count)
    return Window(
      context: context, boundary: boundary, tail: boundary > 0 ? items[boundary - 1].id : nil,
      total: items.count)
  }

  /// The request the last row and Load more history send for `window`, nil when none remain.
  static func request(for window: Window) -> LoadRequest? {
    guard window.hasMore, let tail = window.tail else { return nil }
    return LoadRequest(context: window.context, boundary: window.boundary, tail: tail)
  }

  /// The next limit when `request` still describes `current`, else nil: a duplicate request,
  /// one made for an older window, another tab or other filters, or one with nothing left.
  static func accept(_ request: LoadRequest, current: Window) -> Int? {
    guard request.context == current.context, request.boundary == current.boundary,
      request.tail == current.tail, request.boundary < current.total
    else { return nil }
    return min(current.total, request.boundary + pageSize)
  }

  /// The state after a load request against the live window: an accepted limit is stored with
  /// its context, anything else leaves the state as it was.
  static func load(_ request: LoadRequest, state: State, current: Window) -> State {
    guard let limit = accept(request, current: current) else { return state }
    return State(requested: limit, context: current.context)
  }
}

/// An accepted query result. Selection uses the complete result while the diary draws a page.
struct HistoryQueryResult: Sendable {
  struct Entry: Identifiable, Sendable {
    let id: HistoryDiaryLayout.EntryID
    let position: Int
    let dayCount: Int
  }

  let key: TranscriptCoordinator.HistoryQueryKey
  let items: [HistoryListItem]
  let positions: [HistoryItemID: Int]
  let ids: Set<HistoryItemID>
  let calendar: Calendar
  private let entries: [Entry]
  private let rowOffsets: [Int]
  private let dayPositions: [Date: Int]

  init(key: TranscriptCoordinator.HistoryQueryKey, items: [HistoryListItem]) throws {
    self.key = key
    self.items = items
    let calendar = key.calendar
    self.calendar = calendar
    var positions: [HistoryItemID: Int] = [:]
    var entries: [Entry] = []
    var offsets: [Int] = []
    var days: [Date: Int] = [:]
    var index = 0
    while index < items.count {
      try Task.checkCancellation()
      let day = calendar.startOfDay(for: items[index].createdAt)
      let end = HistoryDiaryLayout.firstIndex(before: day, in: items, from: index)
      days[day] = index
      entries.append(Entry(id: .day(day), position: index, dayCount: end - index))
      while index < end {
        try Task.checkCancellation()
        let id = items[index].id
        if positions[id] == nil { positions[id] = index }
        offsets.append(entries.count)
        entries.append(Entry(id: .item(id), position: index, dayCount: 0))
        index += 1
      }
    }
    self.positions = positions
    self.ids = Set(positions.keys)
    self.entries = entries
    self.rowOffsets = offsets
    self.dayPositions = days
  }

  func entries(through boundary: Int) -> ArraySlice<Entry> {
    let end = boundary < rowOffsets.count ? rowOffsets[boundary] : entries.count
    // The next heading belongs to an undrawn day when the boundary ends the previous day.
    let includesNextHeading = end > 0 && entries[end - 1].dayCount > 0
    return entries.prefix(end - (includesNextHeading ? 1 : 0))
  }

  func anchor(for entry: HistoryDiaryLayout.EntryID?) -> HistoryItemID? {
    switch entry {
    case .item(let id): positions[id] == nil ? nil : id
    case .day(let date): dayPositions[date].map { items[$0].id }
    case nil: nil
    }
  }
}
