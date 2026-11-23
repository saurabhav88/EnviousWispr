import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Observation

/// What History's browser needs from the writer (#4586 N6): the catalog session, the clock rows
/// are judged at, the meeting-record lookup, and payload hydration. Each is read at its use.
@MainActor
protocol HistoryBrowserWriter: AnyObject {
  var catalogSession: HistoryCatalogSession? { get }
  var clock: () -> Date { get }
  func historyMeetingRecord(_ id: UUID) -> MeetingRecord?
  func loadCatalogDetail(_ id: UUID, authoritative: Bool) async -> Transcript?
}

/// Reads what each History tab shows from the catalog and says whether a shown result is
/// current (#4586 N6: browse authority, beside `HistoryCatalogSession`). Owned by
/// `TranscriptCoordinator`; every async read holds the writer for its whole run, as it did when
/// these were the writer's own methods.
@MainActor @Observable
final class HistoryBrowser {
  /// The writer whose rows and catalog this browser reads. Weak: the writer owns this browser.
  @ObservationIgnored weak var writer: (any HistoryBrowserWriter)?
  @ObservationIgnored let meetingPresenter: HistoryMeetingPresenter
  @ObservationIgnored let expiry: HistoryExpiryPulse
  /// #3972 R38: a meeting's notes as EnviousMeet holds them (`MeetingDocumentsOwner`,
  /// observable there), searched with its finished transcript. Nil searches no notes.
  @ObservationIgnored var meetingHistoryDrafts: (@MainActor () -> [UUID: String])?
  @ObservationIgnored var meetingNotes: (@MainActor (UUID) -> String?)?
  /// #4286: a meeting's invited people as search terms (each name, email and email domain), as
  /// EnviousMeet holds them (`MeetingDocumentsOwner`, observable there). Nil searches none.
  @ObservationIgnored var meetingInvited: (@MainActor (UUID) -> [String])?

  init(meetingPresenter: HistoryMeetingPresenter, expiry: HistoryExpiryPulse) {
    self.meetingPresenter = meetingPresenter
    self.expiry = expiry
  }

  /// The writer's catalog session, read at each use (#4586 N6).
  private var catalogSession: HistoryCatalogSession? { writer?.catalogSession }

  // MARK: - History tabs (#3147 §3.3)

  /// The History tab on screen. Set through `selectHistoryTab(_:)`, which also remembers it.
  private(set) var historyTab: HistoryTab = .dictations
  /// Each tab's own search, filters, open item and paging; a tab never resets another.
  private var historyTabStates: [HistoryTab: HistoryTabState] = [:]
  /// Remembers the chosen tab across launches (`SettingsManager.lastHistoryTab`). Nil in tests.
  @ObservationIgnored var onHistoryTabSelected: (@MainActor (HistoryTab) -> Void)?

  /// Opens History on `tab` at launch without saving it again.
  func restoreHistoryTab(_ tab: HistoryTab) {
    historyTab = tab
  }

  /// Switches History to `tab` and remembers the choice.
  func selectHistoryTab(_ tab: HistoryTab) {
    guard historyTab != tab else { return }
    historyTab = tab
    onHistoryTabSelected?(tab)
  }

  func requestedHistoryState(for tab: HistoryTab) -> HistoryTabState {
    historyTabStates[tab] ?? HistoryTabState()
  }

  /// Replaces `tab`'s state. A changed search or filter starts again at the top.
  func setHistoryState(_ state: HistoryTabState, for tab: HistoryTab) {
    var next = state
    let previous = historyTabStates[tab] ?? HistoryTabState()
    if previous.query != next.query || previous.listFilter != next.listFilter {
      next.scrollAnchorID = nil
    }
    historyTabStates[tab] = next
  }

  /// One page of `key`'s list from the catalog, or `previous` extended by the next one.
  func historyResults(
    for key: HistoryQueryKey, extending previous: HistoryQueryResult? = nil, newer: Bool = false
  ) async -> HistoryQueryResult? {
    let writerLifetime = writer
    defer { withExtendedLifetime(writerLifetime) {} }
    if let catalogSession {
      let tab = key.context.tab
      // #4586 H1: a replacement read survives a content publish (same request, same source); an
      // extension must still match the live key exactly, so pages from two content
      // generations are never joined.
      let stillWanted = { [self] () -> Bool in
        let live = historyQueryKey(for: tab, state: requestedHistoryState(for: tab))
        return previous == nil ? live.request == key.request : (live == key && previous?.key == key)
      }
      guard stillWanted() else { return nil }
      guard let query = await catalogQuery(for: key) else { return nil }
      let anchor = requestedHistoryState(for: tab).scrollAnchorID
      let anchorID = anchor.map { id in
        switch id {
        case .transcript(let value), .meeting(let value): value
        }
      }
      // #4586 package I: the read is registered from here to the end, so a full pass lets the
      // whole page (read and build) go first.
      let readID = catalogSession.beginPageRead()
      defer { catalogSession.endPageRead(readID) }
      // The source revision gates authority, not display. A first page samples one admission
      // (revision plus whether a writer is open) before the read and is shown whatever the
      // source does afterwards, stamped with that revision; it is current only while the stamp
      // equals the current source and it has day counts. An unsettled admission can never
      // equal a later stable source, so such a page is display-only (no counts, no paging). An
      // extension joins only a page of the same, non-nil source.
      let admitted = previous == nil ? catalogSession.admission() : nil
      let source: UInt64
      if let admitted {
        source = admitted.revision
        guard stillWanted() else { return nil }
      } else {
        guard let stable = catalogSession.stableSourceRevision,
          previous?.catalogSourceRevision == stable, stillWanted()
        else { return nil }
        source = stable
      }
      let interval = HistorySignpost.signposter.beginInterval("HistoryPage")
      let read: HistoryCatalog.Page?
      do {
        read = try await catalogSession.page(
          query, after: newer ? previous?.newerContinuation : previous?.continuation,
          restoring: previous == nil ? anchorID : nil, newer: newer, admitted: admitted)
      } catch {
        HistorySignpost.signposter.endInterval("HistoryPage", interval, "failed")
        HistorySignpost.event("HistoryPageFailed")
        return nil
      }
      guard let page = read, !Task.isCancelled,
        admitted != nil || source == catalogSession.stableSourceRevision, stillWanted()
      else {
        HistorySignpost.signposter.endInterval("HistoryPage", interval, "superseded")
        HistorySignpost.event("HistoryPageSuperseded")
        return nil
      }
      HistorySignpost.signposter.endInterval("HistoryPage", interval, "accepted")
      // A save that opened (or any source move) after admission can overlap the read, so the
      // page is display-only unless admission was settled and the source did not move since.
      let after = catalogSession.admission()
      let displayOnly = admitted.map { !$0.settled || after.revision != $0.revision } ?? false
      // #4586 H5: the result is built off the main actor (`@concurrent`), then the request
      // checks run again (and, for an extension, the source check) before it is returned.
      let built = await Self.buildResult(
        key: key, page: page, previous: previous, newer: newer, source: source,
        displayOnly: displayOnly)
      #if DEBUG
        await afterBuildResultForTesting?()
      #endif
      guard let built, !Task.isCancelled,
        admitted != nil || source == catalogSession.stableSourceRevision, stillWanted()
      else {
        // The read itself was accepted (its interval ended); the result is refused because the
        // request (or, for an extension, the source) moved while it was built.
        HistorySignpost.event("HistoryPageSuperseded")
        return nil
      }
      return built
    }
    // Production always has a catalog session (`WisprBootstrapper`); without one nothing is listed.
    return nil
  }

  /// Builds the result for one page off the main actor (#4586 H5): the first page laid out
  /// whole, an older page appended incrementally, a newer page (rare: restoring upward) laid out
  /// whole again. `@concurrent` is the mechanism; `onMainThread` lets a test observe it.
  @concurrent nonisolated static func buildResult(
    key: HistoryQueryKey, page: HistoryCatalog.Page, previous: HistoryQueryResult?, newer: Bool,
    source: UInt64, displayOnly: Bool = false, onMainThread: (@Sendable (Bool) -> Void)? = nil
  ) async -> HistoryQueryResult? {
    // `Thread.isMainThread` is unavailable in async code; the C call answers the same question.
    onMainThread?(pthread_main_np() != 0)
    let added = page.summaries.map(HistoryListItem.catalog)
    // An extension joins the stored list, so its counts are certified only when BOTH the stored
    // list and the new page carry counts; one uncertified part leaves the whole list uncertified.
    let counts: [Date: Int]?
    if displayOnly {
      counts = nil
    } else if let previous {
      counts = previous.catalogDayCounts.flatMap { stored in
        page.dayCounts.map { stored.merging($0) { _, new in new } }
      }
    } else {
      counts = page.dayCounts
    }
    guard let previous else {
      // A display-only page (read while a writer was open) shows its rows and nothing that
      // could authorize paging or exact totals.
      return try? HistoryQueryResult(
        key: key, items: added, continuation: displayOnly ? nil : page.continuation,
        newerContinuation: displayOnly ? nil : page.newerContinuation, catalogSourceRevision: source,
        catalogDayCounts: counts, displayOnly: displayOnly)
    }
    if newer {
      var ids = previous.ids
      let fresh = added.filter { ids.insert($0.id).inserted }
      return try? HistoryQueryResult(
        key: key, items: fresh + previous.items, continuation: previous.continuation,
        newerContinuation: page.newerContinuation, catalogSourceRevision: source,
        catalogDayCounts: counts, displayOnly: displayOnly)
    }
    return try? previous.appending(
      added, continuation: page.continuation, catalogDayCounts: counts, displayOnly: displayOnly)
  }

  private func catalogQuery(for context: HistoryPaging.Context, calendar: Calendar = .current) -> HistoryCatalog.Query? {
    guard let clock = writer?.clock else { return nil }
    let app: String?
    switch context.tab {
    case .dictations:
      switch context.filter.app {
      case .all: app = nil
      case .unknown: app = ""
      case .named(let name): app = name
      }
    case .transcripts: app = nil
    case .meetings: app = context.filter.callApp?.rawValue
    }
    return .init(tab: context.tab, search: context.query, dates: context.filter.dateInterval,
      app: app, calendar: calendar, now: clock())
  }

  /// Only open drafts and opted-in echo rows are examined. They replace the corresponding
  /// saved value for the search predicate, and never enter the persisted index.
  private func catalogQuery(
    for key: HistoryQueryKey, context: HistoryPaging.Context? = nil, calendar: Calendar = .current
  ) async -> HistoryCatalog.Query? {
    let writerLifetime = writer
    defer { withExtendedLifetime(writerLifetime) {} }
    let context = context ?? key.context
    guard let base = catalogQuery(for: context, calendar: calendar) else { return nil }
    guard context.tab == .meetings, !context.query.isEmpty,
      !key.draftNotes.isEmpty || !key.echoShown.isEmpty else { return base }
    var records: [UUID: (MeetingRecord, Transcript)] = [:]
    for id in key.draftNotes.keys {
      if let record = writer?.historyMeetingRecord(id), record.state == .ready,
        let row = await writer?.loadCatalogDetail(record.transcriptID, authoritative: false)
      {
        records[id] = (record, row)
      }
    }
    for rowID in key.echoShown {
      if let row = await writer?.loadCatalogDetail(rowID, authoritative: false), let id = row.meetingID,
        let record = writer?.historyMeetingRecord(id), record.state == .ready
      {
        records[id] = (record, row)
      }
    }
    var matches: [UUID: Bool] = [:]
    for (id, pair) in records {
      let (record, row) = pair
      guard !record.deletionRequested else { continue }
      let info = meetingPresenter.meetingInfo?(id)
      let projection = MeetingHistoryPresentation.project(row, info: info, showEcho: key.echoShown.contains(row.id))
      let text: String
      if case .visible(_, let visible) = projection { text = visible } else { text = "" }
      let notes = key.draftNotes[id] ?? meetingNotes?(id)
      matches[id] = Self.matchesSearch(row, query: context.query, text: text, info: info)
        || notes?.localizedCaseInsensitiveContains(context.query) == true
        || (info?.matching(row) != nil
          && (meetingInvited?(id) ?? []).contains { $0.localizedCaseInsensitiveContains(context.query) })
    }
    return .init(tab: base.tab, search: base.search, dates: base.dates, app: base.app,
      calendar: calendar, now: base.now, meetingSearchOverrides: matches)
  }

  func matchingIDs(for result: HistoryQueryResult, day: Date? = nil) async -> [HistoryItemID]? {
    let writerLifetime = writer
    defer { withExtendedLifetime(writerLifetime) {} }
    guard isCurrentHistoryResult(result), let catalogSession else { return nil }
    var context = result.key.context
    if let day, let range = result.calendar.dateInterval(of: .day, for: day) {
      var filter = context.filter
      if let existing = filter.dateInterval {
        guard let clipped = existing.intersection(with: range) else { return [] }
        filter.dateInterval = clipped
      } else {
        filter.dateInterval = range
      }
      context = .init(tab: context.tab, query: context.query, filter: filter)
    }
    guard let query = await catalogQuery(for: result.key, context: context) else { return nil }
    guard let keys = try? await catalogSession.matchingKeys(query),
      isCurrentHistoryResult(result) else { return nil }
    return keys.map { $0.tab == .meetings ? .meeting($0.id) : .transcript($0.id) }
  }

  /// #4598: an older page kept on screen while the current one is read. Each catalog row must
  /// still match its source files (a changed or deleted recording is hidden on its own row), and
  /// the page carries no day totals or continuations, so it cannot page or authorize selection
  /// (`isCurrentHistoryResult` also requires the current source revision).
  /// #4586 N1: the file checks run off the main actor (`@concurrent`), once per change the list
  /// wakes for, never while drawing; the list drops the answer if anything moved meanwhile.
  func retainedHistoryResult(_ saved: HistoryQueryResult) async -> HistoryQueryResult? {
    let writerLifetime = writer
    defer { withExtendedLifetime(writerLifetime) {} }
    return await Self.verifyRetained(saved)
  }

  @concurrent private nonisolated static func verifyRetained(_ saved: HistoryQueryResult) async -> HistoryQueryResult? {
    var items: [HistoryListItem] = []
    for item in saved.items {
      guard !Task.isCancelled else { return nil }
      guard case .catalog(let summary) = item else {
        items.append(item)
        continue
      }
      if (try? summary.sourcesStillMatch()) == true { items.append(item) }
    }
    return try? HistoryQueryResult(key: saved.key, items: items, catalogSourceRevision: saved.catalogSourceRevision, displayOnly: saved.displayOnly)
  }

  func isCurrentHistoryResult(_ result: HistoryQueryResult) -> Bool {
    guard let catalogSession else { return false }
    let ready = result.catalogDayCounts != nil && result.catalogSourceRevision == catalogSession.stableSourceRevision
    return ready && result.key.context.tab == historyTab
      && result.key == historyQueryKey(for: historyTab, state: requestedHistoryState(for: historyTab))
  }

  func isListedMeeting(_ id: UUID, under state: HistoryTabState) -> Bool {
    guard let record = writer?.historyMeetingRecord(id),
      !record.deletionRequested, state.query.isEmpty
    else { return false }
    return Self.matchesFilter(
      state.listFilter, .meeting(HistoryMeetingItem(meetingID: id, record: record, row: nil)))
  }

  func canRenderHistoryItem(_ item: HistoryListItem) -> Bool {
    guard let clock = writer?.clock else { return false }
    switch item {
    case .transcript(let row):
      return HistoryRowVisibility.isVisible(row, at: clock())
    case .meeting(let meeting):
      if let record = writer?.historyMeetingRecord(meeting.meetingID) {
        return !record.deletionRequested
      }
      return meeting.record == nil
    case .catalog(let summary):
      if let expiry = summary.expiresAt, expiry <= clock() { return false }
      if summary.key.tab == .meetings, writer?.historyMeetingRecord(summary.key.id)?.deletionRequested == true {
        return false
      }
      return true
    }
  }

  /// The calendar uses the same query, with its date range omitted.
  func historyActivity(in tab: HistoryTab, calendar: Calendar) async -> [Date: Int] {
    let writerLifetime = writer
    defer { withExtendedLifetime(writerLifetime) {} }
    var state = requestedHistoryState(for: tab)
    state.dateInterval = nil
    if let catalogSession {
      let key = historyQueryKey(for: tab, state: state)
      guard let query = await catalogQuery(for: key, calendar: calendar) else { return [:] }
      let counts = try? await catalogSession.activity(query)
      var current = requestedHistoryState(for: tab)
      current.dateInterval = nil
      guard !Task.isCancelled, key == historyQueryKey(for: tab, state: current) else { return [:] }
      return counts ?? [:]
    }
    return [:]
  }

  func historyAppOptions() async -> [HistoryFilterLabels.AppOption] {
    let writerLifetime = writer
    defer { withExtendedLifetime(writerLifetime) {} }
    if let catalogSession, let clock = writer?.clock {
      let counts = (try? await catalogSession.appCounts(now: clock())) ?? []
      return HistoryFilterLabels.appOptions(counts: counts)
    }
    return []
  }

  /// Everything the query uses from the live owners.
  ///
  /// #4586 H1: two parts with two jobs. `request` is what the reader asked for (tab, search,
  /// filters, echo choices, drafts, expiry pulse, locale): a change starts a new read. `revision`
  /// is the catalog content revision the read started under: it is the freshness proof a result
  /// carries, so a page overtaken by a content publish still displays but cannot authorize
  /// selection, paging or open (`isCurrentHistoryResult`) until the follow-up read lands.
  struct HistoryQueryKey: Equatable, Sendable {
    let revision: Int
    let request: Request

    struct Request: Equatable, Sendable {
      let pulse: Int
      let context: HistoryPaging.Context
      let echoShown: Set<UUID>
      let locale: String
      let localizations: [String]
      let calendar: Calendar
      let draftNotes: [UUID: String]
    }

    init(
      revision: Int, pulse: Int, context: HistoryPaging.Context, echoShown: Set<UUID>,
      locale: String, localizations: [String], calendar: Calendar, draftNotes: [UUID: String] = [:]
    ) {
      self.revision = revision
      request = Request(
        pulse: pulse, context: context, echoShown: echoShown, locale: locale,
        localizations: localizations, calendar: calendar, draftNotes: draftNotes)
    }

    var pulse: Int { request.pulse }
    var context: HistoryPaging.Context { request.context }
    var echoShown: Set<UUID> { request.echoShown }
    var locale: String { request.locale }
    var localizations: [String] { request.localizations }
    var calendar: Calendar { request.calendar }
    var draftNotes: [UUID: String] { request.draftNotes }
  }

  /// The key `tab`'s list is read under now: the request plus the catalog content revision.
  func historyQueryKey(for tab: HistoryTab, state: HistoryTabState) -> HistoryQueryKey {
    HistoryQueryKey(
      revision: Int(truncatingIfNeeded: catalogSession?.revision ?? 0), pulse: expiry.expiryPulse,
      context: HistoryPaging.Context(tab: tab, state: state),
      echoShown: tab == .meetings ? meetingPresenter.echoShownRowIDs : [], locale: Locale.current.identifier,
      localizations: Bundle.main.preferredLocalizations, calendar: .current,
      draftNotes: tab == .meetings && !state.query.isEmpty ? (meetingHistoryDrafts?() ?? [:]) : [:])
  }

  /// Whether `item` passes a History tab's filters (#3147 §3.3). A filter a kind does not carry
  /// (App on a meeting, Call app on a dictation) never lets that item through once it is set.
  private nonisolated static func matchesFilter(_ filter: HistoryListFilter, _ item: HistoryListItem) -> Bool {
    if let interval = filter.dateInterval {
      // Start-inclusive, end-exclusive: a day ending at the next midnight never takes the next
      // day's first instant (`DateInterval.contains` includes its end).
      guard item.createdAt >= interval.start, item.createdAt < interval.end else { return false }
    }
    switch filter.app {
    case .all: break
    case .unknown:
      guard case .transcript(let row) = item, !row.isImported,
        (row.metrics?.targetApp ?? "").isEmpty
      else { return false }
    case .named(let app):
      guard case .transcript(let row) = item, !row.isImported, row.metrics?.targetApp == app
      else { return false }
    }
    if let callApp = filter.callApp {
      guard case .meeting(let meeting) = item, meeting.record?.callApp == callApp else {
        return false
      }
    }
    return true
  }

  private nonisolated static func matchesSearch(
    _ row: Transcript, query: String, text: @autoclosure () -> String, info: MeetingHistoryInfo?
  ) -> Bool {
    // Held recovery rows remain browseable without appearing in search.
    row.escapeRecoveredAt == nil
      && (text().localizedCaseInsensitiveContains(query)
        || (row.customTitle?.localizedCaseInsensitiveContains(query) ?? false)
        || (row.importedFileName?.localizedCaseInsensitiveContains(query) ?? false)
        || (info?.title?.localizedCaseInsensitiveContains(query) ?? false)
        || (row.speakerNames?.values.contains { $0.localizedCaseInsensitiveContains(query) } ?? false))
  }

  /// Shows the Meetings tab with no search or filters and opens `meetingID` when given (#3972
  /// R45, #3147 PR2): the menu's "Show Live Preview" and "Show in History", and the EnviousMeet
  /// page's "Show recordings". The caller brings History forward.
  func showMeetings(meetingID: UUID? = nil) {
    var state = HistoryTabState()
    state.openItemID = meetingID.map { .meeting($0) }
    historyTabStates[.meetings] = state
    selectHistoryTab(.meetings)
  }

  #if DEBUG
    /// Runs in `historyResults` after the result is built off the main actor and before its
    /// freshness checks (#4586 package I): a change here lands while the result was built.
    @ObservationIgnored var afterBuildResultForTesting: (@MainActor () async -> Void)?
  #endif
}
