import EnviousWisprCore
import EnviousWisprStorage
import SwiftUI

/// History's diary (#3147 §3.3): the three tabs, the filter row, and each tab's items grouped by
/// day, newest first, 30 at a time. The dictation card and the transcript and meeting
/// destinations come in through closures, so this shell never builds them itself.
///
/// Single-screen exception to the 300-line split rule: this file holds the shell and the small
/// row and header parts only it draws; the filter row, help, selection toolbar and paging rules
/// live in their own files.
struct HistoryDiaryView<
  DictationCard: View, TranscriptDestination: View, MeetingDestination: View
>: View {
  private let coordinator: TranscriptCoordinator
  private let dictationCard: (HistoryDictationDisplay, String) -> DictationCard
  private let transcriptDestination: (UUID, @escaping () -> Void) -> TranscriptDestination
  private let meetingDestination: (UUID, @escaping () -> Void) -> MeetingDestination

  @State private var selection = HistorySelection()
  @State private var isSelecting = false
  @State private var results: [HistoryTab: HistoryQueryResult] = [:]
  @State private var groupingRevision = 0
  @State private var pendingPage: HistoryCatalog.Cursor?
  /// Where the reader is in the list, as of its last scroll step (`HistoryDiaryList` writes it).
  @State private var liveAnchor = HistoryLiveAnchor()

  init(
    coordinator: TranscriptCoordinator,
    @ViewBuilder dictationCard: @escaping (HistoryDictationDisplay, String) -> DictationCard,
    @ViewBuilder transcriptDestination: @escaping (UUID, @escaping () -> Void) ->
      TranscriptDestination,
    @ViewBuilder meetingDestination: @escaping (UUID, @escaping () -> Void) -> MeetingDestination
  ) {
    self.coordinator = coordinator
    self.dictationCard = dictationCard
    self.transcriptDestination = transcriptDestination
    self.meetingDestination = meetingDestination
  }

  var body: some View {
    let tab = coordinator.historyTab
    let state = coordinator.requestedHistoryState(for: tab)
    let key = coordinator.historyQueryKey(for: tab, state: state)
    let saved = results[tab]
    let source = coordinator.catalogSession?.stableSourceRevision
    // #4598: a page for the same tab, search and filters stays on screen while a newer one is
    // read; its rows are re-verified against their files and it cannot page, select or count.
    let result =
      coordinator.catalogSession == nil || saved?.catalogSourceRevision == source
      ? saved
      : saved.flatMap {
        $0.key.context == key.context ? coordinator.retainedHistoryResult($0) : nil
      }
    let current = result?.key == key
    let canSelect = result.map(coordinator.isCurrentHistoryResult) == true
    let catalogStatus = coordinator.catalogSession?.status
    let openID = state.openItemID
    let canOpen =
      openID.map { id in
        if coordinator.catalogSession != nil { return true }
        if current, result?.ids.contains(id) == true { return true }
        return coordinator.isHistoryDestinationAvailable(id)
      } ?? false

    VStack(spacing: 0) {
      if let openID, tab != .dictations, canOpen {
        destination(for: openID)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .environment(\.historyHighlightQuery, state.query)
      } else {
        VStack(alignment: .leading, spacing: 12) {
          SettingsTabStrip(items: HistoryDiaryLayout.tabItems, selection: tabBinding)
          HistoryFiltersView(
            coordinator: coordinator, tab: tab, state: state, isSelecting: isSelecting,
            toggleSelecting: toggleSelecting)
          if isSelecting {
            HistorySelectionToolbar(
              coordinator: coordinator, tab: tab, selection: selection,
              result: canSelect ? result : nil)
          }
          if tab == .meetings, isSelecting == false {
            HistoryMeetingsBar(coordinator: coordinator)
          }
          if catalogStatus == .updating {
            Label("Updating History…", systemImage: "clock.arrow.circlepath")
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
          } else if catalogStatus == .unavailable {
            Label("Couldn't load History", systemImage: "exclamationmark.triangle")
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
          } else if catalogStatus == nil, coordinator.historyReadAvailability == .unavailable,
            result?.items.isEmpty == false
          {
            HStack {
              Label("Couldn't load History", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.stTextSecondary)
              Spacer()
              Button("Try again") { coordinator.loadIfNeeded() }
            }
            .font(.stHelper)
          }
        }
        .padding(.horizontal, SettingsLayout.contentH)
        .padding(.top, SettingsLayout.contentTop)
        .padding(.bottom, 12)

        HistoryDiaryList(
          coordinator: coordinator, tab: tab, state: state, selection: selection,
          isSelecting: isSelecting, result: result, isCurrent: current,
          canSelect: canSelect,
          liveAnchor: liveAnchor, open: open, loadNext: loadNext, dictationCard: dictationCard
        )
        // Its own identity per tab, so each tab's list restores and saves its own place.
        .id(tab)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
      groupingRevision &+= 1
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
    ) { _ in
      groupingRevision &+= 1
    }
    .task(id: RefreshKey(query: key, grouping: groupingRevision)) {
      guard results[tab]?.key != key else { return }
      // A refresh with the same tab, search and filters (a catalog update, an expiry, a time
      // zone or locale change) restores around the saved anchor: save where the reader is now
      // first, so it never jumps back to the place they last left (cloud review on #4582).
      var live = coordinator.requestedHistoryState(for: tab)
      if live.openItemID == nil, let context = liveAnchor.context, context == key.context,
        context == HistoryPaging.Context(tab: tab, state: live),
        live.scrollAnchorID != liveAnchor.id
      {
        live.scrollAnchorID = liveAnchor.id
        coordinator.setHistoryState(live, for: tab)
      }
      if let result = await coordinator.historyResults(for: key) {
        #if DEBUG
          // #4611 listening code: how long after its save a new item reached the list.
          if let newest = result.items.first, newest.id != results[tab]?.items.first?.id {
            let age = Date().timeIntervalSince(newest.createdAt)
            if age < 120 {
              let line = "new item shown tab=\(tab.rawValue) secondsAfterSave=\(String(format: "%.2f", age))"
              Task { await AppLogger.shared.log(line, level: .info, category: "HistoryScroll") }
            }
          }
        #endif
        results[tab] = result
        if isSelecting, coordinator.historyTab == tab {
          if let matching = await coordinator.matchingIDs(for: result) {
            selection.retain(Set(matching))
          }
        }
      }
    }
    .onChange(of: catalogStatus) { previous, current in
      if previous == .updating, current == .ready {
        AccessibilityNotification.Announcement(
          String(
            localized: "History is up to date.",
            comment: "VoiceOver: the History index finished updating.")
        ).post()
      }
    }
    .onChange(of: tab) { _, _ in
      pendingPage = nil
      // Selection belongs to one tab's list; a tab switch ends it.
      isSelecting = false
      selection.clear()
    }
  }

  private struct RefreshKey: Equatable {
    let query: TranscriptCoordinator.HistoryQueryKey
    let grouping: Int
  }

  private var tabBinding: Binding<HistoryTab> {
    Binding(
      get: { coordinator.historyTab },
      set: { coordinator.selectHistoryTab($0) })
  }

  @ViewBuilder private func destination(for id: HistoryItemID) -> some View {
    switch id {
    case .transcript(let rowID): transcriptDestination(rowID, closeOpenItem)
    case .meeting(let meetingID): meetingDestination(meetingID, closeOpenItem)
    }
  }

  private func open(_ id: HistoryItemID) {
    let tab = coordinator.historyTab
    var state = coordinator.requestedHistoryState(for: tab)
    guard results[tab]?.key == coordinator.historyQueryKey(for: tab, state: state),
      results[tab]?.ids.contains(id) == true,
      coordinator.catalogSession == nil
        || results[tab]?.catalogSourceRevision == coordinator.catalogSession?.stableSourceRevision
    else { return }
    state.openItemID = id
    coordinator.setHistoryState(state, for: coordinator.historyTab)
  }

  private func loadNext(_ result: HistoryQueryResult, newer: Bool) {
    let tab = result.key.context.tab
    let cursor = newer ? result.newerContinuation : result.continuation
    let current = newer ? results[tab]?.newerContinuation : results[tab]?.continuation
    guard let cursor, pendingPage == nil, current == cursor,
      result.catalogSourceRevision == coordinator.catalogSession?.stableSourceRevision
    else { return }
    pendingPage = cursor
    Task {
      defer { if pendingPage == cursor { pendingPage = nil } }
      guard
        let next = await coordinator.historyResults(
          for: result.key, extending: result, newer: newer),
        coordinator.historyTab == tab, results[tab]?.key == result.key
      else { return }
      let current = newer ? results[tab]?.newerContinuation : results[tab]?.continuation
      guard current == cursor else { return }
      results[tab] = next
    }
  }

  private func closeOpenItem() {
    var state = coordinator.requestedHistoryState(for: coordinator.historyTab)
    state.scrollAnchorID = state.openItemID
    state.openItemID = nil
    coordinator.setHistoryState(state, for: coordinator.historyTab)
  }

  private func toggleSelecting() {
    isSelecting.toggle()
    selection.clear()
  }
}

/// The scrolling, day-grouped list of one tab, drawn a page at a time.
private struct HistoryDiaryList<DictationCard: View>: View {
  let coordinator: TranscriptCoordinator
  let tab: HistoryTab
  let state: HistoryTabState
  let selection: HistorySelection
  let isSelecting: Bool
  let result: HistoryQueryResult?
  let isCurrent: Bool
  let canSelect: Bool
  /// The item under the reader as of the last scroll step, shared with the refresh above.
  let liveAnchor: HistoryLiveAnchor
  let open: (HistoryItemID) -> Void
  let loadNext: (HistoryQueryResult, Bool) -> Void
  let dictationCard: (HistoryDictationDisplay, String) -> DictationCard

  /// #4611: the place to put at the top once its rows are installed (on appear, and when the
  /// search or filters change).
  @State private var restore: HistoryDiaryTable.Restore?
  /// #3147 PR3: the import whose Locate original flow is running, and its one-line result.
  @State private var locatingRowID: UUID?
  @State private var locateNote: LocateNote?
  @Environment(ImportedSources.self) private var importedSources

  private struct LocateNote: Identifiable {
    let id = UUID()
    let text: String
  }

  var body: some View {
    let items = result?.items ?? []
    let context = result?.key.context ?? HistoryPaging.Context(tab: tab, state: state)
    let window = HistoryPaging.window(
      items: items, context: context, state: HistoryPaging.state(state, tab: tab),
      selected: state.scrollAnchorID, positions: result?.positions)
    let catalog = result?.catalogSourceRevision != nil
    let request = isCurrent && !catalog ? HistoryPaging.request(for: window) : nil
    let hasNext = catalog && isCurrent && result?.continuation != nil
    let boundary = catalog ? items.count : window.boundary
    let entries = result?.entries(through: boundary) ?? []
    var lookup: [HistoryDiaryLayout.EntryID: HistoryQueryResult.Entry] = [:]
    // One flat list of day headings and items. The result preserves positions, but cards read
    // live detail: an expired recovery or a meeting being deleted is left out of the rows.
    var rows: [HistoryDiaryTable.RowID] = []
    if isCurrent, let result, result.newerContinuation != nil { rows.append(.newer) }
    for entry in entries {
      if case .item = entry.id, !coordinator.canRenderHistoryItem(items[entry.position]) {
        continue
      }
      lookup[entry.id] = entry
      rows.append(.entry(entry.id))
    }
    if request != nil || hasNext { rows.append(.older) }
    let paging = Paging(window: window, request: request, hasNext: hasNext, now: Date())

    return HistoryDiaryTable(
      rows: rows, restore: restore, rowsAreFinal: isCurrent && result != nil,
      content: { row in
        AnyView(
          HistoryDiaryRowBody {
            self.row(row, lookup: lookup, items: items, query: context.query, paging: paging)
          })
      },
      onScroll: { entry in
        // Kept unobserved, so scrolling does not re-render the page.
        guard let result else { return }
        liveAnchor.id = result.anchor(for: entry)
        liveAnchor.context = result.key.context
      }
    )
    // Each tab keeps its place (#3147 §3.3): restored when its list appears, saved when it
    // leaves for another tab or an open item.
    .onAppear {
      restore = .init(token: 1, target: state.scrollAnchorID.map { .item($0) })
    }
    .onChange(of: result?.key.context) { _, next in
      guard next == HistoryPaging.Context(tab: tab, state: state) else { return }
      restore = .init(
        token: (restore?.token ?? 0) + 1, target: state.scrollAnchorID.map { .item($0) })
    }
    .onDisappear {
      saveLiveAnchor()
      liveAnchor.context = nil
    }
    .background(Color.stPageBg)
    // #4001 step 2a: the recording state is read inside the modifier, not by this body.
    .recordingDimmed()
    .overlay {
      if items.isEmpty && coordinator.catalogSession?.status == .unavailable {
        ContentUnavailableView {
          Label("Couldn't load History", systemImage: "exclamationmark.triangle")
        }
      } else if items.isEmpty && coordinator.catalogSession?.status == .updating {
        ProgressView()
      } else if coordinator.catalogSession == nil,
        items.isEmpty && coordinator.historyReadAvailability == .unavailable
      {
        ContentUnavailableView {
          Label("Couldn't load History", systemImage: "exclamationmark.triangle")
        } actions: {
          Button("Try again") { coordinator.loadIfNeeded() }
        }
      } else if items.isEmpty
        && (!isCurrent
          || (coordinator.catalogSession == nil && coordinator.historyReadAvailability == .loading))
      {
        ProgressView()
      } else if let empty = HistoryDiaryLayout.emptyState(
        tab: tab, state: state, matchingCount: items.count)
      {
        HistoryEmptyView(state: empty)
      }
    }
    .alert(
      Text("Locate original", comment: "History: title of the Locate original result message."),
      isPresented: Binding(
        get: { locateNote != nil }, set: { if $0 == false { locateNote = nil } })
    ) {
      Button(String(localized: "OK", comment: "History: dismisses the Locate original result.")) {}
    } message: {
      Text(verbatim: locateNote?.text ?? "")
    }
  }

  /// What the rows need to ask for the next page.
  private struct Paging {
    let window: HistoryPaging.Window
    let request: HistoryPaging.LoadRequest?
    let hasNext: Bool
    let now: Date
  }

  /// One row of the table. Built inside the hosted row's own body, so what it reads (selection,
  /// live rows, players) re-renders that row alone.
  @ViewBuilder private func row(
    _ row: HistoryDiaryTable.RowID, lookup: [HistoryDiaryLayout.EntryID: HistoryQueryResult.Entry],
    items: [HistoryListItem], query: String, paging: Paging
  ) -> some View {
    switch row {
    case .newer:
      if let result {
        Button {
          loadNext(result, true)
        } label: {
          Text(
            "Load more history",
            comment: "History list: the button at the end of the shown rows that shows older ones."
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .padding(.vertical, DesignSpacing.md)
        }
        .buttonStyle(.plain)
        // A list that reopened at an older place fills in the newer rows by itself as soon as
        // the top of the list shows, the same way the bottom loads older rows. The table keeps
        // the reader's place while the newer rows arrive above.
        .onAppear { loadNext(result, true) }
      }
    case .older:
      Button {
        if let request = paging.request {
          loadMore(request)
        } else if let result {
          loadNext(result, false)
        }
      } label: {
        Text(
          "Load more history",
          comment:
            "History list: the button at the end of the shown rows that shows older ones."
        )
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    case .entry(.day(let start)):
      let entry = lookup[.day(start)]
      HistoryDayHeader(
        tab: tab, day: .init(start: start, items: [], total: entry?.dayCount ?? 0),
        hasExactTotal: entry?.dayCount != nil, now: paging.now,
        isSelecting: isSelecting && canSelect,
        selectDay: {
          guard let result else { return }
          Task {
            if let matching = await coordinator.matchingIDs(for: result, day: start) {
              selection.select(Set(matching))
            }
          }
        })
    case .entry(.item(let id)):
      if let entry = lookup[.item(id)], items.indices.contains(entry.position),
        coordinator.canRenderHistoryItem(items[entry.position])
      {
        let item = items[entry.position]
        self.row(for: item, items: items, query: query)
          .onAppear {
            // A best-effort prefetch hint: it can come early, together with other rows,
            // or twice; `loadMore` accepts one request per window.
            // #4611: the next page starts loading ten cards before the end, so a scroll that
            // keeps going never meets the end of the list.
            let ahead = HistoryPaging.pageSize / 3
            if entry.position >= paging.window.boundary - ahead, let request = paging.request {
              loadMore(request)
            }
            if entry.position >= items.count - ahead, paging.hasNext, let result {
              loadNext(result, false)
            }
          }
      }
    }
  }

  @ViewBuilder private func row(
    for item: HistoryListItem, items: [HistoryListItem], query: String
  ) -> some View {
    HStack(alignment: .top, spacing: 10) {
      if isSelecting && canSelect {
        HistorySelectionBox(
          isSelected: selection.selectedIDs.contains(item.id),
          toggle: { extending in tick(item.id, extending: extending, items: items) })
      }
      HistoryDiaryTime(item: item)
      switch item {
      case .transcript(let row) where row.isImported == false:
        dictationCard(HistoryDictationDisplay(row), query)
          .contentShape(Rectangle())
          .gesture(
            TapGesture().onEnded {
              tick(item.id, extending: NSEvent.modifierFlags.contains(.shift), items: items)
            },
            including: isSelecting && canSelect && row.escapeRecoveredAt == nil ? .all : .subviews)
      case .transcript(let row):
        transcriptCard(row.id, item: item.id, items: items, query: query)
      case .meeting(let meeting):
        meetingCard(meeting.meetingID, item: item.id, items: items, query: query)
      case .catalog(let summary):
        switch summary.key.tab {
        case .dictations:
          HistoryCatalogDictationRow(
            summary: summary, coordinator: coordinator, query: query, card: dictationCard
          )
          .contentShape(Rectangle())
          .gesture(
            TapGesture().onEnded {
              tick(item.id, extending: NSEvent.modifierFlags.contains(.shift), items: items)
            }, including: isSelecting && canSelect && summary.expiresAt == nil ? .all : .subviews)
        case .transcripts:
          transcriptCard(
            summary.key.id, item: item.id, items: items, query: query, summary: summary)
        case .meetings:
          meetingCard(summary.key.id, item: item.id, items: items, query: query, summary: summary)
        }
      }
    }
  }

  /// #3147 PR3: an import's card. Its Open and Locate original are its own buttons; while
  /// selecting, the whole card ticks instead and its buttons take no clicks.
  @ViewBuilder private func transcriptCard(
    _ rowID: UUID, item: HistoryItemID, items: [HistoryListItem], query: String,
    summary: HistoryCatalog.Summary? = nil
  ) -> some View {
    let card = HistoryTranscriptCard(
      rowID: rowID, sources: importedSources, query: query, summary: summary,
      onOpen: { open(item) },
      onLocate: { locatingRowID = rowID })
    if isSelecting && canSelect {
      openableCard(item, items: items) { card.allowsHitTesting(false) }
    } else {
      card.historyTranscriptLocate(
        rowID: rowID, sources: importedSources,
        isPresented: Binding(
          get: { locatingRowID == rowID },
          set: { if $0 == false, locatingRowID == rowID { locatingRowID = nil } }),
        onResult: { text, _ in locateNote = LocateNote(text: text) })
    }
  }

  /// #3147 PR4A: a meeting's card. Its Open and title rename are its own buttons; while
  /// selecting, the whole card ticks instead and its buttons take no clicks.
  @ViewBuilder private func meetingCard(
    _ meetingID: UUID, item: HistoryItemID, items: [HistoryListItem], query: String,
    summary: HistoryCatalog.Summary? = nil
  ) -> some View {
    let card = HistoryMeetingCard(
      meetingID: meetingID, onOpen: { open(item) }, allowsPlayback: !isSelecting, query: query,
      summary: summary)
    if isSelecting && canSelect {
      openableCard(item, items: items) { card.allowsHitTesting(false) }
    } else {
      card
    }
  }

  /// A short card that opens its destination, or ticks itself while selecting.
  private func openableCard<Content: View>(
    _ id: HistoryItemID, items: [HistoryListItem], @ViewBuilder content: () -> Content
  ) -> some View {
    Button {
      guard isSelecting && canSelect else { return }
      tick(id, extending: NSEvent.modifierFlags.contains(.shift), items: items)
    } label: {
      content()
    }
    .buttonStyle(.plain)
  }

  /// Stores what is at the top as the tab's scroll anchor: the item there, the first item under
  /// a heading there, or nothing at the very top.
  /// Saves the anchor kept from the last scroll step as the tab's place, when the list leaves.
  private func saveLiveAnchor() {
    guard let context = liveAnchor.context else { return }
    saveAnchor(liveAnchor.id, context: context)
  }

  private func saveAnchor(_ anchor: HistoryItemID?, context: HistoryPaging.Context) {
    var live = coordinator.requestedHistoryState(for: tab)
    guard context == HistoryPaging.Context(tab: tab, state: live) else { return }
    guard live.scrollAnchorID != anchor else { return }
    live.scrollAnchorID = anchor
    coordinator.setHistoryState(live, for: tab)
  }

  /// One tick from a tick box or a card: Shift extends the range from the last ticked item.
  private func tick(_ id: HistoryItemID, extending: Bool, items: [HistoryListItem]) {
    guard let result, coordinator.isCurrentHistoryResult(result) else { return }
    if extending {
      Task {
        if let matching = await coordinator.matchingIDs(for: result) {
          selection.extend(to: id, in: matching)
        }
      }
    } else {
      selection.toggle(id)
    }
  }

  /// The one load action for the last row and Load more history. Synchronous on the main actor:
  /// it rebuilds the window from live state, accepts at most one page for it and stores the
  /// result before returning, so a second request for the same window is refused.
  private func loadMore(_ request: HistoryPaging.LoadRequest) {
    var live = coordinator.requestedHistoryState(for: tab)
    guard let result, result.key == coordinator.historyQueryKey(for: tab, state: live) else {
      return
    }
    let current = HistoryPaging.window(
      items: result.items,
      context: HistoryPaging.Context(tab: tab, state: live),
      state: HistoryPaging.state(live, tab: tab), selected: live.scrollAnchorID,
      positions: result.positions)
    let next = HistoryPaging.load(
      request, state: HistoryPaging.state(live, tab: tab), current: current)
    guard next.requested != live.requestedCount else { return }
    live.requestedCount = next.requested
    coordinator.setHistoryState(live, for: tab)
  }
}

/// #4611: builds a table row inside its own body, so the row tracks what it reads.
private struct HistoryDiaryRowBody<Content: View>: View {
  let build: () -> Content
  var body: some View { build() }
}

private struct HistoryCatalogDictationRow<Card: View>: View {
  let summary: HistoryCatalog.Summary
  let coordinator: TranscriptCoordinator
  let query: String
  let card: (HistoryDictationDisplay, String) -> Card

  /// #4609: the card draws complete from the catalog's display data on first display, so no
  /// file read can resize it while the list scrolls. A row this process holds live (just saved
  /// or edited here) draws from that row: for unchanged content both give the same card.
  private var display: HistoryDictationDisplay? {
    coordinator.currentRow(id: summary.key.id).map(HistoryDictationDisplay.init)
      ?? HistoryDictationDisplay(summary)
  }

  var body: some View {
    Group {
      if let display {
        card(display, query)
      } else {
        HistoryParagraphText.searchText(summary.preview, query: query)
          .font(.stBody)
          .foregroundStyle(.stTextBody)
          .lineLimit(3)
          .padding(DesignSpacing.lg)
          .frame(maxWidth: .infinity, alignment: .leading)
          .historyRowCard(isSelected: false)
      }
    }
  }
}

/// The approved diary keeps the time and source beside the card while its content can wrap.
private struct HistoryDiaryTime: View {
  let item: HistoryListItem

  private var app: String? {
    switch item {
    case .transcript(let row):
      row.isImported ? nil : row.metrics?.targetApp.map(HistoryAppName.label(for:))
    case .meeting(let meeting): meeting.record?.callApp?.displayName
    case .catalog(let summary):
      switch summary.key.tab {
      case .dictations: summary.appKey.map(HistoryAppName.label(for:))
      case .transcripts: nil
      case .meetings: summary.appKey.flatMap(CallAppFamily.init(rawValue:))?.displayName
      }
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: DesignSpacing.md) {
      VStack(alignment: .trailing, spacing: DesignSpacing.xxs) {
        Text(item.createdAt, format: .dateTime.hour().minute())
          .font(.stRowLabel)
          .foregroundStyle(.stTextPrimary)
          .monospacedDigit()
          .fixedSize()
        if let app, !app.isEmpty {
          Text(verbatim: app)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .multilineTextAlignment(.trailing)
            // #4611: one line; a long app name shrinks a little, then ends in "…", rather than
            // breaking mid-word in the narrow time column.
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .truncationMode(.tail)
        }
      }
      .frame(width: DesignSpacing.xxxl * 3, alignment: .trailing)
      .padding(.top, DesignSpacing.lg)
      Circle()
        .fill(Color.stPageBg)
        .overlay { Circle().strokeBorder(Color.stAccent, lineWidth: 1.5) }
        .frame(width: DesignSpacing.xl, height: DesignSpacing.xl)
        .padding(.top, DesignSpacing.xxl)
        .accessibilityHidden(true)
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .background(alignment: .trailing) {
      Rectangle()
        .fill(Color.stDivider)
        .frame(width: 1)
        .padding(.trailing, DesignSpacing.sm)
        .padding(.vertical, -DesignSpacing.sm)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The day heading: the date, Today or Yesterday, how many items the day holds, and Select day
/// while selecting.
private struct HistoryDayHeader: View {
  let tab: HistoryTab
  let day: HistoryDiaryLayout.Day
  let hasExactTotal: Bool
  let now: Date
  let isSelecting: Bool
  let selectDay: () -> Void

  var body: some View {
    let title = HistoryDiaryLayout.dayTitle(day.start, now: now, calendar: .current)
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.md) {
        Text(title.date)
          .font(.stDayTitle)
          .foregroundStyle(.stTextPrimary)
        if let relative = title.relative {
          // The approved mock's TODAY / YESTERDAY: the section eyebrow style, in the accent.
          Text(relative.uppercased())
            .font(.stSectionHeader)
            .tracking(0.8)
            .foregroundStyle(.stAccent)
        }
        Spacer(minLength: DesignSpacing.md)
        if hasExactTotal {
          Text(HistoryDiaryLayout.daySummary(tab: tab, count: day.total))
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
        }
        if isSelecting {
          Button(action: selectDay) {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Select day", comment: "History selection: ticks every item listed on this day."),
              size: .medium)
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
        }
      }
      Rectangle().fill(Color.stDivider).frame(height: 1)
        .accessibilityHidden(true)
    }
    .padding(.top, 8)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isHeader)
  }
}

/// The tick box beside an item in selection mode. Shift-click ticks the range from the last
/// ticked item.
private struct HistorySelectionBox: View {
  let isSelected: Bool
  let toggle: (_ extending: Bool) -> Void

  var body: some View {
    Button {
      toggle(NSEvent.modifierFlags.contains(.shift))
    } label: {
      Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        .font(.stRowTitle)
        .foregroundStyle(isSelected ? Color.stAccent : Color.stTextTertiary)
        .padding(.top, 12)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      String(localized: "Select", comment: "History selection: the tick box beside one item.")
    )
    .accessibilityValue(
      isSelected
        ? String(localized: "Selected", comment: "History selection: this item is ticked.")
        : String(localized: "Not selected", comment: "History selection: this item is not ticked.")
    )
  }
}

/// Above an open transcript or meeting: the way back to the tab's list.
struct HistoryDestinationBar: View {
  let tab: HistoryTab
  let close: () -> Void

  var body: some View {
    Button(action: close) {
      EnviousButtonLabel(
        verbatim: HistoryDiaryLayout.tabTitle(tab), size: .medium, systemImage: "chevron.left")
    }
    .settingsButton(.quiet, size: .medium, isEnabled: true)
    .accessibilityLabel(
      String(
        localized: "Back to \(HistoryDiaryLayout.tabTitle(tab))",
        comment: "History: returns from an open item to its tab's list. %@ is the tab's name."))
  }
}

/// The Meetings tab's own controls, moved from the old sidebar header: Record a meeting when
/// nothing records (the explainer first when it is due), a way to the live meeting while one
/// records, and the count of meetings a newer version saved.
private struct HistoryMeetingsBar: View {
  let coordinator: TranscriptCoordinator
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(MeetingStartFlow.self) private var startFlow

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      recordingControl
      // Meetings a newer EnviousWispr saved stay on disk, untouched; this build cannot open
      // them, so they are counted here rather than listed (#3972 §4).
      if let line = HistoryDiaryLayout.newerFormatLine(meetings.newerFormatMeetings.count) {
        Text(line)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Start Recording when nothing records (the explainer first when it is due for this Start);
  /// while a meeting records, a way to it. Stop lives in that meeting and the menu.
  @ViewBuilder private var recordingControl: some View {
    if startFlow.pendingExplainer == .history {
      MeetingCallSoundExplainer()
    } else {
      switch meetings.phase {
      case .idle:
        Button(action: startMeeting) {
          EnviousButtonLabel(
            MeetingsCopy.startRecording, size: .medium, systemImage: "record.circle")
        }
        .settingsButton(.filled, size: .medium, isEnabled: startFlow.waitingForMicrophone == nil)
      case .starting, .stopping:
        ProgressView().controlSize(.small)
      case .recording(let meetingID, _):
        Button {
          openMeeting(meetingID)
        } label: {
          EnviousButtonLabel(
            LocalizedStringResource(
              "Show the recording",
              comment: "History, Meetings: opens the meeting that is recording now."),
            size: .medium, systemImage: "record.circle")
        }
        .settingsButton(.outlined, size: .medium, isEnabled: true)
      }
    }
  }

  private func startMeeting() {
    Task {
      let outcome = await startFlow.requestStart(from: .history)
      if case .started(.recording(let meetingID)) = outcome { openMeeting(meetingID) }
    }
  }

  private func openMeeting(_ meetingID: UUID) {
    let id = HistoryItemID.meeting(meetingID)
    let current = coordinator.requestedHistoryState(for: .meetings)
    let state = HistoryDiaryLayout.opening(
      id, in: current, isListed: coordinator.isListedMeeting(meetingID, under: current))
    coordinator.setHistoryState(state, for: .meetings)
  }
}

/// History's diary rules as plain values, so grouping, headings and empty states are tested
/// without a view.
enum HistoryDiaryLayout {
  /// One day of the drawn list: its start, the items drawn on it and how many items in all
  /// (drawn or not) fall on it.
  struct Day: Identifiable {
    let start: Date
    let items: [HistoryListItem]
    let total: Int

    var id: Date { start }
  }

  /// A day heading or an item, in drawing order.
  enum Entry: Identifiable {
    case day(Day)
    case item(HistoryListItem)

    var id: EntryID {
      switch self {
      case .day(let day): .day(day.start)
      case .item(let item): .item(item.id)
      }
    }
  }

  /// The identity of an entry: the scroll position names one of these.
  enum EntryID: Hashable, Sendable {
    case day(Date)
    case item(HistoryItemID)
  }

  /// The item a scroll position stands for: the item itself, the first listed item on a day
  /// whose heading is at the top, or nil when nothing is scrolled.
  static func anchorID(for entry: EntryID?, in items: [HistoryListItem], calendar: Calendar)
    -> HistoryItemID?
  {
    switch entry {
    case .item(let id): return id
    case .day(let start):
      return items.first { calendar.isDate($0.createdAt, inSameDayAs: start) }?.id
    case nil: return nil
    }
  }

  /// `days` flattened: each heading followed by its drawn items.
  static func entries(_ days: [Day]) -> [Entry] {
    days.flatMap { day in [.day(day)] + day.items.map { .item($0) } }
  }

  /// The tabs in the strip, in order, with the Settings tab-strip look.
  static var tabItems: [SettingsTabItem<HistoryTab>] {
    HistoryTab.allCases.map { tab in
      SettingsTabItem(id: tab, icon: tabIcon(tab), label: tabLabel(tab))
    }
  }

  static func tabIcon(_ tab: HistoryTab) -> String {
    switch tab {
    case .dictations: "mic"
    case .transcripts: "doc.text"
    case .meetings: "person.2.wave.2"
    }
  }

  static func tabLabel(_ tab: HistoryTab) -> LocalizedStringResource {
    switch tab {
    case .dictations:
      LocalizedStringResource(
        "Dictations", comment: "History filter: rows made by dictating with the keyboard shortcut.")
    case .transcripts:
      LocalizedStringResource(
        "Transcripts", comment: "History filter: rows made with Transcribe a File.")
    case .meetings:
      LocalizedStringResource(
        "Meetings",
        comment: "History filter: meetings recorded with EnviousMeet, finished or still recording."
      )
    }
  }

  static func tabTitle(_ tab: HistoryTab) -> String { String(localized: tabLabel(tab)) }

  /// The drawn items (`items.prefix(boundary)`) grouped by `calendar` day in list order. Each
  /// day's `total` also counts that day's items past the boundary, read from the full list.
  static func days(items: [HistoryListItem], boundary: Int, calendar: Calendar) -> [Day] {
    var result: [Day] = []
    var index = 0
    let drawn = min(boundary, items.count)
    while index < drawn {
      let start = calendar.startOfDay(for: items[index].createdAt)
      let end = firstIndex(before: start, in: items, from: index)
      result.append(
        Day(start: start, items: Array(items[index..<min(end, drawn)]), total: end - index))
      index = end
    }
    return result
  }

  /// `state` with `id` open. When a search or filter hides the item (a meeting that just started
  /// on a tab filtered to yesterday), they are cleared so the item can open, as the old Show the
  /// recording cleared the search; otherwise the person's filters stay.
  static func opening(_ id: HistoryItemID, in state: HistoryTabState, isListed: Bool)
    -> HistoryTabState
  {
    var next = state
    if isListed == false {
      next.query = ""
      next.app = .all
      next.dateInterval = nil
      next.callApp = nil
    }
    next.openItemID = id
    return next
  }

  /// The first index at or after `from` whose item was created before `start`, by binary search
  /// over the newest-first list, so a day with thousands of items costs a few comparisons.
  static func firstIndex(before start: Date, in items: [HistoryListItem], from: Int) -> Int {
    var low = from
    var high = items.count
    while low < high {
      let mid = (low + high) / 2
      if items[mid].createdAt < start { high = mid } else { low = mid + 1 }
    }
    return low
  }

  /// Every listed item on `day`, drawn or not: what Select day ticks.
  static func ids(onDayOf day: Date, in items: [HistoryListItem], calendar: Calendar)
    -> Set<HistoryItemID>
  {
    Set(items.filter { calendar.isDate($0.createdAt, inSameDayAs: day) }.map(\.id))
  }

  /// Why the tab lists nothing, or nil when it lists something. A search or filter that hides
  /// every item says so, rather than "nothing yet" over items that exist.
  static func emptyState(tab: HistoryTab, state: HistoryTabState, matchingCount: Int)
    -> HistoryEmptyState?
  {
    guard matchingCount == 0 else { return nil }
    if state.query.isEmpty == false || state.listFilter != .none { return .noMatches }
    switch tab {
    case .dictations: return .noDictations
    case .transcripts: return .noTranscripts
    case .meetings: return .noRecordings
    }
  }

  /// The day heading's date ("Wednesday, November 11", with the year when it is not this year)
  /// and Today or Yesterday when it applies.
  static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> (
    date: String, relative: String?
  ) {
    var style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
    if calendar.component(.year, from: day) != calendar.component(.year, from: now) {
      style = style.year()
    }
    style.calendar = calendar
    style.timeZone = calendar.timeZone
    let date = day.formatted(style)
    if calendar.isDate(day, inSameDayAs: now) {
      return (
        date, String(localized: "Today", comment: "History: the day heading for today's items.")
      )
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(day, inSameDayAs: yesterday)
    {
      return (
        date,
        String(localized: "Yesterday", comment: "History: the day heading for yesterday's items.")
      )
    }
    return (date, nil)
  }

  /// "9 dictations", "1 transcript", one whole sentence per count and tab (#3142).
  static func daySummary(tab: HistoryTab, count: Int) -> String {
    switch (tab, count == 1) {
    case (.dictations, true):
      String(localized: "1 dictation", comment: "History day heading: one dictation that day.")
    case (.dictations, false):
      String(
        localized: "\(String(count)) dictations",
        comment: "History day heading: how many dictations that day. Never 1.")
    case (.transcripts, true):
      String(localized: "1 transcript", comment: "History day heading: one transcript that day.")
    case (.transcripts, false):
      String(
        localized: "\(String(count)) transcripts",
        comment: "History day heading: how many transcripts that day. Never 1.")
    case (.meetings, true):
      String(localized: "1 meeting", comment: "History day heading: one meeting that day.")
    case (.meetings, false):
      String(
        localized: "\(String(count)) meetings",
        comment: "History day heading: how many meetings that day. Never 1.")
    }
  }

  /// One whole sentence per count (#3142), or nil when every meeting opens.
  static func newerFormatLine(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    guard count != 1 else {
      return String(
        localized:
          "A recording was saved by a newer version of EnviousWispr. Update the app to open it.",
        comment:
          "History, Meetings: one meeting this version cannot open (a newer version saved it).")
    }
    return String(
      localized:
        "\(String(count)) recordings were saved by a newer version of EnviousWispr. Update the app to open them.",
      comment:
        "History, Meetings: how many meetings this version cannot open because a newer version saved them. Never 1."
    )
  }
}

/// What the History list shows when it lists nothing (#2807). One sentence per reason, because
/// the fix for each is different: record something, import something, change the filter, or
/// change the search.
struct HistoryEmptyView: View {
  let state: HistoryEmptyState

  var body: some View {
    switch state {
    case .nothingYet:
      ContentUnavailableView(
        "Nothing here yet",
        systemImage: "doc.text",
        description: Text("Your dictations, transcripts and recordings will appear here.")
      )
    case .noDictations:
      ContentUnavailableView(
        "No dictations yet",
        systemImage: "mic",
        description: Text("Press your keybind and start talking.")
      )
    case .noTranscripts:
      ContentUnavailableView(
        "No transcripts yet",
        systemImage: "doc.text",
        description: Text("Use Transcribe a File to add one.")
      )
    case .noRecordings:
      ContentUnavailableView(
        "No recordings yet",
        systemImage: "person.2.wave.2",
        description: Text("Start a recording from the menu bar.")
      )
    case .noMatches:
      ContentUnavailableView(
        "No matching history.",
        systemImage: "magnifyingglass",
        description: Text("Try a different search, or another filter.")
      )
    }
  }
}

extension View {
  /// The bordered card every History row is drawn in: the selected card carries an accent ring
  /// and a faint wash (mockup #27).
  func historyRowCard(isSelected: Bool) -> some View {
    self
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        // Opaque base so nothing bleeds through, plus a faint accent wash when
        // selected (matches the mockup's subtly purple-tinted active card).
        ZStack {
          RoundedRectangle(cornerRadius: DesignRadius.xl).fill(Color.stSectionBg)
          if isSelected {
            RoundedRectangle(cornerRadius: DesignRadius.xl).fill(Color.stAccent.opacity(0.12))
          }
        }
      }
      .overlay(
        RoundedRectangle(cornerRadius: DesignRadius.xl)
          .strokeBorder(
            isSelected ? Color.stAccent : Color.stDivider,
            lineWidth: isSelected ? 2 : 1)
      )
      // The row's own pointer feedback: History is the first page the app opens on and a list
      // whose whole purpose is picking one of many rows.
      .settingsHoverCard(cornerRadius: DesignRadius.xl, isSelected: isSelected)
      .contentShape(RoundedRectangle(cornerRadius: DesignRadius.xl))
  }

  /// One small capsule chip on a History row card: icon and text, never colour alone.
  func historyChip(tint: Color, fill: Color) -> some View {
    self
      .font(.stHelper)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(fill, in: Capsule())
      .foregroundStyle(tint)
  }
}

/// The Escape Recovery chip on a History dictation (#2087): the held row's countdown, or Kept
/// after the user kept it. Shared by the transcript row, the held dictation's detail and the
/// dictation card (#3147 PR2, Codex r8), so the rule and wording stay in one place.
struct EscapeRecoveryBadge: View {
  let escapeRecoveredAt: Date?
  let escapeRecoveryTakeID: String?

  init(transcript: Transcript) {
    escapeRecoveredAt = transcript.escapeRecoveredAt
    escapeRecoveryTakeID = transcript.escapeRecoveryTakeID
  }

  init(display: HistoryDictationDisplay) {
    escapeRecoveredAt = display.escapeRecoveredAt
    escapeRecoveryTakeID = display.escapeRecoveryTakeID
  }
  @Environment(TranscriptCoordinator.self) private var transcriptCoordinator

  /// Reading `expiryPulse` is what re-renders the countdown (#2087). Observation
  /// invalidates on a property READ by this body; `Date()` alone is invisible to
  /// it, so without this touch the badge would show the remaining time it had when
  /// something else last changed state.
  private var escapeRecoveryClock: Date {
    _ = transcriptCoordinator.expiryPulse
    return Date()
  }

  var body: some View {
    // #2087. Deliberately NOT the "Recovered" capsule below: that one means
    // crash rescue, and a held recovery is an ordinary cancel the user can
    // still change their mind about. The decision and the wording both come
    // from `EscapeRecoveryRowPresentation`, because a rule written inline
    // here would not be unit-drivable.
    switch EscapeRecoveryRowPresentation.badge(
      escapeRecoveredAt: escapeRecoveredAt, takeID: escapeRecoveryTakeID, now: escapeRecoveryClock)
    {
    case .held(let countdown):
      HStack(spacing: 2) {
        Image(systemName: "clock.arrow.circlepath")
        Text(countdown)
      }
      .historyChip(tint: .stWarning, fill: Color.stWarning.opacity(0.15))
      .accessibilityLabel(
        EscapeRecoveryRowPresentation.accessibilityLabel(
          remaining: EscapeRecoveryRowPresentation.remaining(
            from: escapeRecoveredAt ?? escapeRecoveryClock,
            now: escapeRecoveryClock)))
    case .kept:
      HStack(spacing: 2) {
        Image(systemName: "checkmark.seal")
        Text(EscapeRecoveryRowPresentation.keptLabel)
      }
      .historyChip(tint: .stSuccess, fill: Color.stSuccess.opacity(0.15))
      .accessibilityLabel("Kept recovered recording")
    case nil:
      EmptyView()
    }
  }
}

/// The item at the top of the History list as of its last scroll step, and the query it belongs
/// to. A plain class kept outside observation, so scrolling does not re-render the page.
private final class HistoryLiveAnchor {
  var id: HistoryItemID?
  var context: HistoryPaging.Context?
}
