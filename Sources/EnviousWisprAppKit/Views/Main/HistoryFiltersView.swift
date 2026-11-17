import EnviousWisprCore
import SwiftUI

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
  let state: HistoryTabState
  let isSelecting: Bool
  let toggleSelecting: () -> Void

  @FocusState private var searchFocused: Bool
  @State private var openPicker: Picker?

  private enum Picker: Hashable { case app, callApp, date }

  @ViewBuilder let leading: Leading

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: DesignSpacing.md) {
        leading.fixedSize()
        searchField.frame(maxWidth: .infinity)
        controls
      }
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        searchField.frame(maxWidth: .infinity)
        HStack(spacing: DesignSpacing.md) {
          leading.fixedSize()
          Spacer(minLength: 0)
          controls
        }
      }
      VStack(alignment: .leading, spacing: DesignSpacing.md) {
        searchField.frame(maxWidth: .infinity)
        WrappingHStack(spacing: DesignSpacing.md) {
          leading.fixedSize()
          dateButton
          tabFilter
          HStack(spacing: DesignSpacing.md) { selectionControls }
            .fixedSize()
        }
      }
    }
  }

  /// Any time, the tab's own filter, Select and help, together on the right with one gap.
  private var controls: some View {
    HStack(spacing: DesignSpacing.md) {
      dateButton
      tabFilter
      selectionControls
    }
    .fixedSize()
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
      isSelecting ? .filled : .outlined, shape: .roundedRect, size: .medium, isEnabled: true)
    SettingsInfoButton(
      rowTitle: String(localized: "History", comment: "History: the page name."),
      tooltip: String(
        localized: "How History works", comment: "History: hover text of the help button.")
    ) {
      HistoryHelpPopover(tab: tab)
    }
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.stTextTertiary)
        .accessibilityHidden(true)
      // #2807: History holds dictations AND transcripts, so the box searches "history".
      TextField(
        String(localized: "Search history", comment: "History: the search box placeholder."),
        text: binding(\.query)
      )
      .textFieldStyle(.plain)
      .font(.stBody)
      .focused($searchFocused)
    }
    .settingsFieldChrome(focused: $searchFocused)
    .frame(minWidth: 180)
  }

  // MARK: - Tab filters

  private var appButton: some View {
    filterButton(
      title: HistoryFilterLabels.app(state.app), isActive: state.app != .all, picker: .app,
      width: 260, maxHeight: 360
    ) {
      HistoryAppPicker(coordinator: coordinator, current: state.app) { choice in
        update { $0.app = choice }
      }
    }
  }

  /// The Meetings tab's app filter: the same button and list as the other filters.
  private var callAppButton: some View {
    filterButton(
      title: HistoryFilterLabels.callApp(state.callApp), isActive: state.callApp != nil,
      picker: .callApp, width: 220
    ) {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(HistoryFilterLabels.callAppChoices, id: \.self) { family in
          HistoryChoiceRow(
            title: HistoryFilterLabels.callApp(family), isCurrent: family == state.callApp
          ) { update { $0.callApp = family } }
        }
      }
    }
  }

  private var dateButton: some View {
    filterButton(
      title: HistoryDateFilter.label(for: state.dateInterval, now: Date(), calendar: .current),
      isActive: state.dateInterval != nil, picker: .date, width: 304
    ) {
      HistoryDatePicker(coordinator: coordinator, tab: tab, current: state.dateInterval) {
        interval in
        update { $0.dateInterval = interval }
      }
      .padding(6)
    }
  }

  /// One filter control whose list needs more than the Mac menu can draw (counts, a calendar):
  /// the square drop-down button with the current choice, opening `settingsDropdown`. A set
  /// filter is drawn filled so a narrowed list is visible at a glance.
  private func filterButton<Content: View>(
    title: String, isActive: Bool, picker: Picker, width: CGFloat, maxHeight: CGFloat? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    // Every filter button has one width: the invisible sizer sets it, the real button fills it.
    Self.filterWidthSizer(Self.filterWidthTitles)
      .overlay {
        Button {
          openPicker = picker
        } label: {
          HistoryFilterButtonLabel(title: title)
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

  private func binding<Value>(_ keyPath: WritableKeyPath<HistoryTabState, Value>) -> Binding<Value>
  {
    Binding(
      get: { coordinator.requestedHistoryState(for: tab)[keyPath: keyPath] },
      set: { value in update { $0[keyPath: keyPath] = value } })
  }

  /// Applies `change` to the tab's live state; a picker choice also closes its popover.
  private func update(_ change: (inout HistoryTabState) -> Void) {
    var live = coordinator.requestedHistoryState(for: tab)
    change(&live)
    coordinator.setHistoryState(live, for: tab)
    openPicker = nil
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
  /// Unknown app when any dictation has no recorded app.
  nonisolated static func appOptions(_ apps: [String?]) -> [AppOption] {
    var counts: [String: Int] = [:]
    var unknown = 0
    for app in apps {
      if let app, app.isEmpty == false {
        counts[app, default: 0] += 1
      } else {
        unknown += 1
      }
    }
    return appOptions(counts: counts.map { (Optional($0.key), $0.value) } + [(nil, unknown)])
  }

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
