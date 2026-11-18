import EnviousWisprCore
import SwiftUI

#if DEBUG
  import os
#endif

/// The row under History's tabs (#3147 §3.3): search, the date filter, the tab's own filter (App
/// on Dictations and on Meetings, none on Transcripts), Select and help, in that order on every
/// tab. Every change goes through the coordinator's per-tab state, so each tab keeps its own.
///
/// One look on every tab (founder, #4611): the search field fills the row; the filters and Select
/// share one shape and one gap; every filter button has the same width, set by the widest of the
/// filters' usual words, so Any time, Any app and Select sit in the same place on Dictations and
/// Meetings. Transcripts has no second filter, so its search field is one button longer (founder
/// chose that over an empty gap, 2026-11-17).
///
/// `leading`, the tab's main action (Record a meeting, Transcribe a File), starts the row: one row
/// with the search field when the window is wide; under the search field, at the left with the
/// filters at the right, when it is not (founder #4611, 2026-11-17).
struct HistoryFiltersView<Leading: View>: View {
  let coordinator: TranscriptCoordinator
  let tab: HistoryTab
  /// The tab's filters only: the row of controls never reads the query, so a keystroke leaves
  /// its input equal.
  let filter: HistoryListFilter
  let isSelecting: Bool
  let toggleSelecting: () -> Void

  @State private var openPicker: Picker?

  private enum Picker: String, Hashable { case app, callApp, date }

  let leading: Leading

  init(
    coordinator: TranscriptCoordinator, tab: HistoryTab, state: HistoryTabState,
    isSelecting: Bool, toggleSelecting: @escaping () -> Void,
    @ViewBuilder leading: () -> Leading
  ) {
    self.coordinator = coordinator
    self.tab = tab
    self.filter = state.listFilter
    self.isSelecting = isSelecting
    self.toggleSelecting = toggleSelecting
    self.leading = leading()
  }

  /// The search field on its own row, then the row of controls (#4586 WP-H). The search row's
  /// size never depends on the typed text, and the controls row is rebuilt only when its own
  /// inputs change, so a keystroke does not measure the controls.
  var body: some View {
    #if DEBUG
      let _ = HistoryFilterBarProbe.current?.pickerStates.append(openPicker?.rawValue)
    #endif
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      HistorySearchSlot(
        coordinator: coordinator, tab: tab,
        dismissPicker: { if openPicker != nil { openPicker = nil } }
      )
      .historyFilterBarMark("search")
      HistoryFilterControlsRow(
        key: .init(
          tab: tab, isSelecting: isSelecting, filter: filter, openPicker: openPicker?.rawValue)
      ) {
        HistoryFilterControlsShapes(
          leading: leading.historyFilterBarMark("leading"),
          date: dateButton.historyFilterBarMark("date"),
          tabFilter: tabFilter.historyFilterBarMark("tabFilter"),
          selection: selectionControls)
      }
      .equatable()
    }
    #if DEBUG
      .onAppear {
        HistoryFilterBarProbe.current?.openPicker = { name in
          openPicker = Picker(rawValue: name)
        }
      }
    #endif
  }

  @ViewBuilder private var tabFilter: some View {
    switch tab {
    case .dictations: appButton
    case .meetings: callAppButton
    case .transcripts: EmptyView()
    }
  }

  /// The words that set every filter button's width: each filter's unfiltered words and the date
  /// quick picks, in the current language. A longer chosen value is cut short with an ellipsis.
  private static var filterWidthTitles: [String] {
    [
      HistoryDateFilter.label(for: nil, now: Date(), calendar: .current),
      HistoryFilterLabels.app(.all), HistoryFilterLabels.callApp(nil),
    ] + HistoryDateFilter.quickPicks.map(\.title)
  }

  /// Invisible copies of a filter button with each of `titles`, so every filter button is exactly
  /// as wide as the widest of them.
  private static func filterWidthSizer(_ titles: [String]) -> some View {
    ZStack {
      ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
        HistoryFilterButtonLabel(title: title)
          .fixedSize()
          .modifier(EnviousButtonFace(emphasis: .outlined, shape: .roundedRect, size: .medium))
      }
    }
    .hidden()
    .accessibilityHidden(true)
  }

  @ViewBuilder private var selectionControls: some View {
    Button(action: toggleSelecting) {
      EnviousButtonLabel(
        isSelecting
          ? LocalizedStringResource(
            "Done", comment: "History: leaves selection mode (the Select button while selecting).")
          : LocalizedStringResource(
            "Select", comment: "History: enters selection mode to delete several items."),
        size: .medium, systemImage: "checkmark.circle")
    }
    // The filters' shape, so the row reads as one set of controls (founder, #4611).
    .settingsButton(
      isSelecting ? .filled : .outlined, shape: .roundedRect, size: .medium, isEnabled: true
    )
    .historyFilterBarMark("select")
    SettingsInfoButton(
      rowTitle: String(localized: "History", comment: "History: the page name."),
      tooltip: String(
        localized: "How History works", comment: "History: hover text of the help button.")
    ) {
      HistoryHelpPopover(tab: tab)
    }
    .historyFilterBarMark("help")
  }

  // MARK: - Tab filters

  private var appButton: some View {
    filterButton(
      label: HistoryFilterButtonLabel(title: HistoryFilterLabels.app(filter.app)),
      isActive: filter.app != .all, picker: .app, width: 260, maxHeight: 360
    ) {
      HistoryAppPicker(coordinator: coordinator, current: filter.app) { choice in
        update { $0.app = choice }
      }
    }
  }

  /// The Meetings tab's app filter: the same button and list as the other filters.
  private var callAppButton: some View {
    filterButton(
      label: HistoryFilterButtonLabel(title: HistoryFilterLabels.callApp(filter.callApp)),
      isActive: filter.callApp != nil, picker: .callApp, width: 220
    ) {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(HistoryFilterLabels.callAppChoices, id: \.self) { family in
          HistoryChoiceRow(
            title: HistoryFilterLabels.callApp(family), isCurrent: family == filter.callApp
          ) { update { $0.callApp = family } }
        }
      }
    }
  }

  private var dateButton: some View {
    filterButton(
      label: HistoryDateButtonLabel(interval: filter.dateInterval),
      isActive: filter.dateInterval != nil, picker: .date, width: 304
    ) {
      HistoryDatePicker(coordinator: coordinator, tab: tab, current: filter.dateInterval) {
        interval in
        update { $0.dateInterval = interval }
      }
      .padding(6)
    }
  }

  /// One filter control whose list needs more than the Mac menu can draw (counts, a calendar):
  /// the square drop-down button with the current choice, opening `settingsDropdown`. A set
  /// filter is drawn filled so a narrowed list is visible at a glance.
  private func filterButton<Label: View, Content: View>(
    label: Label, isActive: Bool, picker: Picker, width: CGFloat, maxHeight: CGFloat? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    // Every filter button has one width: the invisible sizer sets it, the real button fills it.
    Self.filterWidthSizer(Self.filterWidthTitles)
      .overlay {
        Button {
          openPicker = picker
        } label: {
          label
            .frame(maxWidth: .infinity)
        }
        .settingsButton(
          isActive ? .filled : .outlined, shape: .roundedRect, size: .medium, isEnabled: true
        )
        .settingsDropdown(
          isPresented: Binding(
            get: { openPicker == picker },
            set: { if $0 == false, openPicker == picker { openPicker = nil } }),
          width: width, maxHeight: maxHeight
        ) {
          content()
        }
      }
  }

  // MARK: - State

  /// Applies `change` to the tab's live state; a picker choice also closes its popover.
  private func update(_ change: (inout HistoryTabState) -> Void) {
    var live = coordinator.requestedHistoryState(for: tab)
    change(&live)
    coordinator.setHistoryState(live, for: tab)
    if openPicker != nil { openPicker = nil }
  }
}

// MARK: - Search row

/// The search field's look: magnifier, "Search history" field, the settings field chrome.
private struct HistorySearchFieldFrame: View {
  let text: Binding<String>
  let focused: FocusState<Bool>.Binding

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.stTextTertiary)
        .accessibilityHidden(true)
      // #2807: History holds dictations AND transcripts, so the box searches "history".
      TextField(
        String(localized: "Search history", comment: "History: the search box placeholder."),
        text: text
      )
      .textFieldStyle(.plain)
      .font(.stBody)
      .focused(focused)
    }
    .settingsFieldChrome(focused: focused)
  }
}

/// What the row measures for the search field: an invisible copy of the empty field (same
/// placeholder, icon, chrome and 180 pt floor) whose size never depends on the typed text, with
/// the live field drawn over it at whatever size the row offers.
struct HistorySearchSlot: View {
  let coordinator: TranscriptCoordinator
  let tab: HistoryTab
  let dismissPicker: () -> Void
  @FocusState private var sizerFocused: Bool

  var body: some View {
    HistorySearchFieldFrame(text: .constant(""), focused: $sizerFocused)
      .frame(minWidth: 180)
      .hidden()
      .accessibilityHidden(true)
      .frame(maxWidth: .infinity)
      .overlay {
        HistorySearchField(coordinator: coordinator, tab: tab, dismissPicker: dismissPicker)
      }
  }
}

/// The live field. It reads and writes the tab's query in the coordinator on every keystroke, as
/// the bar's field always did, and follows tab switches and external clears.
private struct HistorySearchField: View {
  let coordinator: TranscriptCoordinator
  let tab: HistoryTab
  let dismissPicker: () -> Void
  @FocusState private var focused: Bool

  var body: some View {
    HistorySearchFieldFrame(
      text: Binding(
        get: { coordinator.requestedHistoryState(for: tab).query },
        set: { value in
          var live = coordinator.requestedHistoryState(for: tab)
          live.query = value
          coordinator.setHistoryState(live, for: tab)
          dismissPicker()
        }),
      focused: $focused)
  }
}

// MARK: - Controls row

#if DEBUG
  /// What a test reads from the bar: how often the controls row built its body, the frames of the
  /// controls and of the arrangement the row chose, and the date button's titles. Set by a test;
  /// nil in the app.
  @MainActor final class HistoryFilterBarProbe {
    static var current: HistoryFilterBarProbe?
    var rowBodies = 0
    var frames: [String: CGRect] = [:]
    var dateTitles: [(interval: DateInterval?, title: String)] = []
    /// Opens a picker by its raw name, as a click on its button does. Set by the bar when it appears.
    var openPicker: ((String) -> Void)?
    /// The open picker (raw name, nil when closed) at each build of the bar.
    var pickerStates: [String?] = []
    /// What the controls layout did (read from its own thread-agnostic counters).
    let layout = HistoryFilterLayoutCounts()
  }

  /// Counters of `HistoryFilterControlsLayout`: child measurements, arrangements computed and the
  /// placement it made.
  final class HistoryFilterLayoutCounts: Sendable {
    struct State {
      var measurements = 0
      var arrangements = 0
      /// Every placement: the proposed width, the width of the bounds it was placed in, and
      /// whether it was the one-row shape. The window's size walk places at its own proposals
      /// (nil, infinity, 0) too.
      var placements: [(proposalWidth: CGFloat?, boundsWidth: CGFloat, oneRow: Bool)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var measurements: Int { state.withLock { $0.measurements } }
    var arrangements: Int { state.withLock { $0.arrangements } }
    var placements: [(proposalWidth: CGFloat?, boundsWidth: CGFloat, oneRow: Bool)] {
      state.withLock { $0.placements }
    }
    func measured() { state.withLock { $0.measurements += 1 } }
    func arranged() { state.withLock { $0.arrangements += 1 } }
    func placed(proposalWidth: CGFloat?, boundsWidth: CGFloat, oneRow: Bool) {
      state.withLock { $0.placements.append((proposalWidth, boundsWidth, oneRow)) }
    }
    func reset() { state.withLock { $0 = State() } }
  }

  private struct HistoryFilterBarMark: ViewModifier {
    let name: String
    func body(content: Content) -> some View {
      content.background {
        GeometryReader { proxy in
          let _ = HistoryFilterBarProbe.current?.frames[name] = proxy.frame(in: .global)
          Color.clear
        }
      }
    }
  }
#endif

extension View {
  /// Names a part of the filter bar so a debug test can read its frame; nothing in Release.
  func historyFilterBarMark(_ name: String) -> some View {
    #if DEBUG
      modifier(HistoryFilterBarMark(name: name))
    #else
      self
    #endif
  }
}

/// The row of controls, rebuilt only when `key` changes. The query is not in the key: a keystroke
/// builds the bar again, and SwiftUI skips this row, including building its controls (`content`
/// runs in `body`, after the equality check). `leading` observes its own state (the Meetings
/// button follows the meeting phase), so it still updates by itself.
struct HistoryFilterControlsRow<Content: View>: View, Equatable {
  struct Key: Equatable, Sendable {
    var tab: HistoryTab
    var isSelecting: Bool
    var filter: HistoryListFilter
    var openPicker: String?
  }

  let key: Key
  let content: @MainActor () -> Content

  init(key: Key, @ViewBuilder content: @escaping @MainActor () -> Content) {
    self.key = key
    self.content = content
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

  var body: some View {
    #if DEBUG
      let _ = HistoryFilterBarProbe.current?.rowBodies += 1
    #endif
    content()
  }
}

/// The date button's words. They come from the saved interval and today's date, so they are
/// recomputed when the day, the time zone or the locale changes: "Today" saved yesterday reads
/// "Yesterday" this morning, with the saved interval and the query untouched.
struct HistoryDateButtonLabel: View {
  let interval: DateInterval?
  var now: @MainActor () -> Date = { Date() }
  @State private var generation = 0

  var body: some View {
    let _ = generation
    let title = HistoryDateFilter.label(for: interval, now: now(), calendar: .current)
    #if DEBUG
      let _ = HistoryFilterBarProbe.current?.dateTitles.append((interval, title))
    #endif
    HistoryFilterButtonLabel(title: title)
      .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
        generation += 1
      }
      .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
        generation += 1
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
      ) { _ in
        generation += 1
      }
  }
}

/// Which control a child of `HistoryFilterControlsLayout` is.
private enum HistoryFilterControlRole: Hashable { case none, leading, date, tabFilter, selection }

private struct HistoryFilterControlRoleKey: LayoutValueKey {
  static let defaultValue = HistoryFilterControlRole.none
}

/// Today's two narrow-width shapes of the controls, without the search field: `leading` at the
/// left with the controls at the right when they fit one row; otherwise everything wrapped,
/// top-aligned (founder #4611, 2026-11-17). One layout decides, with a cache that holds every
/// proposal the window's size walk makes (`WrappingHStack` keeps one width, so each of those
/// proposals measured every child again).
struct HistoryFilterControlsShapes<
  Leading: View, DateControl: View, TabFilter: View, Selection: View
>: View {
  let leading: Leading
  let date: DateControl
  let tabFilter: TabFilter
  let selection: Selection

  var body: some View {
    #if DEBUG
      let layout = HistoryFilterControlsLayout(counts: HistoryFilterBarProbe.current?.layout)
    #else
      let layout = HistoryFilterControlsLayout()
    #endif
    layout {
      leading.fixedSize().layoutValue(key: HistoryFilterControlRoleKey.self, value: .leading)
      date.layoutValue(key: HistoryFilterControlRoleKey.self, value: .date)
      tabFilter.layoutValue(key: HistoryFilterControlRoleKey.self, value: .tabFilter)
      HStack(spacing: DesignSpacing.md) { selection }
        .fixedSize()
        .layoutValue(key: HistoryFilterControlRoleKey.self, value: .selection)
    }
  }
}

/// The controls row's arrangement. One row (when `leading`, a gap and the controls fit): `leading`
/// at the left, the controls at the right, all centered vertically. Otherwise the flow of
/// `WrappingHStack` at the offered width: top-aligned rows, a new row only when an item would end
/// past the width, an oversized first item stays. Results are cached per width (children are
/// always measured at an unspecified height, so height never changes an arrangement) and dropped
/// when the children change.
private struct HistoryFilterControlsLayout: Layout {
  #if DEBUG
    var counts: HistoryFilterLayoutCounts?
  #endif

  private static let gap = DesignSpacing.md
  private static let cacheLimit = 8

  struct Key: Hashable {
    var width: CGFloat?
  }

  struct Ideals {
    var leading: CGSize?
    var date: CGSize
    var tabFilter: CGSize?
    var selection: CGSize
  }

  struct Arrangement {
    var oneRow: Bool
    var size: CGSize
    /// Frames from the top-left, left to right.
    var frames: [(index: Int, frame: CGRect)]
  }

  struct Cache {
    var index: [HistoryFilterControlRole: Int] = [:]
    var count = 0
    var ideals: Ideals?
    var results: [Key: Arrangement] = [:]
  }

  func makeCache(subviews: Subviews) -> Cache {
    var cache = Cache()
    refresh(&cache, subviews)
    return cache
  }

  /// Called when the children change: everything cached described the old ones.
  func updateCache(_ cache: inout Cache, subviews: Subviews) {
    refresh(&cache, subviews)
  }

  private func refresh(_ cache: inout Cache, _ subviews: Subviews) {
    cache.index = [:]
    for (position, subview) in subviews.enumerated() {
      let role = subview[HistoryFilterControlRoleKey.self]
      if role != .none, cache.index[role] == nil { cache.index[role] = position }
    }
    cache.count = subviews.count
    cache.ideals = nil
    cache.results = [:]
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    arrangement(width: proposal.width, subviews: subviews, cache: &cache)?.size ?? .zero
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
  ) {
    guard let result = arrangement(width: bounds.width, subviews: subviews, cache: &cache)
    else { return }
    #if DEBUG
      counts?.placed(
        proposalWidth: proposal.width, boundsWidth: bounds.width, oneRow: result.oneRow)
    #endif
    // SwiftUI mirrors a custom layout's placement in a right-to-left layout by itself.
    for (index, frame) in result.frames {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: frame.width, height: frame.height))
    }
  }

  // MARK: Resolving

  private func measure(_ index: Int, _ proposal: ProposedViewSize, _ subviews: Subviews) -> CGSize {
    #if DEBUG
      counts?.measured()
    #endif
    return subviews[index].sizeThatFits(proposal)
  }

  private func arrangement(
    width offered: CGFloat?, subviews: Subviews, cache: inout Cache
  ) -> Arrangement? {
    // A cache from a different set of children must not place these: refuse it.
    if cache.count != subviews.count { refresh(&cache, subviews) }
    let width = offered.flatMap { $0.isFinite ? max($0, 0) : nil }
    let key = Key(width: width)
    if let known = cache.results[key] { return known }
    guard let date = cache.index[.date], let selection = cache.index[.selection] else { return nil }
    let ideals =
      cache.ideals
      ?? Ideals(
        leading: cache.index[.leading].map { measure($0, .unspecified, subviews) },
        date: measure(date, .unspecified, subviews),
        tabFilter: cache.index[.tabFilter].map { measure($0, .unspecified, subviews) },
        selection: measure(selection, .unspecified, subviews))
    cache.ideals = ideals
    #if DEBUG
      counts?.arranged()
    #endif
    let result = resolve(width: width, ideals: ideals, subviews: subviews, cache: cache)
    if cache.results.count >= Self.cacheLimit { cache.results = [:] }
    cache.results[key] = result
    return result
  }

  private func resolve(
    width: CGFloat?, ideals: Ideals, subviews: Subviews, cache: Cache
  ) -> Arrangement {
    let gap = Self.gap
    var controls: [(index: Int, size: CGSize)] = [(cache.index[.date]!, ideals.date)]
    if let tab = ideals.tabFilter, let index = cache.index[.tabFilter] {
      controls.append((index, tab))
    }
    controls.append((cache.index[.selection]!, ideals.selection))
    let controlsWidth =
      controls.reduce(0) { $0 + $1.size.width } + gap * CGFloat(controls.count - 1)
    let controlsHeight = controls.map(\.size.height).max() ?? 0
    let leading = ideals.leading
    let rowHeight = max(leading?.height ?? 0, controlsHeight)
    // `leading`, the stack's gap, the spacer (no width), the stack's gap, the controls.
    let oneRowWidth = (leading.map { $0.width + gap } ?? 0) + gap + controlsWidth

    if width == nil || oneRowWidth <= width! {
      let total = width ?? oneRowWidth
      var frames: [(Int, CGRect)] = []
      if let leading, let index = cache.index[.leading] {
        frames.append(
          (
            index,
            CGRect(
              x: 0, y: (rowHeight - leading.height) / 2, width: leading.width,
              height: leading.height)
          ))
      }
      var x = total - controlsWidth
      for (index, size) in controls {
        frames.append(
          (
            index,
            CGRect(x: x, y: (rowHeight - size.height) / 2, width: size.width, height: size.height)
          ))
        x += size.width + gap
      }
      return Arrangement(
        oneRow: true, size: CGSize(width: total, height: rowHeight), frames: frames)
    }

    // Wrapped: `WrappingHStack`'s flow at this width, each item asked at the full width.
    let total = width!
    let proposal = ProposedViewSize(width: total, height: nil)
    var items: [(Int, CGSize)] = []
    if let index = cache.index[.leading] {
      items.append((index, measure(index, proposal, subviews)))
    }
    for (index, _) in controls { items.append((index, measure(index, proposal, subviews))) }
    var frames: [(Int, CGRect)] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowMax: CGFloat = 0
    var extent: CGFloat = 0
    for (index, size) in items {
      if x + size.width > total, x > 0 {
        x = 0
        y += rowMax + gap
        rowMax = 0
      }
      frames.append((index, CGRect(x: x, y: y, width: size.width, height: size.height)))
      rowMax = max(rowMax, size.height)
      x += size.width + gap
      extent = max(extent, x - gap)
    }
    return Arrangement(
      oneRow: false, size: CGSize(width: extent, height: y + rowMax), frames: frames)
  }
}

/// A filter button's words: the current value at the leading edge, cut short with an ellipsis
/// when it is longer than the button, and the up-down chevron at the trailing edge. The same font
/// and sizes as `EnviousButtonLabel` at the medium size.
private struct HistoryFilterButtonLabel: View {
  let title: String

  var body: some View {
    let size = EnviousButtonFace.Size.medium
    HStack(spacing: 5) {
      Text(verbatim: title)
        .font(.system(size: size.fontSize, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      Image(systemName: "chevron.up.chevron.down")
        .font(.system(size: size.fontSize - 1, weight: .semibold))
        .accessibilityHidden(true)
    }
  }
}

/// One plain choice of a filter's list (date, Meetings app), drawn as the approved drop-down row.
private struct HistoryChoiceRow: View {
  let title: String
  let isCurrent: Bool
  let action: () -> Void

  var body: some View {
    SettingsDropdownRow(
      isChosen: isCurrent, spokenTitle: title, action: action,
      leading: { EmptyView() }, title: title, subtitle: { EmptyView() })
  }
}

/// The App picker of the Dictations tab: every app dictations went to, with counts, and
/// Unknown app for dictations with no recorded app. Counted off the main actor when it opens.
private struct HistoryAppPicker: View {
  let coordinator: TranscriptCoordinator
  let current: HistoryAppFilter
  let choose: (HistoryAppFilter) -> Void

  @State private var options: [HistoryFilterLabels.AppOption]?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let options {
        ForEach(options) { option in
          let title = HistoryFilterLabels.app(option.filter)
          SettingsDropdownRow(
            isChosen: option.filter == current,
            spokenTitle: "\(title), \(option.count.formatted())",
            action: { choose(option.filter) },
            leading: { EmptyView() }, title: title, subtitle: { EmptyView() },
            trailing: {
              Text(verbatim: option.count.formatted())
                .font(.stHelper.monospacedDigit())
                .foregroundStyle(.stTextSecondary)
                .accessibilityHidden(true)
            })
        }
      } else {
        ProgressView().controlSize(.small)
          .frame(maxWidth: .infinity)
          .padding(.vertical, DesignSpacing.md)
      }
    }
    .task(id: coordinator.catalogSession?.revision ?? UInt64(coordinator.transcriptsRevision)) {
      let result = await coordinator.historyAppOptions()
      if !Task.isCancelled { options = result }
    }
  }
}

/// The words on History's filter controls, and the choices they offer, as plain values.
enum HistoryFilterLabels {
  /// One App picker row: its filter and how many dictations it covers.
  struct AppOption: Identifiable, Equatable, Sendable {
    let filter: HistoryAppFilter
    let count: Int
    var id: HistoryAppFilter { filter }
  }

  /// Any app first (every dictation), then each recorded app by count (ties by name), then
  /// Unknown app when any dictation has no recorded app. `grouped` is the catalog's per-app counts.
  nonisolated static func appOptions(counts grouped: [(String?, Int)]) -> [AppOption] {
    var counts: [String: Int] = [:]
    var unknown = 0
    for (app, count) in grouped {
      if let app, app.isEmpty == false {
        counts[app, default: 0] += count
      } else {
        unknown += count
      }
    }
    let named = counts.sorted { lhs, rhs in
      lhs.value != rhs.value
        ? lhs.value > rhs.value
        : lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
    }
    var options = [AppOption(filter: .all, count: grouped.reduce(0) { $0 + $1.1 })]
    options += named.map { AppOption(filter: .named($0.key), count: $0.value) }
    if unknown > 0 { options.append(AppOption(filter: .unknown, count: unknown)) }
    return options
  }

  @MainActor static func app(_ filter: HistoryAppFilter) -> String {
    switch filter {
    case .all:
      String(localized: "Any app", comment: "History, Dictations: the App filter shows every app.")
    case .unknown:
      String(
        localized: "Unknown app",
        comment: "History, Dictations: dictations with no recorded app they went to.")
    case .named(let identifier):
      HistoryAppName.label(for: identifier)
    }
  }

  /// Any app, then every call app by name.
  static var callAppChoices: [CallAppFamily?] {
    [nil]
      + CallAppFamily.allCases.sorted {
        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
  }

  static func callApp(_ family: CallAppFamily?) -> String {
    guard let family else {
      return String(
        localized: "Any app",
        comment: "History, Meetings: the app filter shows meetings from every call app.")
    }
    return family.displayName
  }
}

/// History's date filter as plain values (#3147 §3.3). Every interval starts at a day's start and
/// ends at the start of the day after its last day, so it holds whole days and never the next
/// day's first moment.
enum HistoryDateFilter: Equatable, Sendable {
  case today, yesterday, last7Days, last30Days
  case day(Date)

  /// The quick picks, in menu order.
  static let quickPicks: [HistoryDateFilter] = [.today, .yesterday, .last7Days, .last30Days]

  /// The interval this choice means at `now`.
  func interval(now: Date, calendar: Calendar) -> DateInterval {
    let today = calendar.startOfDay(for: now)
    switch self {
    case .today: return Self.days(from: today, count: 1, calendar: calendar)
    case .yesterday:
      return Self.days(from: Self.day(today, plus: -1, calendar), count: 1, calendar: calendar)
    case .last7Days:
      return Self.days(from: Self.day(today, plus: -6, calendar), count: 7, calendar: calendar)
    case .last30Days:
      return Self.days(from: Self.day(today, plus: -29, calendar), count: 30, calendar: calendar)
    case .day(let date):
      return Self.days(from: calendar.startOfDay(for: date), count: 1, calendar: calendar)
    }
  }

  static func interval(from first: Date, through last: Date, calendar: Calendar) -> DateInterval {
    let start = calendar.startOfDay(for: min(first, last))
    let lastDay = calendar.startOfDay(for: max(first, last))
    return DateInterval(start: start, end: day(lastDay, plus: 1, calendar))
  }

  /// The name of a quick pick.
  var title: String {
    switch self {
    case .today: String(localized: "Today", comment: "History: the day heading for today's items.")
    case .yesterday:
      String(localized: "Yesterday", comment: "History: the day heading for yesterday's items.")
    case .last7Days:
      String(
        localized: "Last 7 days", comment: "History date filter: items from the last seven days.")
    case .last30Days:
      String(
        localized: "Last 30 days", comment: "History date filter: items from the last 30 days.")
    case .day(let date):
      date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
  }

  /// The words on the date button for `interval`: Any time, a quick pick it still equals, one
  /// day, or "Nov 3 to Nov 9".
  static func label(for interval: DateInterval?, now: Date, calendar: Calendar) -> String {
    guard let interval else {
      return String(localized: "Any time", comment: "History date filter: no date limit.")
    }
    if let pick = quickPicks.first(where: { $0.interval(now: now, calendar: calendar) == interval })
    {
      return pick.title
    }
    let lastDay = calendar.date(byAdding: .second, value: -1, to: interval.end) ?? interval.end
    if calendar.isDate(interval.start, inSameDayAs: lastDay) {
      return HistoryDateFilter.day(interval.start).title
    }
    let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
    return String(
      localized: "\(interval.start.formatted(style)) to \(lastDay.formatted(style))",
      comment:
        "History date filter: a range of days. The first %@ is the first day, the second the last.")
  }

  /// The month grid for the month holding `month`: leading blanks up to the first weekday, then
  /// each day's start.
  static func monthGrid(for month: Date, calendar: Calendar) -> [Date?] {
    guard let interval = calendar.dateInterval(of: .month, for: month),
      let count = calendar.range(of: .day, in: .month, for: month)?.count
    else { return [] }
    let weekday = calendar.component(.weekday, from: interval.start)
    let blanks = (weekday - calendar.firstWeekday + 7) % 7
    let days = (0..<count).map { day(interval.start, plus: $0, calendar) }
    return Array(repeating: nil, count: blanks) + days.map { Optional($0) }
  }

  private static func day(_ start: Date, plus days: Int, _ calendar: Calendar) -> Date {
    calendar.date(byAdding: .day, value: days, to: start) ?? start
  }

  private static func days(from start: Date, count: Int, calendar: Calendar) -> DateInterval {
    DateInterval(start: start, end: day(start, plus: count, calendar))
  }
}

/// The date picker: Any time and the quick picks, then a month calendar whose days carry a dot
/// when the tab has items on them under its other filters.
private struct HistoryDatePicker: View {
  let coordinator: TranscriptCoordinator
  let tab: HistoryTab
  let current: DateInterval?
  let choose: (DateInterval?) -> Void

  @State private var month = Date()
  @State private var activity: [Date: Int] = [:]
  @State private var firstDay: Date?
  @State private var hoveredDay: Date?
  @State private var lastDay: Date?
  private let calendar = Calendar.current

  var body: some View {
    let now = Date()
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        HistoryChoiceRow(
          title: HistoryDateFilter.label(for: nil, now: now, calendar: calendar),
          isCurrent: current == nil
        ) { choose(nil) }
        ForEach(HistoryDateFilter.quickPicks, id: \.title) { pick in
          let interval = pick.interval(now: now, calendar: calendar)
          HistoryChoiceRow(title: pick.title, isCurrent: current == interval) {
            choose(interval)
          }
        }
      }
      Divider()
      Text(
        "Choose one day, or a start and end date, then Apply.",
        comment: "History date filter: one line above the calendar explaining how to pick days."
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
      .fixedSize(horizontal: false, vertical: true)
      monthHeader
      calendarGrid(now: now)
      HStack {
        if let firstDay {
          Text(
            HistoryDateFilter.label(
              for: HistoryDateFilter.interval(
                from: firstDay, through: lastDay ?? firstDay, calendar: calendar),
              now: now, calendar: calendar)
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        }
        Spacer()
        Button {
          guard let firstDay else { return }
          choose(
            HistoryDateFilter.interval(
              from: firstDay, through: lastDay ?? firstDay, calendar: calendar))
        } label: {
          EnviousButtonLabel("Apply", size: .regular)
        }
        .settingsButton(.filled, isEnabled: firstDay != nil)
      }
    }
    .frame(width: 280)
    .task(id: activityKey) {
      let result = await coordinator.historyActivity(in: tab, calendar: calendar)
      if !Task.isCancelled { activity = result }
    }
    .onAppear { if let current { month = current.start } }
  }

  private var activityKey: TranscriptCoordinator.HistoryQueryKey {
    var state = coordinator.requestedHistoryState(for: tab)
    state.dateInterval = nil
    return coordinator.historyQueryKey(for: tab, state: state)
  }

  private var monthHeader: some View {
    HStack {
      Button {
        shiftMonth(-1)
      } label: {
        Image(systemName: "chevron.left")
      }
      .settingsButton(.quiet, size: .medium, isEnabled: true)
      .accessibilityLabel(
        String(localized: "Previous month", comment: "History date picker: shows the month before.")
      )
      Spacer()
      Text(month.formatted(.dateTime.month(.wide).year()))
        .font(.stRowLabel)
        .foregroundStyle(.stTextPrimary)
      Spacer()
      Button {
        shiftMonth(1)
      } label: {
        Image(systemName: "chevron.right")
      }
      .settingsButton(
        .quiet, size: .medium,
        isEnabled: calendar.isDate(month, equalTo: Date(), toGranularity: .month) == false
      )
      .accessibilityLabel(
        String(localized: "Next month", comment: "History date picker: shows the month after."))
    }
  }

  private func calendarGrid(now: Date) -> some View {
    let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    let cells = HistoryDateFilter.monthGrid(for: month, calendar: calendar)
    return LazyVGrid(columns: columns, spacing: 4) {
      ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
        if let day {
          dayCell(day, now: now)
        } else {
          Color.clear.frame(height: 30)
        }
      }
    }
  }

  private func dayCell(_ day: Date, now: Date) -> some View {
    let count = activity[day] ?? 0
    let draft = firstDay.map {
      HistoryDateFilter.interval(from: $0, through: lastDay ?? hoveredDay ?? $0, calendar: calendar)
    }
    let range = draft ?? current
    let inRange = range.map { day >= $0.start && day < $0.end } ?? false
    let isEndpoint =
      range.map {
        day == $0.start || calendar.isDate(day, inSameDayAs: $0.end.addingTimeInterval(-1))
      } ?? false
    let isFuture = day > now
    return Button {
      if firstDay == nil || lastDay != nil {
        firstDay = day
        lastDay = nil
      } else {
        lastDay = day
      }
    } label: {
      VStack(spacing: 2) {
        Text(day.formatted(.dateTime.day()))
          .font(.stBody.monospacedDigit())
          .foregroundStyle(isEndpoint ? Color.white : (isFuture ? .stTextTertiary : .stTextPrimary))
        Circle()
          .fill(isEndpoint ? Color.white : Color.stAccent)
          .frame(width: 4, height: 4)
          .opacity(count > 0 ? 1 : 0)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, minHeight: 30)
      .background {
        if isEndpoint {
          RoundedRectangle(cornerRadius: DesignRadius.md).fill(Color.stAccentSolid)
        } else if inRange || hoveredDay == day {
          RoundedRectangle(cornerRadius: DesignRadius.md).fill(Color.stAccent.opacity(0.22))
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isFuture)
    .onHover { hovering in
      if hovering && !isFuture { hoveredDay = day } else if hoveredDay == day { hoveredDay = nil }
    }
    .accessibilityLabel(HistoryDateFilter.day(day).title)
    .accessibilityValue(
      count > 0
        ? String(localized: "Has items", comment: "History date picker: this day has items.")
        : String(localized: "No items", comment: "History date picker: this day has no items.")
    )
    .accessibilityAddTraits(inRange ? .isSelected : [])
  }

  private func shiftMonth(_ months: Int) {
    hoveredDay = nil
    month = calendar.date(byAdding: .month, value: months, to: month) ?? month
  }
}
