import EnviousWisprCore
import EnviousWisprStorage
import Foundation

/// History paging (#4001 step 3a, #3147 §3.3): the catalog reads 30 items a page, keyed by
/// the tab, search and filters a page was read for, so a page read for one tab or filter is
/// never applied to another.
enum HistoryPaging {
  static let pageSize = HistoryTabState.pageSize

  /// The tab, search and filters a page was read for.
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
}

/// An accepted query result. Selection uses the complete result while the diary draws a page.
struct HistoryQueryResult: Sendable {
  struct Entry: Identifiable, Sendable {
    let id: HistoryDiaryLayout.EntryID
    let position: Int
    let dayCount: Int?
  }

  let key: TranscriptCoordinator.HistoryQueryKey
  /// New for every constructed result (#4586): a later step that started from one stored result
  /// publishes only while that same result is still stored, whatever else changed.
  let identity = UUID()
  let items: [HistoryListItem]
  let positions: [HistoryItemID: Int]
  let ids: Set<HistoryItemID>
  let calendar: Calendar
  let continuation: HistoryCatalog.Cursor?
  let newerContinuation: HistoryCatalog.Cursor?
  let catalogSourceRevision: UInt64?
  let catalogDayCounts: [Date: Int]?
  private let entries: [Entry]
  private let rowOffsets: [Int]
  private let dayPositions: [Date: Int]
  private let dayEntries: [Int]

  init(
    key: TranscriptCoordinator.HistoryQueryKey, items: [HistoryListItem],
    continuation: HistoryCatalog.Cursor? = nil, newerContinuation: HistoryCatalog.Cursor? = nil,
    catalogSourceRevision: UInt64? = nil,
    catalogDayCounts: [Date: Int]? = nil
  ) throws {
    var layout = Layout()
    try Self.layOut(
      items, from: 0, calendar: key.calendar, certified: catalogSourceRevision != nil,
      counts: catalogDayCounts, into: &layout)
    self.init(
      key: key, items: items, layout: layout, ids: Set(layout.positions.keys),
      continuation: continuation, newerContinuation: newerContinuation,
      catalogSourceRevision: catalogSourceRevision, catalogDayCounts: catalogDayCounts)
  }

  private init(
    key: TranscriptCoordinator.HistoryQueryKey, items: [HistoryListItem], layout: Layout,
    ids: Set<HistoryItemID>, continuation: HistoryCatalog.Cursor?,
    newerContinuation: HistoryCatalog.Cursor?, catalogSourceRevision: UInt64?,
    catalogDayCounts: [Date: Int]?
  ) {
    self.key = key
    self.items = items
    self.continuation = continuation
    self.newerContinuation = newerContinuation
    self.catalogSourceRevision = catalogSourceRevision
    self.catalogDayCounts = catalogDayCounts
    calendar = key.calendar
    positions = layout.positions
    self.ids = ids
    entries = layout.entries
    rowOffsets = layout.rowOffsets
    dayPositions = layout.dayPositions
    dayEntries = layout.dayEntries
  }

  /// This result with `added` appended after its last item (#4586 H5), equal to building the
  /// whole list again (`HistoryQueryResultAppendTests`) for date-sorted input. Only the last
  /// day's run and the new items are laid out again; an earlier heading's count is updated
  /// when the merged catalog counts changed it. The arrays are still copied once when this
  /// result is also held elsewhere (copy-on-write); no smaller total cost is claimed.
  func appending(
    _ added: [HistoryListItem], continuation: HistoryCatalog.Cursor?, catalogDayCounts: [Date: Int]?
  ) throws -> HistoryQueryResult {
    var ids = ids
    let fresh = added.filter { ids.insert($0.id).inserted }
    let all = items + fresh
    var layout = Layout(
      positions: positions, entries: entries, rowOffsets: rowOffsets, dayPositions: dayPositions,
      dayEntries: dayEntries)
    var start = items.count
    if let lastHeading = layout.dayEntries.last {
      // Lay the last day's run out again: new items on that day continue it.
      start = layout.entries[lastHeading].position
      layout.dayEntries.removeLast()
      layout.entries.removeSubrange(lastHeading...)
      layout.rowOffsets.removeSubrange(start...)
    }
    let certified = catalogSourceRevision != nil
    let kept = layout.dayEntries.count
    try Self.layOut(
      all, from: start, calendar: calendar, certified: certified, counts: catalogDayCounts,
      into: &layout)
    if certified, catalogDayCounts != self.catalogDayCounts {
      for heading in layout.dayEntries.prefix(kept) {
        try Task.checkCancellation()
        let entry = layout.entries[heading]
        guard case .day(let day) = entry.id else { continue }
        let count = catalogDayCounts?[day]
        if entry.dayCount != count {
          layout.entries[heading] = Entry(id: entry.id, position: entry.position, dayCount: count)
        }
      }
    }
    return HistoryQueryResult(
      key: key, items: all, layout: layout, ids: ids, continuation: continuation,
      newerContinuation: newerContinuation, catalogSourceRevision: catalogSourceRevision,
      catalogDayCounts: catalogDayCounts)
  }

  /// What the list draws from the items: positions, headings and rows in order.
  private struct Layout: Sendable {
    var positions: [HistoryItemID: Int] = [:]
    var entries: [Entry] = []
    var rowOffsets: [Int] = []
    var dayPositions: [Date: Int] = [:]
    /// Indexes into `entries` of every day heading, in order.
    var dayEntries: [Int] = []
  }

  /// Lays out `items` from `start` on, after what `layout` already holds.
  private static func layOut(
    _ items: [HistoryListItem], from start: Int, calendar: Calendar, certified: Bool,
    counts: [Date: Int]?, into layout: inout Layout
  ) throws {
    var index = start
    while index < items.count {
      try Task.checkCancellation()
      let day = calendar.startOfDay(for: items[index].createdAt)
      let end = HistoryDiaryLayout.firstIndex(before: day, in: items, from: index)
      layout.dayPositions[day] = index
      let count = certified ? counts?[day] : end - index
      layout.dayEntries.append(layout.entries.count)
      layout.entries.append(Entry(id: .day(day), position: index, dayCount: count))
      while index < end {
        try Task.checkCancellation()
        let id = items[index].id
        if layout.positions[id] == nil { layout.positions[id] = index }
        layout.rowOffsets.append(layout.entries.count)
        layout.entries.append(Entry(id: .item(id), position: index, dayCount: 0))
        index += 1
      }
    }
  }

  func entries(through boundary: Int) -> ArraySlice<Entry> {
    let end = boundary < rowOffsets.count ? rowOffsets[boundary] : entries.count
    // The next heading belongs to an undrawn day when the boundary ends the previous day.
    let includesNextHeading: Bool
    if end > 0, case .day = entries[end - 1].id {
      includesNextHeading = true
    } else {
      includesNextHeading = false
    }
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

/// #4586 H1: the loop that keeps one History tab's list current for one request (tab, search,
/// filters, grouping). A content publish never cancels a read in flight: the read lands, is
/// shown, and the loop reads once more for the newer content. A read that came back empty (a
/// writer was active, the source moved) is tried again on the next content publish or change
/// notice, never in a tight loop: each (key, notices, source) stamp is attempted once.
@MainActor
struct HistoryRefreshLoop {
  struct Counters: Equatable {
    let content: UInt64
    let notices: UInt64
    let source: UInt64?
  }

  private struct Stamp: Equatable {
    let key: TranscriptCoordinator.HistoryQueryKey
    let notices: UInt64
    let source: UInt64?
  }

  let counters: @MainActor () -> Counters
  let currentKey: @MainActor () -> TranscriptCoordinator.HistoryQueryKey
  /// The key of the result stored for the tab now.
  let storedKey: @MainActor () -> TranscriptCoordinator.HistoryQueryKey?
  let read: @MainActor (TranscriptCoordinator.HistoryQueryKey) async -> Void
  /// Returns once either counter moved from the given values, or on cancellation.
  let wait: @MainActor (_ content: UInt64, _ notices: UInt64) async -> Void

  func run() async {
    var attempted: Stamp?
    while !Task.isCancelled {
      let now = counters()
      let key = currentKey()
      let stamp = Stamp(key: key, notices: now.notices, source: now.source)
      if storedKey() != key, attempted != stamp {
        attempted = stamp
        await read(key)
      }
      await wait(now.content, now.notices)
    }
  }
}

/// #4586 (bug found by the History speed drivers on `acd9e956e`): where a History list opens. The
/// first page shown for the tab's current search and filters restores the tab's saved place (a
/// return to the tab, or Back from an open item); any later change of search or filters starts
/// at the top, even when the saved row is also in the new results. A page for an older search
/// that is still on screen while the new one is read asks for nothing, so the list stays put.
struct HistoryListPlace {
  struct Restore: Equatable {
    let token: Int
    let target: HistoryItemID?
  }

  private var shown: HistoryPaging.Context?
  private var current: Restore?

  /// The restore the list should apply while showing a result for `shownContext`, when the
  /// tab now asks for `requested` and its saved place is `saved`.
  mutating func restore(
    shownContext: HistoryPaging.Context?, requested: HistoryPaging.Context, saved: HistoryItemID?
  ) -> Restore? {
    guard let shownContext, shownContext == requested, shownContext != shown else { return current }
    let first = shown == nil
    shown = shownContext
    current = Restore(token: (current?.token ?? 0) + 1, target: first ? saved : nil)
    return current
  }
}

