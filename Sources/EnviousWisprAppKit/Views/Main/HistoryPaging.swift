import Foundation

/// How much of History's list `TranscriptHistoryView` hands to `List` (#4001 step 3a). On a
/// 27,000-row History a `List` of every item made each search letter and filter switch cost
/// seconds on an M1; the coordinator still decides which items are listed and which is
/// selected, and this only decides how many of them `List` draws: 30, growing by 30.
/// Plain value code, so the paging rules are tested without a view.
enum HistoryPaging {
  static let pageSize = 30

  /// The filter and search a requested limit was set for: a new one starts again at 30.
  struct Context: Equatable {
    let filter: HistoryFilter
    let query: String
  }

  /// The stored request: how many items, for which context.
  struct State: Equatable {
    var requested = HistoryPaging.pageSize
    var context: Context?
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

  /// At least `requested`, and far enough to include a qualifying selection: its position
  /// rounded up to the next page boundary. Never more than `total`.
  static func effectiveCount(requested: Int, selectedIndex: Int?, total: Int) -> Int {
    let throughSelection = selectedIndex.map { ($0 / pageSize + 1) * pageSize } ?? 0
    return min(total, max(requested, throughSelection))
  }

  /// The window `items` give under `context`, `state` and `selected`, computed before `List` is
  /// built, so the selection is inside it without any callback having run.
  static func window(
    items: [HistoryListItem], context: Context, state: State, selected: HistoryItemID?
  ) -> Window {
    let selectedIndex = selected.flatMap { id in items.firstIndex { $0.id == id } }
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
  /// one made for an older window or another context, or one with nothing left to load.
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

  /// The state after the filter or search moved to `context`: a limit already stored for that
  /// context (a load accepted before this ran) is kept; any other starts again at 30.
  static func synchronized(_ state: State, to context: Context) -> State {
    state.context == context ? state : State(requested: pageSize, context: context)
  }
}
