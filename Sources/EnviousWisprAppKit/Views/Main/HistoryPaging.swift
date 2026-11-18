import EnviousWisprCore
import EnviousWisprStorage
import Foundation

/// History paging (#4001 step 3a, #3147 §3.3): the catalog reads 30 items a page, keyed by
/// the tab, search and filters a page was read for, so a page read for one tab or filter is
/// never applied to another.
enum HistoryPaging {
  static let pageSize = HistoryTabState.pageSize

  /// `canPage`: the stored page is for this request, its source is the current one and it has
  /// day counts: the same authority `isCurrentHistoryResult` applies (load more, the newer row).
  /// `isFinal` equals it: such a page's row set is complete for the query (a missing restore
  /// anchor is given up, an empty list is really empty).
  static func finality(
    result: HistoryQueryResult?, key: TranscriptCoordinator.HistoryQueryKey, source: UInt64?
  ) -> (canPage: Bool, isFinal: Bool) {
    let canPage =
      result?.key == key && source != nil && result?.catalogSourceRevision == source
      && result?.catalogDayCounts != nil
    return (canPage, canPage)
  }

  /// An extension may be stored only for the live key and a page of the current, non-nil source
  /// that carries day counts. An older page can come back without counts when a file fails
  /// verification before the watcher reports the change; storing it would replace the good page
  /// and, since paging needs counts, hide "Load more" until a refresh. Keeping the page is correct.
  static func extensionMayStore(
    _ next: HistoryQueryResult, liveKey: TranscriptCoordinator.HistoryQueryKey, source: UInt64?
  ) -> Bool {
    next.key == liveKey && source != nil && next.catalogSourceRevision == source
      && next.catalogDayCounts != nil
  }

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

  /// Whether `other` lists exactly this page for the same request and source (#4586 N1): the
  /// same items with the same catalog content, continuations and day counts. Its key's content
  /// revision may differ.
  func samePage(as other: HistoryQueryResult) -> Bool {
    guard key.request == other.key.request, catalogSourceRevision == other.catalogSourceRevision,
      continuation == other.continuation, newerContinuation == other.newerContinuation,
      catalogDayCounts == other.catalogDayCounts, items.count == other.items.count
    else { return false }
    for (mine, theirs) in zip(items, other.items) {
      guard case .catalog(let left) = mine, case .catalog(let right) = theirs, left == right else {
        return false
      }
    }
    return true
  }

  /// This page under `key` (the content revision a newer read of the same page carried), with a
  /// new identity and the same arrays, so recording its freshness rebuilds nothing.
  func restamped(key: TranscriptCoordinator.HistoryQueryKey) -> HistoryQueryResult {
    HistoryQueryResult(
      key: key, items: items,
      layout: Layout(
        positions: positions, entries: entries, rowOffsets: rowOffsets, dayPositions: dayPositions,
        dayEntries: dayEntries),
      ids: ids, continuation: continuation, newerContinuation: newerContinuation,
      catalogSourceRevision: catalogSourceRevision, catalogDayCounts: catalogDayCounts)
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
/// shown, and the loop reads once more for the newer content. A first-page read is shown even
/// when a writer was active, and read again when its source differs from the current one. A
/// read returns nothing only when cancelled, unwanted (search or filters changed), failed, or
/// for an extension whose source moved; it is tried again on the next content publish or change
/// notice, never in a tight loop: each (key, notices, source) stamp is attempted once.
/// A stored page whose source stamp differs from the current source is read again (the source
/// gates authority, not display). A key change reads at once; a source-only difference reads at
/// most once per `sourcePace`, measured from the end of the previous read and never reset by
/// notices, so a burst gives one trailing read and sustained writes a bounded rate.
@MainActor
struct HistoryRefreshLoop {
  /// Runs first on every pass, before any read (#4586 N1: a kept page's rows are re-checked
  /// against their files on every wake, not while drawing).
  let beforeRead: @MainActor () async -> Void
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
  /// The source revision the stored result was read from.
  let storedSource: @MainActor () -> UInt64?
  let read: @MainActor (TranscriptCoordinator.HistoryQueryKey) async -> Void
  /// Returns once either counter moved from the given values, or on cancellation.
  let wait: @MainActor (_ content: UInt64, _ notices: UInt64) async -> Void
  /// Sleeps for the duration, or returns early on cancellation.
  let pace: @MainActor (Duration) async -> Void
  let now: @MainActor () -> ContinuousClock.Instant

  static let sourcePace = Duration.milliseconds(250)

  func run() async {
    var attempted: Stamp?
    var paceDeadline: ContinuousClock.Instant?
    while !Task.isCancelled {
      let sampled = counters()
      let key = currentKey()
      await beforeRead()
      let stamp = Stamp(key: key, notices: sampled.notices, source: sampled.source)
      let needsKey = storedKey() != key
      let needsSource = !needsKey && storedSource() != sampled.source
      if needsKey || needsSource, attempted != stamp {
        if needsSource, let deadline = paceDeadline, now() < deadline {
          await pace(deadline - now())
          continue
        }
        attempted = stamp
        await read(key)
        paceDeadline = now() + Self.sourcePace
      }
      await wait(sampled.content, sampled.notices)
    }
  }
}

/// The one extension (older or newer page) read in flight for a tab, owned by a per-request
/// token: only the task holding the current token may release the slot, so a stale task (after a
/// tab switch away and back) cannot clear a newer request's claim.
struct HistoryExtensionSlot {
  private var held: (token: UUID, cursor: HistoryCatalog.Cursor)?

  var isClaimed: Bool { held != nil }

  /// A new token, or nil while another request holds the slot.
  mutating func claim(_ cursor: HistoryCatalog.Cursor) -> UUID? {
    guard held == nil else { return nil }
    let token = UUID()
    held = (token, cursor)
    return token
  }

  /// Clears the slot and returns true only when `token` still owns it.
  mutating func release(_ token: UUID) -> Bool {
    guard held?.token == token else { return false }
    held = nil
    return true
  }

  /// True while `token` still owns the slot (not released, cleared or superseded).
  func owns(_ token: UUID) -> Bool { held?.token == token }

  /// A tab switch drops any claim.
  mutating func clear() { held = nil }
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

/// #4586 N1: re-checks a kept page's rows against their files off the drawing path, and drops
/// the answer when anything it was computed from moved before it finished: the tab's key, the
/// change notices, the source revision, the grouping, or the stored page itself.
@MainActor
struct HistoryRetainedVerification {
  struct Stamp: Equatable {
    let key: TranscriptCoordinator.HistoryQueryKey
    let notices: UInt64
    let source: UInt64?
    let grouping: Int
    let stored: UUID
  }

  /// The stamp to verify under now, or nil when no kept page needs checking.
  let stamp: @MainActor () -> Stamp?
  let stored: @MainActor () -> HistoryQueryResult?
  let verify: @MainActor (HistoryQueryResult) async -> HistoryQueryResult?
  let store: @MainActor (HistoryQueryResult) -> Void

  /// Verifies once for a stamp not yet `done`; returns the stamp now done. A dropped answer
  /// leaves `done` as it was, so the newer change is verified on its own wake.
  func run(done: Stamp?) async -> Stamp? {
    guard let before = stamp(), before != done, let saved = stored(),
      saved.identity == before.stored
    else { return done }
    guard let verified = await verify(saved), !Task.isCancelled, stamp() == before,
      stored()?.identity == before.stored
    else { return done }
    store(verified)
    return stamp()
  }
}
