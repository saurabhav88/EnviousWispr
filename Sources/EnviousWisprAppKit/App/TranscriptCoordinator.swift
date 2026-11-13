import CryptoKit
import EnviousWisprCore
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Observation

/// Manages transcript history state, search, and persistence.
@MainActor @Observable
final class TranscriptCoordinator {
  /// The unfiltered store, PRIVATE (#2087).
  ///
  /// Read-time expiry only works if consumers honour it, and every consumer
  /// reading this array directly bypassed it silently — the code compiled, the
  /// list rendered, and the only symptom was a held recovery still reachable
  /// past the 24 hours the user was promised. Three sites did exactly that.
  ///
  /// Guarding it was tried and is not enough: a scanner over the source can
  /// match a name, not a type, so it flags an unrelated `transcripts` elsewhere
  /// and misses a bare access from an extension. The compiler makes the mistake
  /// unavailable instead. Read `visibleTranscripts` or `matchingHistoryItems(in:)`.
  private var transcripts: [Transcript] = [] {
    // Every mutation (assignment, insert, subscript, removeAll) passes here, so the list key
    // sees it without each mutation site remembering to (#4001).
    didSet { transcriptsRevision &+= 1 }
  }
  /// Bumped on every change to `transcripts`: part of the kept list's key (#4001).
  private(set) var transcriptsRevision = 0
  /// #3972 R45: EnviousMeet's meetings, newest first, as its coordinator holds them durably
  /// (`MeetingCoordinator.meetings`, observable there). Every meeting is listed under
  /// Recordings from Start to deletion, with its History row when it has one. Nil (tests, or
  /// before wiring) lists meeting rows only.
  @ObservationIgnored var meetingRecords: (@MainActor () -> [MeetingRecord])?
  /// #3972 R38: a meeting's notes as EnviousMeet holds them (`MeetingDocumentsOwner`,
  /// observable there), searched with its finished transcript. Nil searches no notes.
  @ObservationIgnored var meetingNotes: (@MainActor (UUID) -> String?)?
  /// #4286: a meeting's invited people as search terms (each name, email and email domain), as
  /// EnviousMeet holds them (`MeetingDocumentsOwner`, observable there). Nil searches none.
  @ObservationIgnored var meetingInvited: (@MainActor (UUID) -> [String])?

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

  /// `tab`'s state. An open item or scroll anchor that is no longer listed reads as nil, so a
  /// deleted, expired or filtered-out item never stays open.
  func historyState(for tab: HistoryTab) -> HistoryTabState {
    var state = historyTabStates[tab] ?? HistoryTabState()
    guard state.openItemID != nil || state.scrollAnchorID != nil else { return state }
    let listed = Set(matchingHistoryItems(in: tab, state: state).map(\.id))
    if let open = state.openItemID, !listed.contains(open) { state.openItemID = nil }
    if let anchor = state.scrollAnchorID, !listed.contains(anchor) { state.scrollAnchorID = nil }
    return state
  }

  /// Replaces `tab`'s state. A changed search or filter starts paging again from the top.
  func setHistoryState(_ state: HistoryTabState, for tab: HistoryTab) {
    var next = state
    let previous = historyTabStates[tab] ?? HistoryTabState()
    if previous.query != next.query || previous.listFilter != next.listFilter {
      next.requestedCount = HistoryTabState.pageSize
      next.scrollAnchorID = nil
    }
    historyTabStates[tab] = next
  }

  /// Every item `tab` lists now under its search and filters, all pages, newest first, with the
  /// same visibility, expiry and deletion rules as every History list. Paging only limits drawing.
  func matchingHistoryItems(in tab: HistoryTab) -> [HistoryListItem] {
    matchingHistoryItems(in: tab, state: historyTabStates[tab] ?? HistoryTabState())
  }

  private func matchingHistoryItems(in tab: HistoryTab, state: HistoryTabState)
    -> [HistoryListItem]
  {
    let now = clock()
    let key = listKey(
      at: now, kind: HistoryListKind(tab), filter: state.listFilter, query: state.query)
    #if DEBUG
      if listCacheDisabledForTesting { return buildListedItems(at: now, from: key) }
    #endif
    if let kept = tabListCache[tab], kept.key == key { return kept.items }
    let kept = KeptList(key: key, items: buildListedItems(at: now, from: key))
    tabListCache[tab] = kept
    // #4001: the meeting text cache drops rows that are gone, once per row change, on the list
    // path production reads (Codex PR2 r5: it used to sit on the retired all-kinds list).
    if prunedRevision != transcriptsRevision {
      meetingDocuments.prune(keeping: transcripts)
      prunedRevision = transcriptsRevision
    }
    return kept.items
  }

  /// The row revision the meeting text cache was last pruned at.
  @ObservationIgnored private var prunedRevision = -1

  /// How many of `tab`'s items fall on each day under its search and other filters (the date
  /// filter left out), for the calendar's activity dots. Days are `calendar`'s start of day.
  /// The dates are read here; grouping runs off the main actor.
  func historyActivity(in tab: HistoryTab, calendar: Calendar) async -> [Date: Int] {
    var state = historyTabStates[tab] ?? HistoryTabState()
    state.dateInterval = nil
    let dates = matchingHistoryItems(in: tab, state: state).map(\.createdAt)
    return await Task.detached(priority: .userInitiated) {
      var counts: [Date: Int] = [:]
      for date in dates { counts[calendar.startOfDay(for: date), default: 0] += 1 }
      return counts
    }.value
  }

  /// Each tab's kept list (#4001's cache, one per tab). Not observed: storing it while a view reads
  /// the list is not a change anyone needs to see.
  @ObservationIgnored private var tabListCache: [HistoryTab: KeptList] = [:]

  /// Re-render pulse for pending Escape Recovery rows (#2087).
  ///
  /// This type has no clock, and Observation redraws on a STATE change — a
  /// remaining-time computed from `Date()` is not one. Without a pulse a row
  /// would keep showing whatever it said when something else last mutated
  /// state, and an expired row would stay on screen until an unrelated edit
  /// happened to refresh it. Reading this in a view is what subscribes it.
  ///
  /// Only runs while a live pending row exists, so the ordinary case — feature
  /// off, or no recovery held — has no timer at all.
  private(set) var expiryPulse: Int = 0

  @ObservationIgnored private let transactionExecutor: HistoryTransactionExecutor
  /// #3147: saved dictation recordings, changed only through this coordinator's command queue.
  /// Nil when no archive was given (tests that do not exercise recordings).
  @ObservationIgnored let recordings: DictationRecordings?
  @ObservationIgnored private let diskReconciler: HistoryDiskReconciler
  @ObservationIgnored private let meetingDocuments = HistoryMeetingDocumentCache()

  #if DEBUG
    var transactionExecutorForTesting: HistoryTransactionExecutor { transactionExecutor }
    var meetingDocumentCacheForTesting: HistoryMeetingDocumentCache { meetingDocuments }
  #endif

  var diskReconcilerForTesting: HistoryDiskReconciler { diskReconciler }
  private let pendingPulseInterval: Duration
  private let pendingPulseSleep: @Sendable (Duration) async -> Void

  /// Escape Recovery telemetry emitters, injected (#2087).
  ///
  /// Seams rather than direct `TelemetryService.shared` calls, so a test can
  /// assert an event fired with the right take id and age WITHOUT reaching the
  /// network client — and so the events are observable at all, since the funnel
  /// is the instrument that decides whether this feature earns its keep.
  private let emitEscapeRecoveryKept: (_ ageMs: Int, _ takeID: String) -> Void
  private let emitEscapeRecoveryExpired: (_ ageMs: Int, _ takeID: String) -> Void
  private let emitEscapeRecoveryRestoredFromHistory: (_ ageMs: Int, _ takeID: String) -> Void
  private let recordEscapeRecoveryKeep: @MainActor (_ outcome: String, _ takeID: String?) -> Void
  /// #2811, phase 4 of #2807 §3e — same seam-not-direct-call reason as the escape-recovery
  /// emitters above, but with NO-OP defaults rather than a fallback to the shared service:
  /// these mirror `FileImportCoordinator`'s emitters for the same feature, and both screens'
  /// production wiring lives side by side in `WisprBootstrapper` (found by chunk review).
  private let emitRenameTelemetry: (_ outcome: TelemetryService.FileImportRenameOutcome) -> Void
  private let emitTurnsDisplayedTelemetry: () -> Void
  /// Documents whose turn view History has already drawn this launch (#2811 §3e).
  private var displayedTurnIDs: Set<UUID> = []
  /// Called after a row is deleted here, with its id. Set by the bootstrapper once both
  /// coordinators exist, since this one is built first: the file-import coordinator uses it
  /// to drop the audio it holds for a possible speaker retry on that row (#2811). Nothing
  /// else observes a deletion; the coordinator's own deleted-row notice stays derived.
  @ObservationIgnored var onRowDeleted: (@MainActor (UUID) -> Void)?
  /// Whether a file import is still settling the turn text of the row with this id: its
  /// cleanup running, or its speaker pass placing words onto freshly persisted turns
  /// (#2851 §3 D, cloud review of PR #2871; `FileImportCoordinator.isSettlingTurns(of:)`).
  /// Set by the bootstrapper like `onRowDeleted`; nil reads false. History's detail view asks
  /// it so a raw turn is not disclosed as "Not fully polished" before it is a verdict. The
  /// closure reads the import coordinator's observed state, so a redraw follows.
  @ObservationIgnored var isImportInProgress: (@MainActor (UUID) -> Bool)?
  /// #3972 R12: EnviousMeet is the one deletion authority for a meeting's row. History's delete
  /// of a meeting row hands the meeting id here instead of deleting; EnviousMeet marks the
  /// meeting, removes the row through `removeRow(id:)` and then the meeting folder. Nil (tests,
  /// or before wiring) deletes the row the ordinary way.
  /// True when EnviousMeet deleted the meeting (or a deletion it already owns is under way),
  /// false when it could not now (#4079); History says so. Awaited, never inferred from the
  /// list (#3147 PR2).
  @ObservationIgnored var deleteMeeting: (@MainActor (UUID) async -> Bool)?
  /// #3147 PR2: Delete recordings only for one meeting, as EnviousMeet reports it (active
  /// meetings are skipped, meetings with no audio left are already absent). Nil fails.
  @ObservationIgnored var deleteMeetingAudio: (@MainActor (UUID) async -> HistoryDeleteOutcome)?
  /// #3972 R19: called by Delete All with every meeting id among the rows, BEFORE the store is
  /// emptied, so each meeting is marked for deletion first and a crash cannot leave a finished
  /// meeting whose History row is gone.
  /// Returns false when any meeting could not be marked; Delete All then refuses its bulk
  /// removal, so no meeting is left with audio but no row and no mark to finish its deletion.
  /// Async (#4102): the marks are awaited, not waited for on the main actor.
  @ObservationIgnored var meetingsWillBeDeletedWithAll: (@MainActor ([UUID]) async -> Bool)?
  /// #3972 R5/R19: a meeting's History facts (echo turns, title, speaker outcomes), by meeting
  /// id, from EnviousMeet's in-memory durable copy. Observable on that side, so a view that
  /// reads it redraws when the meeting changes. Nil (tests, or before wiring) and an unknown
  /// meeting both fail closed: the row shows nothing.
  @ObservationIgnored var meetingInfo: (@MainActor (UUID) -> MeetingHistoryInfo?)?
  /// Rows whose probable echo is shown (#3972 R19). Per row and in memory only: one row's
  /// choice never reaches another, and every row starts hidden.
  private(set) var echoShownRowIDs: Set<UUID> = []
  /// #4001 H12: a History read that was still the current one has ended at least once this
  /// launch, successfully or not. It says an attempt finished, never that the rows are complete
  /// or that a given row is there. Never reset: later reads refresh rows in place.
  private(set) var historyReadFinished = false
  private var pulseTask: Task<Void, Never>?

  /// Rows that are still OFFERED, at read time (#2087).
  ///
  /// Read-time expiry is authoritative: a pending row at or past its retention
  /// window is never rendered, searched or counted, whether or not the sweep
  /// that deletes its file has run. The sweep reclaims disk; this decides
  /// visibility. Tying visibility to the sweep would leave an expired row on
  /// screen whenever the sweep failed, threw, or had not run yet.
  var visibleTranscripts: [Transcript] {
    // Reading the pulse HERE is what makes the redraw work, and it is load
    // bearing rather than decorative. Observation invalidates a view when a
    // property the view READ changes; this result depends on `Date()`, which
    // Observation cannot see. Touching `expiryPulse` during the read makes
    // every consumer of this list a subscriber to the pulse automatically,
    // instead of relying on each view to remember to read a counter whose
    // relevance is not obvious from its name.
    _ = expiryPulse
    let now = clock()
    return transcripts.filter { Self.isVisible($0, at: now) }
  }

  /// The time the list, its counts and row visibility are judged at; tests set it to step
  /// across an expiry boundary without sleeping (#4001).
  @ObservationIgnored var clock: () -> Date = Date.init

  private struct KeptList {
    let key: ListKey
    let items: [HistoryListItem]
  }

  /// Everything `buildListedItems` and the search read, captured at one `now` (#4001).
  private struct ListKey: Equatable {
    let revision: Int
    let pulse: Int
    let kind: HistoryListKind
    let filter: HistoryListFilter
    let query: String
    let echoShown: Set<UUID>
    let meetings: [MeetingRecord]
    /// The visibility, at `now`, of each held (pending) row, in list order: an expiry between
    /// pulses changes the key.
    let pendingVisible: [Bool]
    /// While searching: every meeting row's facts and notes (a held row's too), read before
    /// the search runs, so a meeting that does not match yet is still watched. The build reads
    /// them from here and never asks the closures again.
    let searchFacts: [SearchFact]?
    let locale: String
    let localizations: [String]
  }

  private struct SearchFact: Equatable {
    let meetingID: UUID
    let info: MeetingHistoryInfo?
    let notes: String?
    /// #4286: the meeting's invited search terms.
    let invited: [String]
  }

  /// The key for one list: its kind, filters and search, plus every input the build reads.
  private func listKey(
    at now: Date, kind: HistoryListKind, filter: HistoryListFilter, query searchQuery: String
  ) -> ListKey {
    _ = expiryPulse
    let index = rowIndex
    let pendingVisible = index.pending.map { Self.isVisible(transcripts[$0], at: now) }
    let meetingRowIDs = index.meetingRowIDs
    let facts: [SearchFact]? =
      searchQuery.isEmpty
      ? nil
      : meetingRowIDs.map {
        SearchFact(
          meetingID: $0, info: meetingInfo?($0), notes: meetingNotes?($0),
          invited: meetingInvited?($0) ?? [])
      }
    return ListKey(
      revision: transcriptsRevision, pulse: expiryPulse, kind: kind, filter: filter,
      query: searchQuery,
      echoShown: echoShownRowIDs, meetings: meetingRecords?() ?? [], pendingVisible: pendingVisible,
      searchFacts: facts, locale: Locale.current.identifier,
      localizations: Bundle.main.preferredLocalizations)
  }

  /// Where the held rows sit in `transcripts` and which meetings have a row, rebuilt only when
  /// the rows change (#4001), so checking the kept list does not scan every row.
  private var rowIndex: RowIndex {
    let revision = transcriptsRevision
    #if DEBUG
      let reuse = !listCacheDisabledForTesting
    #else
      let reuse = true
    #endif
    if reuse, let kept = rowIndexCache, kept.revision == revision { return kept }
    var pending: [Int] = []
    var meetingRowIDs: [UUID] = []
    for (i, row) in transcripts.enumerated() {
      if row.escapeRecoveredAt != nil { pending.append(i) }
      if let meetingID = row.meetingID { meetingRowIDs.append(meetingID) }
    }
    let index = RowIndex(
      revision: revision, pending: pending, meetingRowIDs: meetingRowIDs,
      meetingRowCounts: meetingRowIDs.reduce(into: [:]) { $0[$1, default: 0] += 1 })
    rowIndexCache = index
    return index
  }

  private struct RowIndex {
    let revision: Int
    let pending: [Int]
    let meetingRowIDs: [UUID]
    /// How many rows each meeting has, held rows included.
    let meetingRowCounts: [UUID: Int]
  }

  @ObservationIgnored private var rowIndexCache: RowIndex?

  #if DEBUG
    /// Builds the list and the meeting search text afresh on every read: the reference the
    /// cache tests compare against.
    @ObservationIgnored var listCacheDisabledForTesting = false
    /// #4001 H4: full list builds, so a test can tell a skipped read from a cache hit.
    @ObservationIgnored private(set) var listBuildsForTesting = 0
  #endif

  /// The list from one key's captured inputs: its time, records, filter, query, echo choices
  /// and meeting facts.
  private func buildListedItems(at now: Date, from key: ListKey) -> [HistoryListItem] {
    #if DEBUG
      listBuildsForTesting += 1
    #endif
    let records = key.meetings
    let visible = transcripts.filter { Self.isVisible($0, at: now) }
    var rowsByMeeting: [UUID: Transcript] = [:]
    var items: [HistoryListItem] = []
    for row in visible {
      if let meetingID = row.meetingID {
        rowsByMeeting[meetingID] = row
      } else {
        items.append(.transcript(row))
      }
    }
    var meetings: [HistoryMeetingItem] = []
    for record in records {
      // Taken out first, so a meeting marked for deletion never comes back as an orphan row
      // while its deletion runs, stalls or failed (Codex C8 r1).
      let row = rowsByMeeting.removeValue(forKey: record.id)
      guard !record.deletionRequested else { continue }
      meetings.append(HistoryMeetingItem(meetingID: record.id, record: record, row: row))
    }
    // A meeting row whose meeting EnviousMeet does not hold (its folder is gone or unreadable)
    // is still a meeting, listed by its meeting id.
    for (meetingID, row) in rowsByMeeting {
      meetings.append(HistoryMeetingItem(meetingID: meetingID, record: nil, row: row))
    }
    let merged = Self.mergeMeetings(meetings, into: items)
    let listed = merged.filter { item in
      Self.matchesKind(key.kind, item) && Self.matchesFilter(key.filter, item)
    }
    guard !key.query.isEmpty else { return listed }
    let facts = Dictionary(
      (key.searchFacts ?? []).map { ($0.meetingID, $0) }, uniquingKeysWith: { first, _ in first })
    func matches(_ row: Transcript) -> Bool {
      matchesSearch(
        row, query: key.query, info: row.meetingID.flatMap { facts[$0]?.info },
        showEcho: key.echoShown.contains(row.id), locale: key.locale,
        localizations: key.localizations)
    }
    return listed.filter { item in
      switch item {
      case .transcript(let row): return matches(row)
      // R35: search covers finished meetings only, by their visible words, title, speaker
      // names, notes and invited people (#4286). A meeting still recording, transcribing (a retry included) or failed is never a
      // match, so an item does not appear and vanish as its state moves.
      case .meeting(let meeting):
        guard let row = meeting.row, meeting.record.map({ $0.state == .ready }) ?? true else {
          return false
        }
        return matches(row)
          || (facts[meeting.meetingID]?.notes?.localizedCaseInsensitiveContains(key.query)
            ?? false)
          // #4286: invited people, only while History may show the meeting's facts.
          || (facts[meeting.meetingID].map { fact in
            fact.info?.matching(row) != nil
              && fact.invited.contains { $0.localizedCaseInsensitiveContains(key.query) }
          } ?? false)
      }
    }
  }

  /// Whether `item` is of the kind a list shows.
  private static func matchesKind(_ kind: HistoryListKind, _ item: HistoryListItem) -> Bool {
    switch (kind, item) {
    case (.dictations, .transcript(let row)): return !row.isImported
    case (.transcripts, .transcript(let row)): return row.isImported
    case (.meetings, .meeting): return true
    case (.dictations, .meeting), (.transcripts, .meeting), (.meetings, .transcript):
      return false
    }
  }

  /// Whether `item` passes a History tab's filters (#3147 §3.3). A filter a kind does not carry
  /// (App on a meeting, Call app on a dictation) never lets that item through once it is set.
  private static func matchesFilter(_ filter: HistoryListFilter, _ item: HistoryListItem) -> Bool {
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
    if let range = filter.speakerCount {
      guard case .transcript(let row) = item, row.isImported,
        let count = row.historySpeakerCount, range.contains(count)
      else { return false }
    }
    if let callApp = filter.callApp {
      guard case .meeting(let meeting) = item, meeting.record?.callApp == callApp else {
        return false
      }
    }
    return true
  }

  private func matchesSearch(
    _ row: Transcript, query searchQuery: String, info: MeetingHistoryInfo?, showEcho: Bool,
    locale: String, localizations: [String]
  ) -> Bool {
    // Pending rows are excluded from search DELIBERATELY: an accidental Escape
    // would otherwise pollute results for 24 hours, and the row is reachable
    // the whole time by scrolling History, which is where the user left it.
    // #2772: the imported file's name is on the row, and it is the thing a person looking
    // for a meeting they transcribed types, so it is searchable. Searching "marketing" for
    // `marketing_sync.wav` removed the row while its badge said the word. Found by the
    // cloud review of PR #2786.
    // #2811, phase 4 of #2807: a renamed speaker's name does not enter `displayText` — the
    // epic's own "find the row with 'Zach, Ariana' on it" walkthrough needs an explicit
    // match against the speaker names themselves, a genuinely new gap this phase closes
    // (plan §6 downstream consumer matrix).
    row.escapeRecoveredAt == nil
      && (searchableText(
        of: row, info: info, showEcho: showEcho, locale: locale, localizations: localizations
      )
      .localizedCaseInsensitiveContains(searchQuery)
        || (row.importedFileName?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        || (info?.title?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        || (row.speakerNames?.values.contains {
          $0.localizedCaseInsensitiveContains(searchQuery)
        } ?? false))
  }

  /// Meetings merged into the newest-first transcript list by start time, without reordering
  /// either list; on a tie the dictation or import goes first.
  private static func mergeMeetings(
    _ meetings: [HistoryMeetingItem], into items: [HistoryListItem]
  ) -> [HistoryListItem] {
    let sortedMeetings = meetings.enumerated().sorted {
      ($0.element.createdAt, -$0.offset) > ($1.element.createdAt, -$1.offset)
    }.map(\.element)
    var result: [HistoryListItem] = []
    result.reserveCapacity(items.count + meetings.count)
    var m = 0
    for item in items {
      while m < sortedMeetings.count, sortedMeetings[m].createdAt > item.createdAt {
        result.append(.meeting(sortedMeetings[m]))
        m += 1
      }
      result.append(item)
    }
    result.append(contentsOf: sortedMeetings[m...].map { .meeting($0) })
    return result
  }

  /// How many dictations exist: every completed row that is not an import, whatever the
  /// filter shows. Onboarding's success detector reads this one.
  var dictationCount: Int {
    _ = expiryPulse
    let now = Date()
    // #3972 R5: a meeting finishing during a practice take is not something the user dictated.
    return transcripts.filter {
      Self.isVisible($0, at: now) && $0.escapeRecoveredAt == nil && !$0.isImported
        && !$0.isMeeting
    }.count
  }

  /// How many rows a Delete All would actually take, from the user's point of
  /// view (#2087).
  ///
  /// Held recoveries are counted: with only held rows on screen a count that excluded them
  /// would read zero, so the dialog would offer to delete "all 0 transcripts" and then delete
  /// them. A confirmation must count what it is about to destroy.
  ///
  /// #3972 R45: a meeting that has no History row yet (recording, transcribing, failed) is
  /// deleted by Delete All too, so it is counted.
  var deletableCount: Int {
    // #4001: the view reads this on every redraw (the Delete All button and its confirmation
    // text), so it reads the row index instead of scanning every row: every row is visible
    // except the held rows whose time has run out.
    #if DEBUG
      if listCacheDisabledForTesting {
        let visible = visibleTranscripts
        let meetingsWithRows = Set(visible.compactMap(\.meetingID))
        return visible.count
          + (meetingRecords?() ?? []).filter { record in
            !record.deletionRequested && !meetingsWithRows.contains(record.id)
          }.count
      }
    #endif
    _ = expiryPulse
    let now = clock()
    let index = rowIndex
    var visibleCount = transcripts.count
    var meetingRowCounts = index.meetingRowCounts
    for i in index.pending where !Self.isVisible(transcripts[i], at: now) {
      visibleCount -= 1
      if let meetingID = transcripts[i].meetingID { meetingRowCounts[meetingID]? -= 1 }
    }
    return visibleCount
      + (meetingRecords?() ?? []).filter { record in
        !record.deletionRequested && (meetingRowCounts[record.id] ?? 0) == 0
      }.count
  }

  /// The Delete All confirmation, assembled HERE rather than in the view.
  ///
  /// Not a style preference. While the view interpolated a count of its own
  /// choosing, the correct count and the wrong one were both in scope and
  /// equally easy to type, and nothing a unit test can reach observed which was
  /// picked — a mutation swapping them survived the whole suite. Owning the
  /// sentence removes the choice from the call site and puts the decision
  /// somewhere a test can see it.
  var deleteAllConfirmationMessage: String {
    let count = deletableCount
    // "all 1 transcripts" is what centralising the sentence without reading it
    // produced, and a test then pinned it. One row is not a plural, and "all"
    // reads as boilerplate when there is nothing to be exhaustive about.
    //
    // #2807: Delete All is GLOBAL while the list can be filtered or searched, so the
    // sentence says that a hidden row goes too. The count is the global one for the same
    // reason: a confirmation must count what it is about to destroy, not what is on screen.
    //
    //
    // #3142: each branch is ONE whole localizable sentence. The count == 1 branch stays in
    // code (not catalog plural forms) because unit tests run outside the app bundle and
    // must still read the English a user sees; a language with more plural forms adds
    // them to the counted sentence in the catalog.
    guard count != 1 else {
      return String(
        localized:
          "This will permanently delete the only item in History, even if a filter or search is hiding it. This action cannot be undone.",
        comment:
          "Delete All confirmation in History when exactly one row exists (it may be hidden by a filter)."
      )
    }
    return String(
      localized:
        "This will permanently delete all \(String(count)) items in History, including any hidden by a filter or search. This action cannot be undone.",
      comment:
        "Delete All confirmation in History. %@ is how many rows will be deleted, including hidden ones. Never 1."
    )
  }

  /// Held rows IN MEMORY whose window has elapsed.
  ///
  /// The pulse's sweep trigger: a direct statement of "there is something to
  /// clean up", which cannot race the way a before/after comparison does.
  ///
  /// Says "in memory" precisely because that is what it reads. An earlier
  /// version of this comment claimed it represented files still on disk, which
  /// was wrong in a way that mattered: swept rows stayed in the array, so it
  /// never returned to zero and the pulse re-swept every minute.
  private var lapsedPendingCount: Int {
    let now = Date()
    return transcripts.filter { $0.escapeRecoveredAt != nil && !Self.isVisible($0, at: now) }.count
  }

  /// Live pending rows — a countdown still worth redrawing.
  private var livePendingCount: Int {
    let now = Date()
    return transcripts.filter { $0.escapeRecoveredAt != nil && Self.isVisible($0, at: now) }.count
  }


  /// A held row is visible only while `PendingAdmission` calls it live.
  /// Permanent rows carry no stamp and are always visible.
  ///
  /// Asked through the shared authority rather than re-derived, for the reason
  /// that type's own documentation gives: two copies of the retention
  /// comparison diverge the moment one side gains a condition the other lacks.
  /// An earlier version of this method compared elapsed time directly and so
  /// omitted future-skew rejection — a clock-skewed stamp would have stayed
  /// visible in History indefinitely while the store refused to return it,
  /// recreating precisely the divergence chunk 5 existed to remove.
  private static func isVisible(_ transcript: Transcript, at now: Date) -> Bool {
    guard let stamped = transcript.escapeRecoveredAt else { return true }
    return PendingAdmission.verdict(stampedAt: stamped, now: now) == .live
  }

  /// - Parameters:
  ///   - pendingPulseInterval: how often a held row's countdown and expiry are
  ///     re-evaluated. One minute: the countdown is rendered in hours, so a
  ///     minute bounds staleness three orders of magnitude below the window it
  ///     measures, while costing one wakeup a minute and only while a row is
  ///     actually being held.
  ///   - pendingPulseSleep: the wait between pulses. Injected rather than
  ///     hard-coded so a test drives the loop on a signal instead of a real
  ///     clock — a clock-based test of this would be flaky by construction and
  ///     would take a day to exercise the case that matters.
  init(
    store: TranscriptStore,
    pendingPulseInterval: Duration = .seconds(60),
    pendingPulseSleep: (@Sendable (Duration) async -> Void)? = nil,
    emitEscapeRecoveryKept: ((_ ageMs: Int, _ takeID: String) -> Void)? = nil,
    emitEscapeRecoveryExpired: ((_ ageMs: Int, _ takeID: String) -> Void)? = nil,
    emitEscapeRecoveryRestoredFromHistory: ((_ ageMs: Int, _ takeID: String) -> Void)? = nil,
    recordEscapeRecoveryKeep: (@MainActor (_ outcome: String, _ takeID: String?) -> Void)? = nil,
    emitRenameTelemetry: @escaping (_ outcome: TelemetryService.FileImportRenameOutcome) -> Void =
      { _ in },
    emitTurnsDisplayedTelemetry: @escaping () -> Void = {},
    recordingArchive: RecordingArchive? = nil,
    encodeRecording: DictationRecordings.Encode? = nil
  ) {
    let transactionExecutor = HistoryTransactionExecutor(store: store)
    self.transactionExecutor = transactionExecutor
    self.recordings = recordingArchive.map { archive in
      let exists: @MainActor (UUID) async throws -> Bool = {
        try await transactionExecutor.readRow(id: $0) != nil
      }
      let rows: @MainActor () async throws -> Set<UUID>? = { try await store.permanentRowIDs() }
      return encodeRecording.map {
        DictationRecordings(
          archive: archive, executor: transactionExecutor, permanentRowExists: exists,
          permanentRowIDs: rows, encode: $0)
      }
        ?? DictationRecordings(
          archive: archive, executor: transactionExecutor, permanentRowExists: exists,
          permanentRowIDs: rows)
    }
    self.diskReconciler = HistoryDiskReconciler(
      store: store, transactionExecutor: transactionExecutor)
    self.pendingPulseInterval = pendingPulseInterval
    self.pendingPulseSleep = pendingPulseSleep ?? { try? await Task.sleep(for: $0) }
    self.emitEscapeRecoveryKept =
      emitEscapeRecoveryKept
      ?? { ageMs, takeID in
        TelemetryService.shared.escapeRecoveryKept(ageMs: ageMs, takeID: takeID)
      }
    self.emitEscapeRecoveryExpired =
      emitEscapeRecoveryExpired
      ?? { ageMs, takeID in
        TelemetryService.shared.escapeRecoveryExpired(ageMs: ageMs, takeID: takeID)
      }
    self.emitEscapeRecoveryRestoredFromHistory =
      emitEscapeRecoveryRestoredFromHistory
      ?? { ageMs, takeID in
        TelemetryService.shared.escapeRecoveryRestored(
          source: .history, ageMs: ageMs, pasteResult: .pasted, takeID: takeID)
      }
    self.recordEscapeRecoveryKeep = recordEscapeRecoveryKeep ?? Self.logKeep
    self.emitRenameTelemetry = emitRenameTelemetry
    self.emitTurnsDisplayedTelemetry = emitTurnsDisplayedTelemetry
  }

  /// Report that a HELD recovery was pasted from History (#2087).
  ///
  /// `EscapeRecoveryRestoreSource` has two cases and only `.pill` had a
  /// producer, so every restore that went through History was invisible and the
  /// funnel understated the one number the feature is judged on. History's Paste
  /// button has shipped since chunk 10; nothing about it changed, it simply was
  /// never counted.
  ///
  /// Silent for an ordinary row and for a lapsed one. A row that is no longer
  /// offerable was refused by `textForDelivery` before this is reached, so
  /// reporting here would count a paste that did not happen.
  func reportRestoredFromHistory(_ transcript: Transcript) {
    guard
      let stampedAt = transcript.escapeRecoveredAt,
      let takeID = transcript.escapeRecoveryTakeID,
      Self.isVisible(transcript, at: Date())
    else { return }
    emitEscapeRecoveryRestoredFromHistory(
      Int(Date().timeIntervalSince(stampedAt) * 1000), takeID)
  }

  /// Sweep pending rows that aged out un-restored, reporting each (#2087).
  ///
  /// Read-time expiry already hides them, so this reclaims disk and produces the
  /// `expired` half of the ratio that judges the feature. The store returns ONLY
  /// rows that genuinely expired AND were actually deleted — a corrupt file is
  /// swept without a receipt, and a failed removal is not reported until it is
  /// confirmed gone, so a stuck file cannot re-emit the same expiry forever.
  ///
  /// Inert until activation: no pending rows exist to sweep.
  /// ASYNC, and off the main actor for the walk itself.
  ///
  /// `deleteExpiredPending` enumerates a directory and decodes one JSON file per
  /// pending row. Running that synchronously on `@MainActor` put a filesystem
  /// walk in front of History opening — the two loads beside it already hop off
  /// for exactly this reason, and the sweep had no business being the one thing
  /// that blocks the window.
  func sweepExpiredPending(now: Date = Date()) async {
    // #4075 S1: one command spanning the walk and its result, so no write or removal lands
    // between them.
    await transactionExecutor.admit { [self] in await performSweep(now: now) }
  }

  private func performSweep(now: Date) async {
    do {
      let swept = try await diskReconciler.sweep(now: now)
      // Evict on EVERY deletion, not only the telemetry-eligible ones. A
      // future-skewed or corrupt row is deleted without a receipt, and leaving
      // it in memory kept `lapsedPendingCount` above zero — so the pulse
      // re-walked the directory every minute for a file that was already gone.
      if !swept.deletedIDs.isEmpty {
        transcripts.removeAll { swept.deletedIDs.contains($0.id) }
      }
      // `walkComplete` FIRST, and it is not a formality: `unremovable == 0` has
      // two causes — the sweep saw everything and cleared it, or it could not
      // read the directory at all. The second masks work instead of proving
      // there is none, so acting on it would evict the only remaining record of
      // rows whose files are still there.
      //
      // Nothing resisted removal, so every not-live file this pass could see is
      // gone — which means a row still lapsed at this SAME `now` has no file at
      // all, and memory is simply stale. Dropping it is what makes the sweep
      // trigger return to zero.
      //
      // Without this the trigger never settles whenever an unrelated LIVE row
      // keeps the pulse running: the stale row is lapsed forever, so the
      // directory is walked every minute for the life of the app. `load()`
      // preserves rows absent from both namespaces, so this state is reachable
      // rather than theoretical.
      //
      // The same `now` the sweep used, never a fresh `Date()`. A row exactly on
      // its boundary would otherwise be live to the sweep and lapsed to this
      // line, and it would be evicted on the strength of a disagreement between
      // two clocks rather than a fact about the disk.
      if swept.walkComplete, swept.unremovable == 0 {
        transcripts.removeAll { $0.escapeRecoveredAt != nil && !Self.isVisible($0, at: now) }
      }
      for row in swept.expired {
        guard let takeID = row.takeID else { continue }
        // The row's REAL age, not the retention constant. A Mac left off for
        // three days sweeps rows that are 72 hours old, and the gap between
        // deadline and sweep is the part worth seeing.
        emitEscapeRecoveryExpired(Int(now.timeIntervalSince(row.stampedAt) * 1000), takeID)
      }
      // The sweep is where outstanding work is DISCOVERED, so it is what must
      // make sure the retry is running. Relying on the caller left this to
      // ordering luck: `load()` happens to arm afterwards, so a sweep reached
      // any other way could learn that a file resisted removal — or that it
      // could not look at all — and then have nothing scheduled to try again.
      // Idempotent: from inside the pulse's own loop the task already exists.
      startPulseIfNeeded()
    } catch {
      // A sweep that THREW measured nothing, so it must not read as a finished
      // one — same reasoning as an unreadable directory, one layer out.
      //
      // Gated with the success path for one reason: a superseded FAILURE landing
      // after a newer walk succeeded would mark the directory unread when it had
      // just been read. `startPulseIfNeeded` below is unconditional, so a genuine
      // failure still leaves a retry armed either way.
      startPulseIfNeeded()
      // History is a limb, not the heart. A failed sweep leaves rows the
      // read-time filter already hides.
      Task {
        await AppLogger.shared.log(
          "Failed to sweep expired pending transcripts: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }

  // No `deinit` teardown: `deinit` is nonisolated and cannot touch main-actor
  // state, and none is needed — the loop holds `self` weakly, so once this
  // object goes away the next wake finds nothing and returns. Nothing is
  // retained in the meantime.

  func loadIfNeeded() {
    diskReconciler.loadIfNeeded(effects: readEffects)
  }

  func load() {
    diskReconciler.load(effects: readEffects)
  }

  private var readEffects: HistoryDiskReconciler.ReadEffects {
    HistoryDiskReconciler.ReadEffects(
      rows: { [self] in transcripts },
      applyRows: { [self] rows, removedIDs in
        removedRowIDs.formUnion(removedIDs)
        transcripts = rows
      },
      didApplyRead: { [self] in startPulseIfNeeded() },
      sweepBeforeRead: { [self] in await sweepExpiredPending() },
      didFinishCurrentRead: { [self] in historyReadFinished = true })
  }

  /// Append a just-completed transcript to the in-memory cache.
  ///
  /// Precondition: the transcript has already been persisted by
  /// the finalization `save` closure. This method does no disk I/O. Caller
  /// must not invoke it twice for the same transcript — duplicate-ID
  /// protection would mask heart-path bugs.
  func append(_ transcript: Transcript) {
    diskReconciler.noteWritten(transcript.id)
    // By date, not at the top: a dictation is dated before its delivery suspends, so a newer
    // queued save can publish first (Codex review of the #4075 S7 fix).
    insertByDate(transcript)
    // A held row appended at runtime is the production route once the feature
    // is activated, and it arrives with a countdown already running. Without
    // this the pulse would only ever start at launch, so a recovery held during
    // a session would show a countdown frozen at the value it had when the row
    // appeared. No-op for an ordinary dictation, which carries no stamp.
    startPulseIfNeeded()
  }


  /// Thrown by an ordinary write to a row whose durable meeting write is still in flight.
  struct RowWriteInFlight: Error {}

  /// Save a row to disk AND show it, replacing an existing row with the same id.
  ///
  /// #2772: a file import writes TWICE under one id — the raw words the moment transcription
  /// lands, then the cleaned document when the cleanup finishes. `append` would have put two
  /// rows on screen for one recording, because it inserts unconditionally while the store,
  /// which names its file by id, was correctly overwriting. The two would then disagree
  /// until the next launch re-read the disk.
  ///
  /// Throws, deliberately. The import STOPS before polishing when the first write fails,
  /// which it cannot do if this swallows the error.
  func saveAndShow(_ transcript: Transcript) async throws {
    // #3972 C4a: refused at admission, so ordinary writes admitted before a durable one stay
    // valid while later ones are refused until it lands.
    guard !transactionExecutor.isDurableWriteInFlight(transcript.id) else { throw RowWriteInFlight() }
    try Task.checkCancellation()
    _ = try await transactionExecutor.admit { [self] in
      await transactionExecutor.capture { try await performWrite(transcript, insertIfAbsent: true) }
    }.get()
  }

  /// One ordinary write, run as the head command: the file work on the storage worker, then
  /// the publication. Update-only when `insertIfAbsent` is false: a row no longer listed is
  /// not written and the answer is false.
  private func performWrite(_ transcript: Transcript, insertIfAbsent: Bool) async throws -> Bool {
    if !insertIfAbsent, !transcripts.contains(where: { $0.id == transcript.id }) {
      return false
    }
    try await transactionExecutor.write(transcript)
    // Stamped with the publication, with no read applied in between, so an in-flight `load()`
    // cannot publish the version it read BEFORE this write.
    diskReconciler.noteWritten(transcript.id)
    if let existing = transcripts.firstIndex(where: { $0.id == transcript.id }) {
      transcripts[existing] = transcript
    } else {
      insertByDate(transcript)
    }
    startPulseIfNeeded()
    return true
  }

  /// Puts a newly published row where its date places it, newest first, ahead of rows with
  /// the same date. A queued write lands after its worker finishes, so a newer dictation can
  /// already be on top by then; putting the row at the top would show it above that dictation
  /// until the next disk read (Codex History regrade 3, S7).
  private func insertByDate(_ transcript: Transcript) {
    let index =
      transcripts.firstIndex { $0.createdAt <= transcript.createdAt } ?? transcripts.endIndex
    transcripts.insert(transcript, at: index)
  }

  /// #3972 C4a: an EnviousMeet meeting's row, written durably (encode, `F_FULLFSYNC`, directory
  /// sync) OFF the main actor, then shown. EnviousMeet marks the meeting ready only after this
  /// returns, and its deletion awaits the commit that calls this, so no delete races the write.
  ///
  /// #4013 chunk 12B: with `naming`, the pass that proposed the row's automatic names, it
  /// returns what naming achieved in the row actually written, after the user's names were
  /// reconciled; `nil` without `naming`. A throw returns nothing.
  @discardableResult
  func saveAndShowDurably(_ transcript: Transcript, naming: SpeakerNamingPass? = nil)
    async throws -> SpeakerNamingSummary?
  {
    guard !transactionExecutor.isDurableWriteInFlight(transcript.id) else { throw RowWriteInFlight() }
    // Registered at admission and held until its publication or failure, so ordinary writes
    // admitted after it are refused and those admitted before it stay valid.
    transactionExecutor.reserveDurableWrite(transcript.id)
    return try await transactionExecutor.admit { [self] in
      defer { transactionExecutor.finishDurableWrite(transcript.id) }
      return await transactionExecutor.capture {
        try await performDurableWrite(transcript, naming: naming)
      }
    }.get()
  }

  /// #3973 C2: a row as its file holds it, read in History's command order, so a write admitted
  /// before this read has landed. Nil when there is no file; throws when it cannot be read.
  func durableRow(id: UUID) async throws -> Transcript? {
    try await transactionExecutor.admit { [self] in
      await transactionExecutor.capture { try await transactionExecutor.readRow(id: id) }
    }.get()
  }

  private func performDurableWrite(_ incoming: Transcript, naming: SpeakerNamingPass?)
    async throws -> SpeakerNamingSummary?
  {
    // #4013 r2 item 4: the user's speaker names are carried over from the row as it is NOW,
    // read when this command runs, so a rename admitted while the meeting was processing is
    // kept. The reconciled row is what is written and what is shown. A row History has not
    // loaded (a launch replay of #3973 C2) is read from its file inside this same command; a
    // file that cannot be read fails the write rather than writing over it.
    let existing: Transcript?
    if let row = currentRow(id: incoming.id) {
      existing = row
    } else {
      existing = try await transactionExecutor.readRow(id: incoming.id)
    }
    let transcript = existing.map { incoming.reconcilingSpeakerNames(withCurrent: $0) } ?? incoming
    // Calculated from this exact reconciled row, released only once it is written.
    let pending = naming.map {
      PendingSpeakerNamingSummary(proposed: incoming, reconciled: transcript, pass: $0)
    }
    try await transactionExecutor.writeDurably(transcript)
    diskReconciler.noteWritten(transcript.id)
    if let existing = transcripts.firstIndex(where: { $0.id == transcript.id }) {
      transcripts[existing] = transcript
    } else {
      insertByDate(transcript)
    }
    startPulseIfNeeded()
    return pending?.committed(.written)
  }

  #if DEBUG
    /// Replaces `Date()` for Keep's press and execution times.
    @ObservationIgnored var clockForTesting: (@MainActor () -> Date)?
  #endif

  /// Save a row that must ALREADY be in History, reporting whether it was.
  ///
  /// #2772: an import's two writes are minutes apart, and History is reachable the whole
  /// time. Between them the user can delete the raw row. `saveAndShow` INSERTS an id it does
  /// not find, so the second write put the row back and rewrote its file, undoing an
  /// explicit deletion with nothing on screen to say so. Found by the cloud review of
  /// PR #2786.
  ///
  /// Update-only by CONSTRUCTION rather than by a tombstone the caller has to remember to
  /// check: this method has no insert branch, so no future caller can reach one.
  ///
  /// The in-memory list is the oracle, not the disk. `delete` and `deleteAll` empty both on
  /// this actor, and the list is what the user is looking at.
  @discardableResult
  func updateExistingRow(_ transcript: Transcript) async throws -> Bool {
    guard !transactionExecutor.isDurableWriteInFlight(transcript.id) else { throw RowWriteInFlight() }
    try Task.checkCancellation()
    return try await transactionExecutor.admit { [self] in
      await transactionExecutor.capture {
        // #4075 S1: prepared when it runs. A cleaned update owns its text and provenance; the
        // speaker fields are whatever earlier commands (a rename, a speaker merge) left.
        guard let current = currentRow(id: transcript.id) else { return false }
        var candidate = transcript.carryingSpeakerFields(from: current)
        if current.isImported {
          // #3147 PR3: a write from an older transcription of this import (its text replaced
          // since by Transcribe again with) is refused, even when the text matches; and the
          // row's current source link stands, whatever link the caller's copy carried.
          guard candidate.importAttemptID == current.importAttemptID else { return false }
          candidate = candidate.withSource(
            bookmark: current.sourceBookmark, fingerprint: current.sourceFingerprint)
        }
        return try await performWrite(candidate, insertIfAbsent: false)
      }
    }.get()
  }

  /// The speaker-fields write (#2810 addendum §3 E), and the one future rename write (phase
  /// 4) will share it. Reads the CURRENT row from `transcripts` at call time — never a value
  /// captured earlier — so "merge into the latest existing row, never overwrite newer
  /// names" holds structurally: whichever call runs second reads what the first one left.
  /// Update-only like `updateExistingRow`, inheriting its "never resurrect a deleted row"
  /// guard. #4075 S1: one queued command, so the merge reads the row when it runs.
  @discardableResult
  func mergeSpeakerFields(
    id: UUID, analysis: TranscriptSpeakerAnalysis, turns: [Turn]?,
    explicitRename: (speakerId: String, name: String)? = nil
  ) async throws -> Bool {
    guard !transactionExecutor.isDurableWriteInFlight(id) else { throw RowWriteInFlight() }
    try Task.checkCancellation()
    let rename = explicitRename.map { RenamePair(speakerId: $0.speakerId, name: $0.name) }
    return try await transactionExecutor.admit { [self] in
      await transactionExecutor.capture {
        // #4075 S1: read when this command runs, so it merges into what earlier commands left.
        if let rename {
          // A rename changes the named speaker only, on the row's analysis and turns as they
          // are now; the caller's copies may be older than an earlier queued write.
          switch preparedRename(id: id, rename) {
          case .removed: return false
          case .notRenamable: throw RenameNotSupported()
          case .row(let renamed): return try await performWrite(renamed, insertIfAbsent: false)
          }
        }
        guard let existing = transcripts.first(where: { $0.id == id }) else { return false }
        let merged = existing.mergingSpeakerFields(analysis: analysis, turns: turns)
        return try await performWrite(merged, insertIfAbsent: false)
      }
    }.get()
  }

  /// Thrown by a rename of a row that is still listed but no longer has speakers to rename.
  struct RenameNotSupported: Error {}

  private enum PreparedRename {
    case row(Transcript)
    case removed
    case notRenamable
  }

  /// The one preparation both renames share, run inside the rename's command.
  private func preparedRename(id: UUID, _ rename: RenamePair) -> PreparedRename {
    guard let current = currentRow(id: id) else { return .removed }
    guard current.turns != nil, let analysis = current.speakerAnalysis else { return .notRenamable }
    return .row(
      current.mergingSpeakerFields(
        analysis: analysis, turns: current.turns,
        explicitRename: (rename.speakerId, rename.name)))
  }

  /// A rename's speaker and name, as one Sendable value.
  private struct RenamePair: Sendable {
    let speakerId: String
    let name: String
  }

  /// Whether a row is in History right now. The import's "Saved to History" badge asks this
  /// live rather than remembering that a write once succeeded (#2772): a row can be deleted
  /// at any moment after either of the import's writes, and a remembered success then
  /// describes a file that is gone.
  func hasRow(id: UUID) -> Bool {
    transcripts.contains { $0.id == id }
  }

  /// The CURRENT row, read fresh from `transcripts` at call time — never a snapshot (#2811,
  /// phase 4 of #2807). Mirrors `hasRow(id:)`'s own "the in-memory list is the oracle"
  /// contract: a caller about to carry another writer's speaker fields forward, or decide
  /// whether a rename/retry is eligible, must read this rather than trust a value it captured
  /// earlier.
  func currentRow(id: UUID) -> Transcript? {
    transcripts.first { $0.id == id }
  }

  /// Renames a speaker id across every turn showing it, for a row History renders directly
  /// (#2811, phase 4 of #2807) — the History-side twin of `FileImportCoordinator
  /// .renameSpeaker`, both ordinary, symmetric callers of `mergeSpeakerFields` above. Re-reads
  /// the row's CURRENT analysis and turns TOGETHER, atomically, immediately before writing —
  /// never a value captured when a popover opened (§3 Design correction 2).
  ///
  /// `isMeeting` is the kind of the row the caller rendered (#3972 R19): a meeting row's rename
  /// emits no file-import telemetry. It comes from the caller because the row may already be
  /// gone when a late callback arrives, and a missing row has no kind to read.
  func renameSpeaker(id transcriptID: UUID, speakerId: String, name: String, isMeeting: Bool)
    async -> RenameFailure?
  {
    let emitRenameTelemetry: (TelemetryService.FileImportRenameOutcome) -> Void =
      isMeeting ? { _ in } : self.emitRenameTelemetry
    // #3972 C4a: refused at admission while a durable meeting write to this row is queued.
    guard !transactionExecutor.isDurableWriteInFlight(transcriptID), !Task.isCancelled else {
      emitRenameTelemetry(.failed)
      return RenameFailure(
        message: RenameFailure.couldNotSaveName,
        currentName: currentRow(id: transcriptID)?.speakerNames?[speakerId])
    }
    // #4075 S1: the row's analysis and turns are resolved when the command runs, so the
    // rename changes the named speaker only, on whatever earlier commands left.
    let rename = RenamePair(speakerId: speakerId, name: name)
    let outcome = await transactionExecutor.admit { [self] () async -> RenameOutcome in
      switch preparedRename(id: transcriptID, rename) {
      case .removed: return .removed
      case .notRenamable: return .notRenamable
      case .row(let renamed):
        do {
          return try await performWrite(renamed, insertIfAbsent: false) ? .saved : .removed
        } catch {
          return .failed
        }
      }
    }
    switch outcome {
    case .saved:
      emitRenameTelemetry(.saved)
      return nil
    case .removed:
      emitRenameTelemetry(.failed)
      return RenameFailure(message: RenameFailure.recordingRemoved, currentName: nil)
    case .notRenamable:
      emitRenameTelemetry(.failed)
      return RenameFailure(message: RenameFailure.couldNotSaveName, currentName: nil)
    case .failed:
      emitRenameTelemetry(.failed)
      // The name as History holds it now, not as it was before the wait.
      return RenameFailure(
        message: RenameFailure.couldNotSaveName,
        currentName: currentRow(id: transcriptID)?.speakerNames?[speakerId])
    }
  }

  private enum RenameOutcome: Sendable { case saved, removed, notRenamable, failed }

  /// The rename popover closed on Escape or a blank name (plan §3d). Telemetry only.
  func noteRenameCancelled() {
    emitRenameTelemetry(.cancelled)
  }

  /// `noteRenameCancelled()` for a row History rendered: nothing for a meeting row (#3972
  /// R19). `isMeeting` comes from the caller, as in `renameSpeaker`.
  func noteRenameCancelled(isMeeting: Bool) {
    guard !isMeeting else { return }
    noteRenameCancelled()
  }

  /// History's detail view just drew a turn view for `id` (#2811 §3e). Reported once per
  /// document per launch; re-selecting the same row is not a new fact. Never for a meeting
  /// row (#3972 R19); `isMeeting` comes from the caller, as in `renameSpeaker`.
  func noteTurnsDisplayed(id: UUID, isMeeting: Bool) {
    guard !isMeeting else { return }
    guard displayedTurnIDs.insert(id).inserted else { return }
    emitTurnsDisplayedTelemetry()
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

  /// The rows that name this meeting (normally one; an orphan's when its record is gone).
  func rowIDs(ofMeeting meetingID: UUID) -> [UUID] {
    transcripts.filter { $0.meetingID == meetingID }.map(\.id)
  }

  /// History's delete of one listed item. A meeting goes to EnviousMeet, the deletion
  /// authority of its row and its files (#3972 R12); the selection moves to the item beside it
  /// at once, because the meeting leaves the list only when EnviousMeet has removed it.
  func delete(_ item: HistoryListItem) async {
    switch item {
    case .transcript(let row):
      await delete(row)
    case .meeting(let meeting):
      if let deleteMeeting {
        if await !deleteMeeting(meeting.meetingID) { reportActionFailure(.delete) }
      } else if let row = meeting.row {
        await removeRowAnnouncing(row.id)
      }
    }
  }

  /// A History action that failed and the user has not dismissed yet (#4075 G10). The History
  /// window shows it; before, each failure only wrote a log line and a press looked ignored.
  enum ActionFailure: Equatable {
    case delete, keep, deleteAll
  }

  private(set) var actionFailure: ActionFailure?

  /// The History window's alert was dismissed.
  func dismissActionFailure() { actionFailure = nil }

  /// A History action owned elsewhere failed: a meeting's delete, run by EnviousMeet (#4079).
  func reportActionFailure(_ failure: ActionFailure) { actionFailure = failure }

  func delete(_ transcript: Transcript) async {
    // A meeting goes to EnviousMeet before any History command is admitted; its own History
    // removal joins the queue from there, so the queue is never held across that orchestration.
    if let meetingID = transcript.meetingID, let deleteMeeting {
      if await !deleteMeeting(meetingID) { reportActionFailure(.delete) }
      return
    }
    await removeRowAnnouncing(transcript.id)
  }

  // MARK: - History commands (#3147 PR2)

  /// Whether History may store a text preference on `row`: a permanent, visible dictation.
  /// Imports, meetings and held Escape-recovery rows have no preference.
  private func acceptsHistoryPreference(_ row: Transcript) -> Bool {
    !row.isImported && !row.isMeeting && row.escapeRecoveredAt == nil
      && Self.isVisible(row, at: clock())
  }

  /// Sets which text History shows and delivers for dictation `rowID` (Restore original text,
  /// Use polished text). One queued command that reads the row when it runs and changes only
  /// the preference. Nil when the row is gone or takes no preference; an unchanged preference
  /// writes nothing and still returns its change.
  func setHistoryPreferredVersion(
    _ version: Transcript.PreferredVersion?, for rowID: UUID
  ) async throws -> HistoryPreferenceChange? {
    guard !transactionExecutor.isDurableWriteInFlight(rowID) else { throw RowWriteInFlight() }
    try Task.checkCancellation()
    return try await transactionExecutor.admit { [self] in
      await transactionExecutor.capture { () async throws -> HistoryPreferenceChange? in
        guard let current = currentRow(id: rowID), acceptsHistoryPreference(current) else {
          return nil
        }
        let change = HistoryPreferenceChange(
          rowID: rowID, before: current.preferredVersion, after: version)
        guard change.before != version else { return change }
        guard try await performWrite(current.preferring(version), insertIfAbsent: false) else {
          return nil
        }
        return change
      }
    }.get()
  }

  /// Puts back what `change` replaced, only while the row still holds `change.after`: a later
  /// different choice is never overwritten. False when nothing was put back.
  func undoHistoryPreference(_ change: HistoryPreferenceChange) async throws -> Bool {
    guard !transactionExecutor.isDurableWriteInFlight(change.rowID) else {
      throw RowWriteInFlight()
    }
    try Task.checkCancellation()
    return try await transactionExecutor.admit { [self] in
      await transactionExecutor.capture { () async throws -> Bool in
        guard let current = currentRow(id: change.rowID), acceptsHistoryPreference(current),
          current.preferredVersion == change.after
        else { return false }
        guard change.before != change.after else { return true }
        return try await performWrite(
          current.preferring(change.before), insertIfAbsent: false)
      }
    }.get()
  }

  /// One History deletion with what its owner actually did (#3147 selection mode). A meeting,
  /// or a row that belongs to one, goes to EnviousMeet outside any History command; a dictation
  /// or import is one queued command. Failures are returned, not reported here.
  func deleteHistoryItem(id: HistoryItemID, kind: HistoryDeleteKind) async
    -> HistoryDeleteOutcome
  {
    switch id {
    case .meeting(let meetingID):
      return await deleteMeetingItem(meetingID, kind: kind)
    case .transcript(let rowID):
      if let meetingID = currentRow(id: rowID)?.meetingID {
        return await deleteMeetingItem(meetingID, kind: kind)
      }
      switch kind {
      case .textAndRecordings: return await removeRowReporting(rowID)
      case .recordingsOnly: return await deleteRecordingReporting(rowID)
      }
    }
  }

  private func deleteMeetingItem(_ meetingID: UUID, kind: HistoryDeleteKind) async
    -> HistoryDeleteOutcome
  {
    switch kind {
    case .textAndRecordings:
      if let deleteMeeting { return await deleteMeeting(meetingID) ? .removed : .failed }
      // Unwired (tests): the meeting's rows go the ordinary way.
      let rowIDs = transcripts.filter { $0.meetingID == meetingID }.map(\.id)
      guard !rowIDs.isEmpty else { return .alreadyAbsent }
      var outcome = HistoryDeleteOutcome.alreadyAbsent
      for rowID in rowIDs {
        switch await removeRowReporting(rowID) {
        case .failed: outcome = .failed
        case .removed where outcome != .failed: outcome = .removed
        default: break
        }
      }
      return outcome
    case .recordingsOnly:
      guard let deleteMeetingAudio else { return .failed }
      return await deleteMeetingAudio(meetingID)
    }
  }

  /// The removal command with its announcement, returning its outcome instead of reporting it.
  private func removeRowReporting(_ id: UUID) async -> HistoryDeleteOutcome {
    guard !Task.isCancelled else { return .failed }
    return await transactionExecutor.admit { [self] in
      do {
        let result = try await performRemovalWithCleanup(id)
        if result.removal == .removed { onRowDeleted?(id) }
        // Text gone but its recording left behind is not done: the item stays selected and a
        // retry finishes the cleanup (Codex r3).
        if result.recordingCleanupFailed { return .failed }
        return result.removal == .removed ? .removed : .alreadyAbsent
      } catch {
        return .failed
      }
    }
  }

  /// Delete recordings only for one row: a dictation's recording goes and its text stays. An
  /// import has no recording to delete; a dictation without one is already absent.
  private func deleteRecordingReporting(_ rowID: UUID) async -> HistoryDeleteOutcome {
    guard let recordings else { return .skipped }
    guard !Task.isCancelled else { return .failed }
    return await transactionExecutor.admit { [self] in
      guard let row = currentRow(id: rowID) else { return .alreadyAbsent }
      guard !row.isImported, !row.isMeeting else { return .skipped }
      guard await recordings.hasRecordingOrPendingInCommand(rowID: rowID) else {
        return .alreadyAbsent
      }
      do {
        try await recordings.deleteRecordingInCommand(rowID: rowID, reason: .deleted)
        return .removed
      } catch {
        return .failed
      }
    }
  }

  // MARK: - Imported transcripts (#3147 PR3)

  /// The import background speaker write: `mergeSpeakerFields` for a document whose import
  /// attempt is `expectedAttemptID`, refused (false) when the row's text has since been
  /// replaced by Transcribe again with, or the row is not an import.
  @discardableResult
  func mergeImportedSpeakerFields(
    id: UUID, expectedAttemptID: UUID?, analysis: TranscriptSpeakerAnalysis, turns: [Turn]?
  ) async throws -> Bool {
    guard !transactionExecutor.isDurableWriteInFlight(id) else { throw RowWriteInFlight() }
    try Task.checkCancellation()
    return try await transactionExecutor.admit { [self] in
      await transactionExecutor.capture { () async throws -> Bool in
        guard let existing = currentRow(id: id), existing.isImported,
          existing.importAttemptID == expectedAttemptID
        else { return false }
        let merged = existing.mergingSpeakerFields(analysis: analysis, turns: turns)
        return try await performWrite(merged, insertIfAbsent: false)
      }
    }.get()
  }

  /// Links import `rowID` to `bookmark` (Locate original, or a refreshed stale bookmark), only
  /// while the row still holds `expected`. A known fingerprint is never erased or replaced
  /// through the legacy route: `fingerprint` must equal the stored one when one is stored.
  /// A row without one (legacy) takes `fingerprint` only with `confirmedLegacy`.
  @discardableResult
  func setImportedSource(
    bookmark: Data, fingerprint: String?, for rowID: UUID, expected: ImportedSourceReference,
    confirmedLegacy: Bool
  ) async throws -> Bool {
    guard !transactionExecutor.isDurableWriteInFlight(rowID) else { throw RowWriteInFlight() }
    try Task.checkCancellation()
    return try await transactionExecutor.admit { [self] in
      await transactionExecutor.capture { () async throws -> Bool in
        guard let current = currentRow(id: rowID), current.isImported,
          ImportedSourceReference(current) == expected
        else { return false }
        if let stored = current.sourceFingerprint {
          guard fingerprint == stored else { return false }
        } else {
          guard confirmedLegacy else { return false }
        }
        onImportedContentWillChange?(rowID)
        return try await performWrite(
          current.withSource(bookmark: bookmark, fingerprint: fingerprint ?? current.sourceFingerprint),
          insertIfAbsent: false)
      }
    }.get()
  }

  /// The newest replacement ticket per row; a commit with any other ticket is stale.
  private var replacementTickets: [UUID: UUID] = [:]

  /// Starts Transcribe again with for import `rowID` (after the user confirmed): records the
  /// row's current state so the commit can refuse if anything changed. Nil when the row is
  /// gone or not an import. A newer ticket for the same row makes an older one stale.
  func beginImportedReplacement(for rowID: UUID) async throws -> ImportedReplacementTicket? {
    try Task.checkCancellation()
    return try await transactionExecutor.admit { [self] in
      await transactionExecutor.capture { () async throws -> ImportedReplacementTicket? in
        guard let current = currentRow(id: rowID), current.isImported else { return nil }
        // Reserved before the digest (Codex PR3 r2): a Cancel while it is computed wins.
        let requestID = UUID()
        replacementTickets[rowID] = requestID
        let digest = try await rowDigest(current)
        guard replacementTickets[rowID] == requestID else { return nil }
        return ImportedReplacementTicket(
          rowID: rowID, requestID: requestID, attemptID: UUID(), expectedRowDigest: digest,
          source: ImportedSourceReference(current))
      }
    }.get()
  }

  /// Replaces import `ticket.rowID`'s content with `result` (a fresh transcription of the same
  /// file) in one write, keeping its id, date, file name, source link and preference, and
  /// minting `ticket.attemptID`. False when the ticket is stale, the row is gone, or its stored
  /// state or source changed since the ticket. Stops the row's players first.
  @discardableResult
  func commitImportedReplacement(_ result: Transcript, ticket: ImportedReplacementTicket)
    async throws -> Bool
  {
    guard !transactionExecutor.isDurableWriteInFlight(ticket.rowID) else {
      throw RowWriteInFlight()
    }
    try Task.checkCancellation()
    return try await transactionExecutor.admit { [self] in
      await transactionExecutor.capture { () async throws -> Bool in
        guard replacementTickets[ticket.rowID] == ticket.requestID,
          let current = currentRow(id: ticket.rowID), current.isImported,
          ImportedSourceReference(current) == ticket.source
        else { return false }
        let digest = try await rowDigest(current)
        // Checked again after the digest's await: a Cancel during it wins (Codex PR3 r2).
        guard digest == ticket.expectedRowDigest,
          replacementTickets[ticket.rowID] == ticket.requestID
        else { return false }
        onImportedContentWillChange?(ticket.rowID)
        let replaced = current.replacingImportedContent(from: result, attemptID: ticket.attemptID)
        let written = try await performWrite(replaced, insertIfAbsent: false)
        if written { replacementTickets[ticket.rowID] = nil }
        return written
      }
    }.get()
  }

  /// Makes any outstanding replacement ticket for `rowID` stale (Cancel, deletion).
  func invalidateImportedReplacement(for rowID: UUID) {
    replacementTickets[rowID] = nil
  }

  /// Called inside the command, before an import's content or source changes or the row is
  /// removed, so its players stop first (wired to the playback arbiter). Nil in tests.
  @ObservationIgnored var onImportedContentWillChange: (@MainActor (UUID) -> Void)?

  /// A canonical digest of a stored row, the base a replacement ticket compares against.
  private func rowDigest(_ row: Transcript) async throws -> String {
    #if DEBUG
      await rowDigestWillRunForTesting?()
    #endif
    return try await Self.canonicalDigest(row)
  }

  #if DEBUG
    /// Holds a replacement's digest step so a test can cancel during it.
    @ObservationIgnored var rowDigestWillRunForTesting: (@MainActor () async -> Void)?
  #endif

  /// Its encoded JSON with sorted keys, hashed off the main actor.
  private static func canonicalDigest(_ row: Transcript) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      encoder.dateEncodingStrategy = .millisecondsSince1970
      let data = try encoder.encode(row)
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }.value
  }

  /// One removal command with its announcement. A row already absent from History and from
  /// both folders is a no-op: nothing is published and nothing is announced.
  private func removeRowAnnouncing(_ id: UUID) async {
    guard !Task.isCancelled else { return }
    // #4075 S1: the announcement and the failure are handled inside the command, before the
    // next command prepares, so a queued re-insertion cannot run ahead of them.
    await transactionExecutor.admit { [self] in
      do {
        if try await performRemoval(id) == .removed { onRowDeleted?(id) }
      } catch {
        reportDeleteFailure(error)
      }
    }
  }

  private func reportDeleteFailure(_ error: any Error) {
    actionFailure = .delete
    Task {
      await AppLogger.shared.log(
        "Failed to delete transcript: \(error)",
        level: .info, category: "TranscriptCoordinator"
      )
    }
  }

  /// Text for a Copy or Paste started from History, or `nil` if the row is no
  /// longer being offered (#2087).
  ///
  /// A view holds the row it was RENDERED with, which is a snapshot. For an
  /// ordinary dictation that is harmless. For a held recovery it is not: the
  /// offer can lapse between the row appearing and the button being pressed, and
  /// pasting from the snapshot would hand back text the user was told had gone —
  /// the one thing the 24-hour promise says will not happen.
  ///
  /// Re-reads by id rather than trusting the caller's copy, so a row deleted in
  /// another pane is also refused. Inert, not merely harmless.
  func textForDelivery(_ transcript: Transcript) -> String? {
    if transcript.isMeeting {
      // #3972 R19: read again by id, and only the visible turns; nil when the row is gone,
      // its meeting facts are unknown, or every line is hidden.
      guard let current = currentRow(id: transcript.id) else { return nil }
      return MeetingHistoryPresentation.deliveryText(
        current, projection: meetingProjection(of: current), timesOn: false)
    }
    // #4075 R5: the row as it is now, never the caller's copy. History Paste reads this after
    // hiding the app, and an import's cleanup or a deletion can land in that wait.
    if let current = transcripts.first(where: { $0.id == transcript.id }) {
      // #3147 §3.4: History delivers the row's preferred text (original or polished).
      return Self.isVisible(current, at: Date()) ? current.historyText : nil
    }
    // Not in History. A held recovery that is gone has lapsed, and a row History held and
    // removed was deleted: both are refused. A dictation History never held (the live pane's
    // copy when its save failed) keeps the text it showed.
    guard transcript.escapeRecoveredAt == nil, !removedRowIDs.contains(transcript.id) else {
      return nil
    }
    return transcript.displayText
  }

  /// Rows History held and then removed this session (#4075 R5), so delivery refuses a copy of
  /// one instead of treating it like a dictation History never held.
  private var removedRowIDs: Set<UUID> = []

  /// The newest dictation the menu bar and the Paste/Copy Last Dictation shortcuts may offer
  /// again (#3106), or nil when there is none.
  ///
  /// Read from every visible row, NOT a History tab's list: those shortcuts work from any app, so
  /// what History's own filter or search happens to show must not decide which text they reuse.
  /// Returns the full `displayText`; the menu shortens it for display.
  ///
  /// A SNAPSHOT for rendering. Acting on it goes through `lastDictationTextForReuse(id:)`,
  /// which reads the row again at that moment.
  func lastPasteableDictation() -> (id: UUID, text: String)? {
    let now = Date()
    guard let row = transcripts.first(where: { Self.isReusableDictation($0, at: now) }) else {
      return nil
    }
    #if DEBUG
      if Self.reuseInputFault == .dropNextSampledRow {
        Self.reuseInputFault = nil
        Self.droppedReuseRowID = row.id
      }
    #endif
    return (row.id, row.displayText)
  }

  /// The text to reuse for row `id`, read fresh at call time, or nil if that row may no longer
  /// be reused (#3106): deleted, expired, or no longer eligible.
  ///
  /// Deliberately separate from `textForDelivery(_:)`, which serves History's own buttons and
  /// must keep offering imported and held rows there. Reuse is narrower: only a dictation the
  /// user actually made and received.
  func lastDictationTextForReuse(id: UUID) -> String? {
    var rows = transcripts
    #if DEBUG
      // The sampled row, gone from the rows this ONE read sees: the same read a deletion after
      // the menu rendered would meet.
      if let dropped = Self.droppedReuseRowID, dropped == id {
        Self.droppedReuseRowID = nil
        rows = rows.filter { $0.id != dropped }
      }
    #endif
    guard let row = rows.first(where: { $0.id == id }),
      Self.isReusableDictation(row, at: Date())
    else { return nil }
    return row.displayText
  }

  /// One eligibility rule for both queries above, applied at the time of each read, so the two
  /// cannot disagree about the same row in the same state. The row can still change between the
  /// menu's read and the action's: an edit or deletion in between is meant to make the action
  /// refuse it.
  ///
  /// - Imported rows are files put through Transcribe a File, not something the user said.
  /// - Held rows (`escapeRecoveredAt`) are cancelled takes that were never delivered; offering
  ///   one here would paste words the user chose to throw away.
  /// - Whitespace-only text would paste nothing visible. Checked, never trimmed: the text that
  ///   is reused is exactly the text that was delivered.
  private static func isReusableDictation(_ row: Transcript, at now: Date) -> Bool {
    isVisible(row, at: now)
      && !isImportedForReuse(row)
      // #3972 R5: a meeting is never the last dictation to paste again.
      && !row.isMeeting
      && row.escapeRecoveredAt == nil
      && !row.displayText.allSatisfy(\.isWhitespace)
  }

  private static func isImportedForReuse(_ row: Transcript) -> Bool {
    #if DEBUG
      if reuseInputFault == .importedOnly { return true }
    #endif
    return row.isImported
  }

  #if DEBUG
    /// #3106 Live UAT input seams, armed ONLY through `DebugFaultEndpoint` (a DEBUG build launched
    /// with `EW_FAULT_INJECTION=1`). They fault the INPUT to the real eligibility check and the
    /// real read-by-id, never the outcome, and never touch stored History.
    enum ReuseInputFault: Equatable {
      /// Every row reads as imported to the eligibility check: History with only imported rows.
      case importedOnly
      /// One-shot: the next row the menu (or a chord) samples is missing from the next read of
      /// that id, as if it were deleted after the menu rendered.
      case dropNextSampledRow
    }
    static var reuseInputFault: ReuseInputFault?
    private(set) static var droppedReuseRowID: UUID?

    static func clearReuseInputFault() {
      reuseInputFault = nil
      droppedReuseRowID = nil
    }
  #endif

  /// Everything the pill needs to restore a held row, or nil if it may not be
  /// restored (#2087).
  ///
  /// ONE authority rather than three lookups at the call site, because the
  /// refusal must be indivisible: text, age and join key have to describe the
  /// SAME row at the SAME instant, and a caller that fetched them separately
  /// could paste text while reporting a different row's age — or, worse, paste a
  /// row that lapsed between the second lookup and the third.
  ///
  /// Refuses on the same rule `textForDelivery` uses, and for the same reason: a
  /// recovery can lapse between the pill appearing and the press, and pasting a
  /// snapshot would hand back text the user was told had gone.
  func restorableHeldRow(id: UUID) -> (text: String, stampedAt: Date, takeID: String?)? {
    let now = Date()
    guard
      let row = transcripts.first(where: { $0.id == id }),
      let stampedAt = row.escapeRecoveredAt,
      Self.isVisible(row, at: now)
    else { return nil }
    return (row.displayText, stampedAt, row.escapeRecoveryTakeID)
  }

  /// Make a held recovery permanent (#2087).
  ///
  /// Inert, not merely harmless, when the row is no longer offerable: the store
  /// revalidates and silently ignores a row that expired between render and
  /// click, so a Keep press arriving a moment too late writes nothing rather
  /// than resurrecting text the user was told had gone.
  ///
  /// The in-memory row is replaced only after the store call returns, and it is
  /// replaced rather than mutated because `Transcript` is immutable. Idempotent:
  /// a second Keep finds no pending file and changes nothing.
  func keep(_ transcript: Transcript) async {
    guard transcript.escapeRecoveredAt != nil, !Task.isCancelled else { return }
    // #4075 S1: the press time, for the kept event's age; eligibility is judged when the
    // command runs.
    let pressedAt = now()
    await transactionExecutor.admit { [self] in await performKeep(transcript, pressedAt: pressedAt) }
  }

  private func performKeep(_ transcript: Transcript, pressedAt: Date) async {
    // A Keep of a row an earlier command removed: refused, never written back.
    guard let current = currentRow(id: transcript.id) else {
      recordEscapeRecoveryKeep("refused-not-offerable", transcript.escapeRecoveryTakeID)
      return
    }
    // A second Keep of a row an earlier command already promoted: done, not refused.
    if current.escapeRecoveredAt == nil {
      recordEscapeRecoveryKeep("already-permanent", transcript.escapeRecoveryTakeID)
      return
    }
    let id = transcript.id
    let executedAt = now()
    do {
      // Only on a CONFIRMED promotion. The store silently ignores a row that
      // expired between render and click, and clearing the stamp anyway would
      // put an expired recovery on screen as permanent History — resurrecting
      // in the UI precisely the text the store just refused to write.
      guard
        let result = try await transactionExecutor.promote(id: id, now: executedAt)
      else {
        // The refusal is the interesting case and it was the silent one: the
        // user pressed Keep, the row lapsed a moment earlier, and nothing
        // anywhere recorded that the press happened. That is precisely the
        // report a support conversation starts from.
        recordEscapeRecoveryKeep("refused-not-offerable", transcript.escapeRecoveryTakeID)
        return
      }
      // #2087: only on a CONFIRMED promotion, and only with the persisted take
      // id. A `kept` event for a row that was not promoted would overstate the
      // one ratio this funnel exists to measure. #4075 S1: the take id and stamp are the
      // promoted recovery's own, and the age runs to the press, not to the write.
      if let takeID = result.pending.escapeRecoveryTakeID,
        let stamped = result.pending.escapeRecoveredAt
      {
        emitEscapeRecoveryKept(Int(pressedAt.timeIntervalSince(stamped) * 1000), takeID)
        recordEscapeRecoveryKeep("kept", takeID)
      } else {
        // Promoted, but with nothing to join it to. The user keeps their text
        // either way — this records the bookkeeping gap rather than letting the
        // Keep disappear from the count it belongs in.
        recordEscapeRecoveryKeep("kept-unreported", nil)
      }
      guard let index = transcripts.firstIndex(where: { $0.id == id }) else { return }
      diskReconciler.noteWritten(id)
      transcripts[index] = result.promoted
      refreshDiskStateThenStopIfIdle()
    } catch {
      actionFailure = .keep
      Task {
        await AppLogger.shared.log(
          "Failed to keep transcript: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }


  /// The coordinator's clock for Keep, so a test can tell the press from the execution.
  private func now() -> Date {
    #if DEBUG
      if let clock = clockForTesting { return clock() }
    #endif
    return Date()
  }

  /// One line per Keep press, on every outcome including the refusals.
  ///
  /// Founder 2026-08-18, on the sibling Undo path: we must be able to tell after
  /// the fact how often this is used and when it fails. Telemetry answers that
  /// across users; this answers it for the ONE user in front of you, which is
  /// the only thing a support conversation can read. Shape only — no transcript
  /// and no text — and `take` is our own opaque join key.
  private static func logKeep(outcome: String, takeID: String?) {
    let take = takeID ?? "MISSING (keep not reported to telemetry)"
    Task {
      await AppLogger.shared.log(
        "escape recovery keep: outcome=\(outcome) take=\(take)",
        level: .info, category: "EscapeRecovery"
      )
    }
  }

  // MARK: - Meeting rows (#3972 R5, R19)

  func isShowingEcho(rowID: UUID) -> Bool { echoShownRowIDs.contains(rowID) }

  /// The document-scoped "Show probable echo" choice; C5 gives it a control.
  func setShowEcho(_ show: Bool, rowID: UUID) {
    if show { echoShownRowIDs.insert(rowID) } else { echoShownRowIDs.remove(rowID) }
  }

  /// #3973 C2: the probable-echo turn IDs of `row`'s own transcript generation, or nil when
  /// its facts are not known.
  func meetingEchoTurnIDs(of row: Transcript) -> Set<String>? {
    guard let meetingID = row.meetingID else { return nil }
    return meetingInfo?(meetingID)?.matching(row)?.echoTurnIDs
  }

  /// #3973 C2: whether `row`'s own transcript generation has probable-echo lines, the facts
  /// "Show probable echo" acts on. False for a row whose facts are not known.
  func meetingHasProbableEcho(_ row: Transcript) -> Bool {
    meetingEchoTurnIDs(of: row)?.isEmpty == false
  }

  /// What a meeting row shows; `.unavailable` for a row that is not a meeting.
  func meetingProjection(of row: Transcript) -> MeetingHistoryPresentation.Projection {
    guard let meetingID = row.meetingID else { return .unavailable }
    // #3973 C2: only the facts of this row's own transcript generation.
    let info = meetingInfo?(meetingID)?.matching(row)
    let showEcho = isShowingEcho(rowID: row.id)
    // #4075 R6: the plain text comes from the kept meeting text (the same projection search and
    // the preview read), so a detail redraw does not rebuild the whole meeting's text. Only the
    // visible turns, a filter, are computed here.
    let text = meetingDocuments.text(
      of: row, info: info, showEcho: showEcho, locale: Locale.current.identifier,
      localizations: Bundle.main.preferredLocalizations, bypass: meetingDocumentsBypass)
    switch text.kind {
    case .unavailable: return .unavailable
    case .everythingHidden: return .everythingHidden
    case .visible:
      guard let info else { return .unavailable }
      let visible = MeetingTranscriptProjection.visible(
        turns: row.turns ?? [], echoTurnIDs: info.echoTurnIDs, showEcho: showEcho)
      return .visible(turns: visible.turns, plainText: text.plain)
    }
  }

  /// A meeting row's two-line list preview, the same text `meetingProjection` gives, read from
  /// the kept meeting text (#4001 step 2a) so a row body does not project the whole meeting.
  /// The meeting info and echo choice are read on every call, so the row stays subscribed.
  func meetingPreviewText(of row: Transcript) -> String {
    guard let meetingID = row.meetingID else {
      return MeetingHistoryPresentation.unavailableMessage
    }
    let text = meetingDocuments.text(
      of: row, info: meetingInfo?(meetingID), showEcho: isShowingEcho(rowID: row.id),
      locale: Locale.current.identifier, localizations: Bundle.main.preferredLocalizations,
      bypass: meetingDocumentsBypass)
    switch text.kind {
    case .visible: return text.plain
    case .everythingHidden: return MeetingHistoryPresentation.everythingHiddenMessage
    case .unavailable: return MeetingHistoryPresentation.unavailableMessage
    }
  }

  /// The text search reads: a meeting's visible text only, never hidden echo lines.
  private func searchableText(
    of row: Transcript, info: MeetingHistoryInfo?, showEcho: Bool, locale: String,
    localizations: [String]
  ) -> String {
    guard row.isMeeting else { return row.historyText }
    let text = meetingDocuments.text(
      of: row, info: info, showEcho: showEcho, locale: locale, localizations: localizations,
      bypass: meetingDocumentsBypass)
    return text.kind == .visible ? text.plain : ""
  }

  /// Whether the meeting document cache is bypassed: only the DEBUG reference build of the list
  /// (`listCacheDisabledForTesting`), never Release.
  private var meetingDocumentsBypass: Bool {
    #if DEBUG
      listCacheDisabledForTesting
    #else
      false
    #endif
  }

  /// A meeting summary's source text: the visible text, echo always hidden, nil when nothing is
  /// visible (`HistoryMeetingDocumentCache.summaryText`). The caller reads the row and the
  /// meeting facts live, before this lookup.
  func summaryVisibleText(of row: Transcript, info: MeetingHistoryInfo?) -> String? {
    summaryText(of: row, info: info).visibleText
  }

  /// #4148: true when the same projection is known and has no visible transcript text.
  func summaryHasNoWords(of row: Transcript, info: MeetingHistoryInfo?) -> Bool {
    summaryText(of: row, info: info).hasNoWords
  }

  private func summaryText(
    of row: Transcript, info: MeetingHistoryInfo?
  ) -> HistoryMeetingDocumentCache.MeetingText {
    meetingDocuments.summaryText(
      of: row, info: info, locale: Locale.current.identifier,
      localizations: Bundle.main.preferredLocalizations, bypass: meetingDocumentsBypass)
  }

  /// Removes one row from disk and from the list (#2807). Announces nothing: `delete(_:)`
  /// announces for History's own deletes, and EnviousMeet calls this as the deletion authority
  /// of a meeting's row (#3972 R12), so it must not call back. Throws when the file is still
  /// there.
  /// Removes a row without announcing it (EnviousMeet's own removals). One queued command.
  func removeRow(id: UUID) async throws {
    try Task.checkCancellation()
    _ = try await transactionExecutor.admit { [self] in
      await transactionExecutor.capture { try await performRemoval(id) }
    }.get()
  }

  enum Removal: Sendable, Equatable { case removed, alreadyAbsent }

  /// The removal command: both copies on the storage worker, then the publication. A row
  /// absent from History and confirmed absent from both folders is `alreadyAbsent`, and
  /// changes nothing on screen.
  private func performRemoval(_ id: UUID) async throws -> Removal {
    try await performRemovalWithCleanup(id).removal
  }

  /// `performRemoval` with whether the row's recording cleanup failed (the text can still have
  /// gone), for History's deletion outcomes (#3147 PR2).
  private func performRemovalWithCleanup(_ id: UUID) async throws
    -> (removal: Removal, recordingCleanupFailed: Bool)
  {
    let known = transcripts.first { $0.id == id }
    let listed = known != nil
    // #3147: meetings and imports never have a dictation recording, so their removal never
    // depends on the dictation archive. Decided from the row before its text goes.
    let mayHaveRecording = known.map { $0.meetingID == nil && !$0.isImported } ?? true
    // #3147 PR3: an import's players stop and its pending Transcribe again goes stale first.
    if known?.isImported == true {
      onImportedContentWillChange?(id)
      replacementTickets[id] = nil
    }
    let existed = try await transactionExecutor.remove(id: id)
    // #3147: a dictation's recording goes with it, also when the text was already gone (a
    // leftover). A failure is reported, never hidden behind the text's removal; launch
    // reconciliation removes the leftover later.
    let recordingCleanupFailed = mayHaveRecording ? !(await forgetRecording(of: id)) : false
    guard listed || existed else { return (.alreadyAbsent, recordingCleanupFailed) }
    transcripts.removeAll { $0.id == id }
    removedRowIDs.insert(id)
    echoShownRowIDs.remove(id)
    refreshDiskStateThenStopIfIdle()
    return (.removed, recordingCleanupFailed)
  }

  func deleteAll() async {
    guard !Task.isCancelled else { return }
    // #4075 S1: admitted behind earlier commands. Its marking, handoff and publication are one
    // command: History's queue stays held while the meeting marks are awaited (#4102), so later
    // saves, removals and a second Delete All wait behind it, while the main actor keeps running.
    await transactionExecutor.admit { [self] in await performDeleteAll() }
  }

  private func performDeleteAll() async {
    // #3972 R45: every meeting goes too, also one with no History row yet.
    var meetingIDs = transcripts.compactMap(\.meetingID)
    for record in meetingRecords?() ?? [] where !meetingIDs.contains(record.id) {
      meetingIDs.append(record.id)
    }
    if !meetingIDs.isEmpty, let marking = meetingsWillBeDeletedWithAll,
      await marking(meetingIDs) == false
    {
      actionFailure = .deleteAll
      Task {
        await AppLogger.shared.log(
          "Delete All refused: a meeting could not be marked for deletion",
          level: .info, category: "TranscriptCoordinator")
      }
      return
    }
    // #3147 PR3: every import's players stop and pending Transcribe again runs go stale first.
    for row in transcripts where row.isImported { onImportedContentWillChange?(row.id) }
    replacementTickets.removeAll()
    do {
      try transactionExecutor.deleteAll()
      // #3147: every recording goes with the rows. A failure is reported as a failed Delete All
      // after the text is gone; launch reconciliation removes what is left.
      do {
        try await recordings?.removeAllInCommand()
      } catch {
        actionFailure = .deleteAll
        Task {
          await AppLogger.shared.log(
            "Delete All left dictation recordings: \(type(of: error))",
            level: .info, category: "TranscriptCoordinator")
        }
      }
      let removedIDs = transcripts.map(\.id)
      transcripts.removeAll()
      removedRowIDs.formUnion(removedIDs)
      echoShownRowIDs.removeAll()
      // The same announcement `delete(_:)` makes, per row, after the list is already empty
      // (found by cloud review, round 3: this route bypassed it).
      for id in removedIDs { onRowDeleted?(id) }
      refreshDiskStateThenStopIfIdle()
    } catch {
      actionFailure = .deleteAll
      Task {
        await AppLogger.shared.log(
          "Failed to delete all transcripts: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }

  /// Inside a removal command: withdraws and deletes the row's recording, reporting a failure.
  /// False when the recording could not be removed (reported as a delete failure as before).
  @discardableResult
  private func forgetRecording(of id: UUID) async -> Bool {
    guard let recordings else { return true }
    do {
      try await recordings.forgetInCommand(rowID: id)
      return true
    } catch {
      actionFailure = .delete
      Task {
        await AppLogger.shared.log(
          "Deleted transcript left its recording: \(type(of: error))",
          level: .info, category: "TranscriptCoordinator")
      }
      return false
    }
  }

  // MARK: - Escape Recovery expiry pulse (#2087)


  private func startPulseIfNeeded() {
    guard pulseTask == nil,
      diskReconciler.pendingPulseHasWork(liveInMemory: livePendingCount)
    else { return }
    pulseTask = Task { [weak self, pendingPulseInterval, pendingPulseSleep] in
      while !Task.isCancelled {
        await pendingPulseSleep(pendingPulseInterval)
        guard let self, !Task.isCancelled else { return }
        // Bumped BEFORE the stop check, so the pulse that carries the last row
        // past its deadline is itself delivered — otherwise the final expiry
        // would stop the timer and never redraw, leaving the expired row on
        // screen until something unrelated moved.
        self.expiryPulse &+= 1
        // #2087: the pulse is where an expiry is DETECTED, so it is where the
        // file must go and the event must fire. Sweeping only on `load()` left
        // cleanup and telemetry waiting for the user to reopen History — which
        // for a row that aged out while they watched could be days, or never.
        //
        // Asks "can I see a lapsed row" rather than comparing the live count
        // before and after. The comparison version could never fire: both reads
        // happen after the wait, so they are always equal, and it only appeared
        // to work because the row sometimes expired BETWEEN them. A test that
        // removed the wall clock is what exposed it.
        if self.diskReconciler.pendingSweepIsDue(
          lapsedInMemory: self.lapsedPendingCount, now: Date())
        {
          await self.sweepExpiredPending()
        }
        // AFTER the sweep above, never before: this asks whether a countdown is
        // running or a file resisted removal, and the sweep is what settles the
        // second half. Stopping on the live count alone is what stranded a
        // failed removal, because the retry it was promised never came.
        if !self.diskReconciler.pendingPulseHasWork(liveInMemory: self.livePendingCount) {
          self.pulseTask = nil
          return
        }
      }
    }
  }

  private func stopPulseIfIdle() {
    guard !diskReconciler.pendingPulseHasWork(liveInMemory: livePendingCount) else { return }
    pulseTask?.cancel()
    pulseTask = nil
  }

  /// #2186: after an action that REMOVES pending files, re-read disk truth
  /// before deciding the pulse is idle.
  ///
  /// `liveOnDiskPendingCount` is a CACHE of the last sweep, and Keep, Delete and
  /// Delete All all change the directory it describes. Calling `stopPulseIfIdle`
  /// on the stale value means `pendingPulseHasWork` still sees the removed row,
  /// so the pulse never stops — a directory walk every minute for the life of
  /// the app, which is precisely the stranded-retry this file's own comments
  /// warn about, reintroduced through a cache those comments predate.
  ///
  /// A sweep rather than zeroing the count: zeroing is wrong whenever ANOTHER
  /// pending row is still counting down, and it would stop that row's timer.
  /// Only the directory knows. The sweep re-arms if work remains, so the stop
  /// below can then be trusted. Cloud review, P2.
  private func refreshDiskStateThenStopIfIdle() {
    // SYNCHRONOUS first, and that is a contract rather than an optimisation:
    // `Keep stops the pulse once the last held row is gone` asserts the pulse is
    // gone the instant Keep returns. Making this purely async broke it — the
    // full lane caught it, this suite did not, because the new tests await the
    // refresh and the old one does not.
    //
    // The cache is INVALIDATED rather than trusted or preserved. It describes a
    // directory this removal just changed, so keeping it blocks the stop (the
    // round-2 P2), and believing its old value is what made it stale. Zeroing
    // can only stop the pulse EARLY; the refresh below re-arms within moments if
    // another row is still counting down, and only the directory can say.
    diskReconciler.invalidateDiskState()
    stopPulseIfIdle()
    refreshTask = Task { [weak self] in
      await self?.sweepExpiredPending()
      self?.stopPulseIfIdle()
    }
  }


  /// Held so a test can await the refresh rather than guess at a duration —
  /// a signal the subject itself fires, never a sleep or a yield count.
  private var refreshTask: Task<Void, Never>?

  #if DEBUG
    // periphery:ignore - test seam
    var hasPendingPulseForTesting: Bool { pulseTask != nil }

    /// Bumps the pulse the way the loop does, so a test can assert that reading
    /// the visible list actually subscribes to it — without driving the loop.
    // periphery:ignore - test seam
    func bumpExpiryPulseForTesting() {
      expiryPulse &+= 1
    }

    /// The unfiltered rows. Only for assertions about state the read-time
    /// filter deliberately HIDES — an expired row that must keep its stamp, for
    /// instance. Anything a user would see is asserted through
    /// `visibleTranscripts`, which is what production reads.
    // periphery:ignore - test seam
    var rawTranscriptsForTesting: [Transcript] { transcripts }

    /// The pulse's sweep trigger, so a test can assert it returns to zero
    /// after a sweep rather than keeping the directory walk alive.
    // periphery:ignore - test seam
    var lapsedPendingCountForTesting: Int { lapsedPendingCount }


    /// Awaits the post-removal disk refresh. Captured before awaiting because
    /// the task clears nothing but may be replaced by a later removal.
    // periphery:ignore - test seam
    func waitForRefreshForTesting() async {
      let running = refreshTask
      await running?.value
    }

    /// Awaits the pulse loop's own completion — a real signal, so a test never
    /// guesses how long the loop needs. Captured before awaiting because the
    /// loop nils the handle as it exits.
    // periphery:ignore - test seam
    func waitForPulseForTesting() async {
      let running = pulseTask
      await running?.value
    }

    /// The deadline behind `waitForPulseForTesting`. A loop that stopped
    /// honouring its own exit condition would otherwise spin forever and HANG
    /// the suite — no test name, no assertion, just a wedged run — which is
    /// worse than having no test. A test bounds its iterations and calls this,
    /// so the regression fails loudly instead.
    // periphery:ignore - test seam
    func cancelPulseForTesting() {
      pulseTask?.cancel()
      pulseTask = nil
    }

  #endif

  /// Bulk fixture seam, available in BOTH configurations (#3013). It used to sit
  /// inside the `#if DEBUG` block above, so the Release run of the 25,000-row
  /// History cost test fell back to `saveAndShow` once per row (25,000 disk
  /// writes and front-inserts before the stopwatch started): 276 s on the hosted
  /// Release lane against 0.2 s in Debug (2026-09-16). The other Debug-only
  /// helpers stay where they are; only the seam the test needs in both
  /// configurations is here.
  // periphery:ignore - test seam
  func setTranscriptsForTesting(_ rows: [Transcript]) {
    transcripts = rows
    diskReconciler.invalidateReadCache()
    startPulseIfNeeded()
  }
}

/// Why the History list is empty (#2807). Each case has a different fix, so each gets its own
/// sentence.
enum HistoryEmptyState: Equatable, Sendable {
  /// Nothing has ever been recorded or imported.
  case nothingYet
  /// Rows exist, none of them a dictation.
  case noDictations
  /// Rows exist, none of them a Transcribe a File transcript.
  case noTranscripts
  /// Rows exist, no meeting (#3972 R34).
  case noRecordings
  /// Rows exist, none matching the search.
  case noMatches
}

/// Which kind of item a History list shows: one tab's kind.
enum HistoryListKind: Equatable, Sendable {
  case dictations, transcripts, meetings

  init(_ tab: HistoryTab) {
    switch tab {
    case .dictations: self = .dictations
    case .transcripts: self = .transcripts
    case .meetings: self = .meetings
    }
  }
}

/// One History list item's identity (#3972 R45): a dictation or an import by its row's id, a
/// meeting by its MEETING id, from Start to deletion (its row, when it exists, has another id).
enum HistoryItemID: Hashable, Sendable {
  case transcript(UUID)
  case meeting(UUID)
}

/// A meeting as History lists it: EnviousMeet's record, and its History row once one exists.
/// Either can be missing: a meeting still recording has no row, a row whose meeting folder is
/// gone has no record.
struct HistoryMeetingItem {
  let meetingID: UUID
  let record: MeetingRecord?
  let row: Transcript?

  var createdAt: Date { record?.createdAt ?? row?.createdAt ?? .distantPast }
}

/// One item of the History list (#3972 R45).
enum HistoryListItem: Identifiable {
  case transcript(Transcript)
  case meeting(HistoryMeetingItem)

  var id: HistoryItemID {
    switch self {
    case .transcript(let row): return .transcript(row.id)
    case .meeting(let meeting): return .meeting(meeting.meetingID)
    }
  }

  var createdAt: Date {
    switch self {
    case .transcript(let row): return row.createdAt
    case .meeting(let meeting): return meeting.createdAt
    }
  }

  /// The History row behind the item, if it has one.
  var row: Transcript? {
    switch self {
    case .transcript(let row): return row
    case .meeting(let meeting): return meeting.row
    }
  }
}
