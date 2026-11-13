import EnviousWisprCore
import SwiftUI

/// The row under History's tabs (#3147 §3.3): search, the tab's own filter (App on Dictations,
/// Speakers on Transcripts, Call app on Meetings), the date filter, Select and help. Every
/// change goes through the coordinator's per-tab state, so each tab keeps its own.
struct HistoryFiltersView: View {
  let coordinator: TranscriptCoordinator
  let tab: HistoryTab
  let state: HistoryTabState
  let isSelecting: Bool
  let toggleSelecting: () -> Void

  @FocusState private var searchFocused: Bool
  @State private var openPicker: Picker?

  private enum Picker: Hashable { case app, speakers, callApp, date }

  var body: some View {
    WrappingHStack(spacing: 8) {
      searchField
      switch tab {
      case .dictations: appButton
      case .transcripts: speakersButton
      case .meetings: callAppButton
      }
      dateButton
      Button(action: toggleSelecting) {
        EnviousButtonLabel(
          isSelecting
            ? LocalizedStringResource(
              "Done selecting", comment: "History: leaves selection mode.")
            : LocalizedStringResource(
              "Select", comment: "History: enters selection mode to delete several items."),
          systemImage: "checkmark.circle")
      }
      .settingsButton(isSelecting ? .filled : .outlined, isEnabled: true)
      SettingsInfoButton(
        rowTitle: String(localized: "History", comment: "History: the page name."),
        tooltip: String(
          localized: "How History works", comment: "History: hover text of the help button.")
      ) {
        HistoryHelpPopover(tab: tab)
      }
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
    .frame(minWidth: 180, maxWidth: 280)
  }

  // MARK: - Tab filters

  private var appButton: some View {
    filterButton(
      title: HistoryFilterLabels.app(state.app), isActive: state.app != .all, picker: .app
    ) {
      HistoryAppPicker(coordinator: coordinator, current: state.app) { choice in
        update { $0.app = choice }
      }
    }
  }

  private var speakersButton: some View {
    filterButton(
      title: HistoryFilterLabels.speakers(state.speakerCount),
      isActive: state.speakerCount != nil, picker: .speakers
    ) {
      HistoryChoiceList(
        choices: HistoryFilterLabels.speakerChoices.map {
          .init(value: $0, title: HistoryFilterLabels.speakers($0))
        },
        current: state.speakerCount
      ) { choice in
        update { $0.speakerCount = choice }
      }
    }
  }

  private var callAppButton: some View {
    filterButton(
      title: HistoryFilterLabels.callApp(state.callApp), isActive: state.callApp != nil,
      picker: .callApp
    ) {
      HistoryChoiceList(
        choices: HistoryFilterLabels.callAppChoices.map {
          .init(value: $0, title: HistoryFilterLabels.callApp($0))
        },
        current: state.callApp
      ) { choice in
        update { $0.callApp = choice }
      }
    }
  }

  private var dateButton: some View {
    filterButton(
      title: HistoryDateFilter.label(for: state.dateInterval, now: Date(), calendar: .current),
      isActive: state.dateInterval != nil, picker: .date
    ) {
      HistoryDatePicker(coordinator: coordinator, tab: tab, current: state.dateInterval) {
        interval in
        update { $0.dateInterval = interval }
      }
    }
  }

  /// One filter control: a button with the current choice that opens its picker. A set filter
  /// is drawn filled so a narrowed list is visible at a glance.
  private func filterButton<Content: View>(
    title: String, isActive: Bool, picker: Picker, @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    Button {
      openPicker = picker
    } label: {
      EnviousButtonLabel(verbatim: title, trailingSystemImage: "chevron.down")
    }
    .settingsButton(isActive ? .filled : .outlined, isEnabled: true)
    .popover(
      isPresented: Binding(
        get: { openPicker == picker },
        set: { if $0 == false, openPicker == picker { openPicker = nil } }),
      arrowEdge: .bottom
    ) {
      content()
        .padding(12)
    }
  }

  // MARK: - State

  private func binding<Value>(_ keyPath: WritableKeyPath<HistoryTabState, Value>) -> Binding<Value>
  {
    Binding(
      get: { coordinator.historyState(for: tab)[keyPath: keyPath] },
      set: { value in update { $0[keyPath: keyPath] = value } })
  }

  /// Applies `change` to the tab's live state; a picker choice also closes its popover.
  private func update(_ change: (inout HistoryTabState) -> Void) {
    var live = coordinator.historyState(for: tab)
    change(&live)
    coordinator.setHistoryState(live, for: tab)
    openPicker = nil
  }
}

/// A short list of choices with a checkmark on the current one.
private struct HistoryChoiceList<Value: Hashable>: View {
  struct Choice: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
  }

  let choices: [Choice]
  let current: Value
  let choose: (Value) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(choices) { choice in
        HistoryChoiceRow(
          title: choice.title, detail: nil, isCurrent: choice.value == current
        ) { choose(choice.value) }
      }
    }
    .frame(minWidth: 220)
  }
}

/// One row of a filter picker: its name, an optional count, and a checkmark when chosen.
private struct HistoryChoiceRow: View {
  let title: String
  let detail: String?
  let isCurrent: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark")
          .opacity(isCurrent ? 1 : 0)
          .foregroundStyle(.stAccent)
          .accessibilityHidden(true)
        Text(title)
          .font(.stBody)
          .foregroundStyle(.stTextPrimary)
        Spacer(minLength: 12)
        if let detail {
          Text(detail)
            .font(.stHelper.monospacedDigit())
            .foregroundStyle(.stTextSecondary)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .settingsHoverRow()
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
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
          HistoryChoiceRow(
            title: HistoryFilterLabels.app(option.filter),
            detail: option.count.formatted(), isCurrent: option.filter == current
          ) { choose(option.filter) }
        }
      } else {
        ProgressView().controlSize(.small)
          .frame(maxWidth: .infinity)
      }
    }
    .frame(minWidth: 240)
    .task {
      // The apps are read here; counting and sorting run off the main actor.
      let apps = coordinator.visibleTranscripts.filter { $0.isImported == false }
        .map { $0.metrics?.targetApp }
      options = await Task.detached(priority: .userInitiated) {
        HistoryFilterLabels.appOptions(apps)
      }.value
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

  /// All apps first (every dictation), then each recorded app by count (ties by name), then
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
    let named = counts.sorted { lhs, rhs in
      lhs.value != rhs.value
        ? lhs.value > rhs.value
        : lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
    }
    var options = [AppOption(filter: .all, count: apps.count)]
    options += named.map { AppOption(filter: .named($0.key), count: $0.value) }
    if unknown > 0 { options.append(AppOption(filter: .unknown, count: unknown)) }
    return options
  }

  static func app(_ filter: HistoryAppFilter) -> String {
    switch filter {
    case .all:
      String(localized: "All apps", comment: "History, Dictations: the App filter shows every app.")
    case .unknown:
      String(
        localized: "Unknown app",
        comment: "History, Dictations: dictations with no recorded app they went to.")
    case .named(let name):
      name
    }
  }

  /// Any, one speaker, two speakers, three or more.
  static let speakerChoices: [ClosedRange<Int>?] = [nil, 1...1, 2...2, 3...Int.max]

  static func speakers(_ range: ClosedRange<Int>?) -> String {
    switch range {
    case nil:
      String(
        localized: "Any number of speakers",
        comment: "History, Transcripts: the Speakers filter shows every transcript.")
    case 1...1:
      String(localized: "1 speaker", comment: "History, Transcripts: transcripts with one speaker.")
    case 2...2:
      String(
        localized: "2 speakers", comment: "History, Transcripts: transcripts with two speakers.")
    case let range?:
      String(
        localized: "\(String(range.lowerBound)) or more speakers",
        comment: "History, Transcripts: transcripts with at least this many speakers.")
    }
  }

  /// Any call app, then every call app by name.
  static var callAppChoices: [CallAppFamily?] {
    [nil]
      + CallAppFamily.allCases.sorted {
        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
  }

  static func callApp(_ family: CallAppFamily?) -> String {
    guard let family else {
      return String(
        localized: "Any call app",
        comment: "History, Meetings: the Call app filter shows every meeting.")
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
    case .yesterday: return Self.days(from: Self.day(today, plus: -1, calendar), count: 1, calendar: calendar)
    case .last7Days: return Self.days(from: Self.day(today, plus: -6, calendar), count: 7, calendar: calendar)
    case .last30Days: return Self.days(from: Self.day(today, plus: -29, calendar), count: 30, calendar: calendar)
    case .day(let date): return Self.days(from: calendar.startOfDay(for: date), count: 1, calendar: calendar)
    }
  }

  /// The name of a quick pick.
  var title: String {
    switch self {
    case .today: String(localized: "Today", comment: "History: the day heading for today's items.")
    case .yesterday:
      String(localized: "Yesterday", comment: "History: the day heading for yesterday's items.")
    case .last7Days:
      String(localized: "Last 7 days", comment: "History date filter: items from the last seven days.")
    case .last30Days:
      String(localized: "Last 30 days", comment: "History date filter: items from the last 30 days.")
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
    if let pick = quickPicks.first(where: { $0.interval(now: now, calendar: calendar) == interval }) {
      return pick.title
    }
    let lastDay = calendar.date(byAdding: .second, value: -1, to: interval.end) ?? interval.end
    if calendar.isDate(interval.start, inSameDayAs: lastDay) {
      return HistoryDateFilter.day(interval.start).title
    }
    let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
    return String(
      localized: "\(interval.start.formatted(style)) to \(lastDay.formatted(style))",
      comment: "History date filter: a range of days. The first %@ is the first day, the second the last.")
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
  private let calendar = Calendar.current

  var body: some View {
    let now = Date()
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        HistoryChoiceRow(
          title: HistoryDateFilter.label(for: nil, now: now, calendar: calendar), detail: nil,
          isCurrent: current == nil
        ) { choose(nil) }
        ForEach(HistoryDateFilter.quickPicks, id: \.title) { pick in
          let interval = pick.interval(now: now, calendar: calendar)
          HistoryChoiceRow(title: pick.title, detail: nil, isCurrent: current == interval) {
            choose(interval)
          }
        }
      }
      Divider()
      monthHeader
      calendarGrid(now: now)
    }
    .frame(width: 280)
    // The tab's counts do not depend on the month shown, so they are read once.
    .task {
      activity = await coordinator.historyActivity(in: tab, calendar: calendar)
    }
  }

  private var monthHeader: some View {
    HStack {
      Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
        .buttonStyle(.borderless)
        .accessibilityLabel(String(localized: "Previous month", comment: "History date picker: shows the month before."))
      Spacer()
      Text(month.formatted(.dateTime.month(.wide).year()))
        .font(.stRowLabel)
        .foregroundStyle(.stTextPrimary)
      Spacer()
      Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
        .buttonStyle(.borderless)
        .disabled(calendar.isDate(month, equalTo: Date(), toGranularity: .month))
        .accessibilityLabel(String(localized: "Next month", comment: "History date picker: shows the month after."))
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
    let interval = HistoryDateFilter.day(day).interval(now: now, calendar: calendar)
    let count = activity[day] ?? 0
    let isChosen = current == interval
    let isFuture = day > now
    return Button {
      choose(interval)
    } label: {
      VStack(spacing: 2) {
        Text(day.formatted(.dateTime.day()))
          .font(.stBody.monospacedDigit())
          .foregroundStyle(isChosen ? Color.white : (isFuture ? .stTextTertiary : .stTextPrimary))
        Circle()
          .fill(isChosen ? Color.white : Color.stAccent)
          .frame(width: 4, height: 4)
          .opacity(count > 0 ? 1 : 0)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, minHeight: 30)
      .background {
        if isChosen { Circle().fill(Color.stAccentSolid) }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isFuture)
    .accessibilityLabel(HistoryDateFilter.day(day).title)
    .accessibilityValue(
      count > 0
        ? String(localized: "Has items", comment: "History date picker: this day has items.")
        : String(localized: "No items", comment: "History date picker: this day has no items."))
    .accessibilityAddTraits(isChosen ? .isSelected : [])
  }

  private func shiftMonth(_ months: Int) {
    month = calendar.date(byAdding: .month, value: months, to: month) ?? month
  }
}
