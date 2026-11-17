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
  private let transcriptDestination:
    (UUID, @escaping () -> Void, HistoryNeighbors) -> TranscriptDestination
  private let meetingDestination:
    (UUID, @escaping () -> Void, HistoryNeighbors) -> MeetingDestination

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
    @ViewBuilder transcriptDestination: @escaping (UUID, @escaping () -> Void, HistoryNeighbors) ->
      TranscriptDestination,
    @ViewBuilder meetingDestination: @escaping (UUID, @escaping () -> Void, HistoryNeighbors) ->
      MeetingDestination
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
          .task(id: NeighborKey(open: openID, loaded: result?.items.count ?? 0)) {
            loadPastEnd(of: openID)
          }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          SettingsTabStrip(items: HistoryDiaryLayout.tabItems, selection: tabBinding)
          HistoryFiltersView(
            coordinator: coordinator, tab: tab, state: state, isSelecting: isSelecting,
            toggleSelecting: toggleSelecting
          ) {
            if isSelecting == false { HistoryTabAction(coordinator: coordinator, tab: tab) }
          }
          if isSelecting {
            HistorySelectionToolbar(
              coordinator: coordinator, tab: tab, selection: selection,
              result: canSelect ? result : nil)
          }
          if tab == .meetings, isSelecting == false {
            HistoryMeetingsBar()
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
              Button {
                coordinator.loadIfNeeded()
              } label: {
                EnviousButtonLabel(HistoryEmptyMessage.tryAgain, size: .medium)
              }
              .settingsButton(.quiet, size: .medium, isEnabled: true)
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
    .task(id: RefreshKey(request: key.request, grouping: groupingRevision)) {
      await refresh(tab: tab)
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
    let request: TranscriptCoordinator.HistoryQueryKey.Request
    let grouping: Int
  }

  /// #4586 H1: keeps `tab`'s list current for one request (`HistoryRefreshLoop`).
  private func refresh(tab: HistoryTab) async {
    guard let session = coordinator.catalogSession else {
      await readPage(tab: tab, key: currentKey(tab))
      return
    }
    await HistoryRefreshLoop(
      counters: {
        .init(content: session.revision, notices: session.noticeCount, source: session.stableSourceRevision)
      },
      currentKey: { currentKey(tab) },
      storedKey: { results[tab]?.key },
      read: { key in await readPage(tab: tab, key: key) },
      wait: { content, notices in await session.waitForChange(revision: content, notices: notices) }
    ).run()
  }

  private func currentKey(_ tab: HistoryTab) -> TranscriptCoordinator.HistoryQueryKey {
    coordinator.historyQueryKey(for: tab, state: coordinator.requestedHistoryState(for: tab))
  }

  /// One read for `key`, then publish (the body that ran once per key before #4586).
  private func readPage(tab: HistoryTab, key: TranscriptCoordinator.HistoryQueryKey) async {
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
    // With a page open, restore around the item on screen: after the arrows stepped past the
    // loaded page, a restore around the item first opened lost the open one, and both arrows
    // stayed disabled (founder, #4611). Back returns to the open item anyway.
    if let open = live.openItemID, key.context == HistoryPaging.Context(tab: tab, state: live),
      live.scrollAnchorID != open
    {
      live.scrollAnchorID = open
      coordinator.setHistoryState(live, for: tab)
    }
    guard let result = await coordinator.historyResults(for: key), !Task.isCancelled,
      coordinator.historyTab == tab
    else { return }
    #if DEBUG
      // #4611 listening code: how long after its save a new item reached the list.
      if let newest = result.items.first, newest.id != results[tab]?.items.first?.id {
        let age = Date().timeIntervalSince(newest.createdAt)
        if age < 120 {
          let line =
            "new item shown tab=\(tab.rawValue) secondsAfterSave=\(String(format: "%.2f", age))"
          Task { await AppLogger.shared.log(line, level: .info, category: "HistoryScroll") }
        }
      }
    #endif
    results[tab] = result
    HistoryFirstPage.accepted(tab)
    if isSelecting, coordinator.historyTab == tab {
      if let matching = await coordinator.matchingIDs(for: result), isSelecting {
        selection.retain(Set(matching))
      }
    }
  }

  private var tabBinding: Binding<HistoryTab> {
    Binding(
      get: { coordinator.historyTab },
      set: { coordinator.selectHistoryTab($0) })
  }

  @ViewBuilder private func destination(for id: HistoryItemID) -> some View {
    let neighbors = neighbors(of: id)
    switch id {
    case .transcript(let rowID): transcriptDestination(rowID, closeOpenItem, neighbors)
    case .meeting(let meetingID): meetingDestination(meetingID, closeOpenItem, neighbors)
    }
  }

  private struct NeighborKey: Equatable {
    let open: HistoryItemID
    let loaded: Int
  }

  /// The open item's list as the reader left it (same tab, search, filters and order, newest
  /// first), keeping only the items the list draws.
  private func openList() -> [HistoryListItem]? {
    let tab = coordinator.historyTab
    let state = coordinator.requestedHistoryState(for: tab)
    // The same list while a refresh reads (only its revision differs) still steps, so the
    // arrows do not blink off on every background update.
    guard let result = results[tab],
      result.key.context == coordinator.historyQueryKey(for: tab, state: state).context
    else { return nil }
    return result.items.filter { coordinator.canRenderHistoryItem($0) }
  }

  /// #4611 (founder: "like an email inbox"): the items above and below the open one.
  private func neighbors(of id: HistoryItemID) -> HistoryNeighbors {
    guard let items = openList(), let index = items.firstIndex(where: { $0.id == id }) else {
      return HistoryNeighbors(inList: true)
    }
    let previous = index > 0 ? items[index - 1].id : nil
    let next = index + 1 < items.count ? items[index + 1].id : nil
    return HistoryNeighbors(
      inList: true,
      previous: previous.map { target in { step(to: target) } },
      next: next.map { target in { step(to: target) } })
  }

  /// Opens a neighbour in place. The page is rebuilt for it (its own `.id`), so the item left
  /// stops playing and the new one starts at the top. The list's saved place is left alone: it
  /// anchors the loaded page, and moving it reloaded the list from the new item, which lost
  /// Previous. Back still returns to the new item (`closeOpenItem`).
  private func step(to id: HistoryItemID) {
    var state = coordinator.requestedHistoryState(for: coordinator.historyTab)
    guard state.openItemID != nil else { return }
    state.openItemID = id
    coordinator.setHistoryState(state, for: coordinator.historyTab)
  }

  /// At the last (or first) loaded item, reads the next page so Next (or Previous) has a
  /// neighbour when the list holds more.
  private func loadPastEnd(of id: HistoryItemID) {
    let tab = coordinator.historyTab
    guard let result = results[tab], let items = openList(),
      let index = items.firstIndex(where: { $0.id == id })
    else { return }
    if index == items.count - 1, result.continuation != nil {
      loadNext(result, newer: false)
    } else if index == 0, result.newerContinuation != nil {
      loadNext(result, newer: true)
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
    // #4586: only from the stored result; the coordinator also requires the live key.
    guard let cursor, pendingPage == nil, current == cursor, results[tab]?.identity == result.identity,
      result.catalogSourceRevision == coordinator.catalogSession?.stableSourceRevision
    else { return }
    pendingPage = cursor
    Task {
      defer { if pendingPage == cursor { pendingPage = nil } }
      guard
        let next = await coordinator.historyResults(
          for: result.key, extending: result, newer: newer),
        coordinator.historyTab == tab, results[tab]?.identity == result.identity
      else { return }
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

  /// #4611: the place to put at the top once its rows are installed. The first page for the
  /// tab's current search restores its saved place; a later search or filter starts at the top
  /// (#4586, `HistoryListPlace`).
  @State private var place = PlaceBox()
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
    // Decided here, in the same update that hands the table its rows, so a new search's rows
    // never land at the old place first (#4586). `place` is unobserved: this changes no state.
    let restore = place.value.restore(
      shownContext: result?.key.context, requested: HistoryPaging.Context(tab: tab, state: state),
      saved: state.scrollAnchorID
    ).map { HistoryDiaryTable.Restore(token: $0.token, target: $0.target.map { .item($0) }) }
    if !rows.isEmpty, isCurrent { HistoryFirstPage.installing(tab) }

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
    // Each tab keeps its place (#3147 §3.3): restored when its list appears (`place`), saved when
    // it leaves for another tab or an open item. A new search or filter starts at the top.
    .onDisappear {
      saveLiveAnchor()
      liveAnchor.context = nil
    }
    .background(Color.stPageBg)
    // #4001 step 2a: the recording state is read inside the modifier, not by this body.
    .recordingDimmed()
    .overlay {
      if items.isEmpty && coordinator.catalogSession?.status == .unavailable {
        HistoryEmptyMessage(
          systemImage: "exclamationmark.triangle", title: HistoryEmptyMessage.loadFailed)
      } else if items.isEmpty && coordinator.catalogSession?.status == .updating {
        ProgressView()
      } else if coordinator.catalogSession == nil,
        items.isEmpty && coordinator.historyReadAvailability == .unavailable
      {
        HistoryEmptyMessage(
          systemImage: "exclamationmark.triangle", title: HistoryEmptyMessage.loadFailed,
          retry: { coordinator.loadIfNeeded() })
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
      meetingID: meetingID, onOpen: { open(item) }, query: query, summary: summary)
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

  @State private var previewExpanded = false

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
        // A row the index saved before #4609 has only its preview: the same text and card
        // frame as a full dictation card, without the buttons it has no data for.
        HistoryClampedText(text: summary.preview, query: query, expanded: $previewExpanded)
          .historyDiaryCard()
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
        if hasExactTotal, let summary = HistoryDiaryLayout.daySummary(tab: tab, count: day.total) {
          Text(summary)
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
    // A plain link, no outline (founder, #4611 page header): the page's own buttons sit on the
    // right, and the way back reads as navigation, not as one more action.
    Button(action: close) {
      HStack(spacing: DesignSpacing.xxs) {
        Image(systemName: "chevron.left")
          .fontWeight(.semibold)
          .accessibilityHidden(true)
        Text(verbatim: HistoryDiaryLayout.tabTitle(tab))
      }
      .font(.stRowLabel)
      .foregroundStyle(.stTextSecondary)
      .settingsHoverQuiet(tint: .stAccent)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      String(
        localized: "Back to \(HistoryDiaryLayout.tabTitle(tab))",
        comment: "History: returns from an open item to its tab's list. %@ is the tab's name."))
  }
}

/// The Meetings tab's own notices under the filter row: the call sound explainer when it is due
/// for a Start from History (it stands in for the Record button), and the count of meetings a
/// newer version saved. Nil-sized when neither applies.
private struct HistoryMeetingsBar: View {
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(MeetingStartFlow.self) private var startFlow

  var body: some View {
    let newerLine = HistoryDiaryLayout.newerFormatLine(meetings.newerFormatMeetings.count)
    if startFlow.pendingExplainer == .history || newerLine != nil {
      VStack(alignment: .leading, spacing: 8) {
        if startFlow.pendingExplainer == .history { MeetingCallSoundExplainer() }
        // Meetings a newer EnviousWispr saved stay on disk, untouched; this build cannot open
        // them, so they are counted here rather than listed (#3972 §4).
        if let newerLine {
          Text(newerLine)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// The tab's main action at the start of the filter row (founder #4611): Record a meeting on
/// Meetings, Transcribe a File on Transcripts, nothing on Dictations. Hidden while selecting.
struct HistoryTabAction: View {
  let coordinator: TranscriptCoordinator
  let tab: HistoryTab

  var body: some View {
    switch tab {
    case .dictations: EmptyView()
    case .transcripts: HistoryTranscribeFileButton()
    case .meetings: HistoryMeetingRecordButton(coordinator: coordinator)
    }
  }
}

/// Opens the Transcribe a File page, with the sidebar's name and glyph for it.
private struct HistoryTranscribeFileButton: View {
  @Environment(NavigationCoordinator.self) private var navigation

  var body: some View {
    Button {
      navigation.request(.transcribeFile)
    } label: {
      // The sidebar's own name for the page, one owner (`SettingsPage.labelResource`).
      EnviousButtonLabel(
        SettingsPage.transcribeFile.labelResource ?? "Transcribe a File",
        size: .medium, systemImage: SettingsPage.transcribeFile.icon)
    }
    .settingsButton(.filled, size: .medium, isEnabled: true)
  }
}

/// Start Recording when nothing records; while a meeting records, a way to it. Stop lives in
/// that meeting and the menu. While the call sound explainer is due it shows below the filter
/// row instead (`HistoryMeetingsBar`), so this draws nothing.
private struct HistoryMeetingRecordButton: View {
  let coordinator: TranscriptCoordinator
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(MeetingStartFlow.self) private var startFlow

  var body: some View {
    if startFlow.pendingExplainer != .history {
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

  /// "9 dictations", one whole sentence per count and tab (#3142). Nil for a day with one item:
  /// the single card already says it (founder #4611).
  static func daySummary(tab: HistoryTab, count: Int) -> String? {
    guard count > 1 else { return nil }
    switch tab {
    case .dictations:
      return String(
        localized: "\(String(count)) dictations",
        comment: "History day heading: how many dictations that day. Never 1.")
    case .transcripts:
      return String(
        localized: "\(String(count)) transcripts",
        comment: "History day heading: how many transcripts that day. Never 1.")
    case .meetings:
      return String(
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
      HistoryEmptyMessage(
        systemImage: "doc.text",
        title: LocalizedStringResource(
          "Nothing here yet", comment: "History: empty list title when nothing was ever saved."),
        message: LocalizedStringResource(
          "Your dictations, transcripts and recordings will appear here.",
          comment: "History: empty list explanation when nothing was ever saved."))
    case .noDictations:
      HistoryEmptyMessage(
        systemImage: "mic",
        title: LocalizedStringResource(
          "No dictations yet", comment: "History, Dictations: empty tab title."),
        message: LocalizedStringResource(
          "Press your keybind and start talking.",
          comment: "History, Dictations: empty tab explanation."))
    case .noTranscripts:
      HistoryEmptyMessage(
        systemImage: "doc.text",
        title: LocalizedStringResource(
          "No transcripts yet", comment: "History, Transcripts: empty tab title."),
        message: LocalizedStringResource(
          "Use Transcribe a File to add one.",
          comment: "History, Transcripts: empty tab explanation."))
    case .noRecordings:
      HistoryEmptyMessage(
        systemImage: "person.2.wave.2",
        title: LocalizedStringResource(
          "No recordings yet", comment: "History, Meetings: empty tab title."),
        message: LocalizedStringResource(
          "Click \(String(localized: MeetingsCopy.startRecording)) above to start one.",
          comment:
            "History, Meetings: empty tab explanation. %@ is the name of the record button above the list."
        ))
    case .noMatches:
      HistoryEmptyMessage(
        systemImage: "magnifyingglass",
        title: LocalizedStringResource(
          "No matching history.", comment: "History: title when a search or filter finds nothing."),
        message: LocalizedStringResource(
          "Try a different search, or another filter.",
          comment: "History: explanation when a search or filter finds nothing."))
    }
  }
}

/// History's own empty or failed list message (#4611): a quiet glyph, a title, one line of help
/// and an optional button, in the page's fonts and colors rather than the system's
/// `ContentUnavailableView`.
struct HistoryEmptyMessage: View {
  let systemImage: String
  let title: LocalizedStringResource
  var message: LocalizedStringResource?
  var retry: (() -> Void)?

  var body: some View {
    VStack(spacing: DesignSpacing.md) {
      Image(systemName: systemImage)
        .font(.stDayTitle)
        .foregroundStyle(.stTextTertiary)
        .padding(.bottom, DesignSpacing.xs)
        .accessibilityHidden(true)
      Text(title)
        .font(.stRowTitle)
        .foregroundStyle(.stTextPrimary)
      if let message {
        Text(message)
          .font(.stBody)
          .foregroundStyle(.stTextSecondary)
      }
      if let retry {
        Button(action: retry) {
          EnviousButtonLabel(HistoryEmptyMessage.tryAgain, size: .medium)
        }
        .settingsButton(.outlined, size: .medium, isEnabled: true)
        .padding(.top, DesignSpacing.xs)
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: 360)
    .padding(DesignSpacing.xxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
  }

  static let tryAgain = LocalizedStringResource(
    "Try again", comment: "History: reloads History after it could not be read.")

  static let loadFailed = LocalizedStringResource(
    "Couldn't load History", comment: "History: the list could not be read.")
}

extension View {
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
/// after the user kept it. Shared by the transcript card and the dictation card (#3147 PR2, Codex r8), so the rule and wording stay in one place.
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

/// #4586 signposts for the first page of each tab since launch: accepted when stored, drawn on
/// the next main run-loop turn, after `HistoryDiaryTable` installed its rows. "Drawn" brackets
/// the table insert; it is not a frame timestamp.
@MainActor
private enum HistoryFirstPage {
  static var accepted: Set<HistoryTab> = []
  static var drawn: Set<HistoryTab> = []

  static func accepted(_ tab: HistoryTab) {
    guard accepted.insert(tab).inserted else { return }
    HistorySignpost.event("HistoryFirstPageAccepted")
  }

  /// Called by the list body that hands the table a current, non-empty page; the table installs
  /// those rows in the same update, so the next main run-loop turn is after the install.
  static func installing(_ tab: HistoryTab) {
    guard accepted.contains(tab), drawn.insert(tab).inserted else { return }
    DispatchQueue.main.async { HistorySignpost.event("HistoryFirstPageDrawn") }
  }
}

/// The list's place decision, kept outside observation so deciding it never redraws the list.
@MainActor
private final class PlaceBox {
  var value = HistoryListPlace()
}
