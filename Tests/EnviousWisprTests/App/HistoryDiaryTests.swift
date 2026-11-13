import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// History's diary rules (#3147 §3.3): day groups and their counts, empty states, day headings,
/// the date filter's whole-day intervals, the App picker, help per tab, and open items kept per
/// tab.
@MainActor
/// Class: `.productOutcome` — a diary that splits or miscounts a day, says "nothing yet" over
/// hidden items, filters the wrong days, or loses the open transcript on a tab switch.
@Suite("History diary: days, filters and help (#3147)", .tags(.productOutcome))
struct HistoryDiaryTests {
  /// A fixed Gregorian calendar in UTC, so day boundaries never depend on the Mac running this.
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 1
    return calendar
  }()

  /// Wednesday 11 November 2026, 15:00 UTC.
  private static let now = Date(timeIntervalSince1970: 1_794_409_200)

  private static func item(daysAgo: Int, minutes: Int) -> HistoryListItem {
    let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
    return .transcript(
      Transcript(text: "row", createdAt: day.addingTimeInterval(TimeInterval(minutes * 60))))
  }

  @Test("the fixture's now is Wednesday 11 November 2026 in UTC")
  func fixtureDate() {
    let parts = Self.calendar.dateComponents([.year, .month, .day, .weekday], from: Self.now)
    #expect(parts.year == 2026 && parts.month == 11 && parts.day == 11 && parts.weekday == 4)
  }

  @Test("drawn items group by day, and a day cut by the page still counts all its items")
  func daysGroupAndCount() {
    // Newest first: 3 today, 4 yesterday, 2 three days ago.
    let items =
      [600, 500, 400].map { Self.item(daysAgo: 0, minutes: $0) }
      + [700, 600, 500, 400].map { Self.item(daysAgo: 1, minutes: $0) }
      + [300, 200].map { Self.item(daysAgo: 3, minutes: $0) }

    let page = HistoryDiaryLayout.days(items: items, boundary: 5, calendar: Self.calendar)
    #expect(page.map(\.items.count) == [3, 2])
    #expect(page.map(\.total) == [3, 4], "yesterday has 4 items though 2 are drawn")

    let all = HistoryDiaryLayout.days(items: items, boundary: 9, calendar: Self.calendar)
    #expect(all.map(\.items.count) == [3, 4, 2])
    #expect(all.map(\.total) == [3, 4, 2])
    #expect(
      all.map(\.start)
        == [0, 1, 3].map {
          Self.calendar.date(
            byAdding: .day, value: -$0, to: Self.calendar.startOfDay(for: Self.now))!
        })
    #expect(HistoryDiaryLayout.days(items: [], boundary: 30, calendar: Self.calendar).isEmpty)
  }

  @Test("Select day reaches every item on that day, drawn or not, and no other day")
  func dayIDs() {
    let items =
      (0..<3).map { Self.item(daysAgo: 0, minutes: 600 - $0) }
      + (0..<5).map { Self.item(daysAgo: 1, minutes: 600 - $0) }
    let yesterday = Self.calendar.date(byAdding: .day, value: -1, to: Self.now)!
    let ids = HistoryDiaryLayout.ids(onDayOf: yesterday, in: items, calendar: Self.calendar)
    #expect(ids == Set(items[3...].map(\.id)))
  }

  @Test("an empty tab says why: nothing of its kind yet, or a search or filter hides everything")
  func emptyStates() {
    var state = HistoryTabState()
    #expect(HistoryDiaryLayout.emptyState(tab: .dictations, state: state, matchingCount: 3) == nil)
    #expect(
      HistoryDiaryLayout.emptyState(tab: .dictations, state: state, matchingCount: 0)
        == .noDictations)
    #expect(
      HistoryDiaryLayout.emptyState(tab: .transcripts, state: state, matchingCount: 0)
        == .noTranscripts)
    #expect(
      HistoryDiaryLayout.emptyState(tab: .meetings, state: state, matchingCount: 0) == .noRecordings
    )
    state.query = "carrier"
    #expect(
      HistoryDiaryLayout.emptyState(tab: .dictations, state: state, matchingCount: 0) == .noMatches)
    state.query = ""
    state.callApp = .zoom
    #expect(
      HistoryDiaryLayout.emptyState(tab: .meetings, state: state, matchingCount: 0) == .noMatches)
  }

  @Test("day headings say Today and Yesterday, and add the year only for other years")
  func dayTitles() {
    let today = HistoryDiaryLayout.dayTitle(Self.now, now: Self.now, calendar: Self.calendar)
    #expect(today.relative == "Today")
    #expect(today.date.contains("11"))
    #expect(today.date.contains("2026") == false)
    let yesterday = HistoryDiaryLayout.dayTitle(
      Self.calendar.date(byAdding: .day, value: -1, to: Self.now)!, now: Self.now,
      calendar: Self.calendar)
    #expect(yesterday.relative == "Yesterday")
    let lastYear = HistoryDiaryLayout.dayTitle(
      Self.calendar.date(byAdding: .year, value: -1, to: Self.now)!, now: Self.now,
      calendar: Self.calendar)
    #expect(lastYear.relative == nil)
    #expect(lastYear.date.contains("2025"))
  }

  @Test("day summaries and the newer-version line read one whole sentence per count")
  func countSentences() {
    #expect(HistoryDiaryLayout.daySummary(tab: .dictations, count: 1) == "1 dictation")
    #expect(HistoryDiaryLayout.daySummary(tab: .dictations, count: 1200) == "1200 dictations")
    #expect(HistoryDiaryLayout.daySummary(tab: .transcripts, count: 2) == "2 transcripts")
    #expect(HistoryDiaryLayout.daySummary(tab: .meetings, count: 1) == "1 meeting")
    #expect(HistoryDiaryLayout.newerFormatLine(0) == nil)
    #expect(
      HistoryDiaryLayout.newerFormatLine(1)
        == "A recording was saved by a newer version of EnviousWispr. Update the app to open it.")
    #expect(
      HistoryDiaryLayout.newerFormatLine(3)
        == "3 recordings were saved by a newer version of EnviousWispr. Update the app to open them."
    )
  }

  @Test("date picks are whole days: start of the first day up to the start of the day after")
  func dateIntervals() {
    let start = Self.calendar.startOfDay(for: Self.now)
    func day(_ offset: Int) -> Date {
      Self.calendar.date(byAdding: .day, value: offset, to: start)!
    }
    #expect(
      HistoryDateFilter.today.interval(now: Self.now, calendar: Self.calendar)
        == DateInterval(start: start, end: day(1)))
    #expect(
      HistoryDateFilter.yesterday.interval(now: Self.now, calendar: Self.calendar)
        == DateInterval(start: day(-1), end: start))
    #expect(
      HistoryDateFilter.last7Days.interval(now: Self.now, calendar: Self.calendar)
        == DateInterval(start: day(-6), end: day(1)))
    #expect(
      HistoryDateFilter.last30Days.interval(now: Self.now, calendar: Self.calendar)
        == DateInterval(start: day(-29), end: day(1)))
    let picked = HistoryDateFilter.day(day(-3).addingTimeInterval(5000))
      .interval(now: Self.now, calendar: Self.calendar)
    #expect(picked == DateInterval(start: day(-3), end: day(-2)))
  }

  @Test("the date button names Any time, a quick pick, one day or a range")
  func dateLabels() {
    let start = Self.calendar.startOfDay(for: Self.now)
    func day(_ offset: Int) -> Date {
      Self.calendar.date(byAdding: .day, value: offset, to: start)!
    }
    #expect(HistoryDateFilter.label(for: nil, now: Self.now, calendar: Self.calendar) == "Any time")
    #expect(
      HistoryDateFilter.label(
        for: DateInterval(start: day(-6), end: day(1)), now: Self.now, calendar: Self.calendar)
        == "Last 7 days")
    let single = HistoryDateFilter.label(
      for: DateInterval(start: day(-3), end: day(-2)), now: Self.now, calendar: Self.calendar)
    #expect(single == HistoryDateFilter.day(day(-3)).title)
    let range = HistoryDateFilter.label(
      for: DateInterval(start: day(-10), end: day(-7)), now: Self.now, calendar: Self.calendar)
    #expect(range.contains(" to "))
  }

  @Test("the month grid starts on the calendar's first weekday and lists every day once")
  func monthGrid() {
    // November 2026 starts on a Sunday; with Sunday first there are no blanks.
    let grid = HistoryDateFilter.monthGrid(for: Self.now, calendar: Self.calendar)
    #expect(grid.count == 30)
    #expect(grid.first! == Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
    var mondayFirst = Self.calendar
    mondayFirst.firstWeekday = 2
    let shifted = HistoryDateFilter.monthGrid(for: Self.now, calendar: mondayFirst)
    #expect(shifted.prefix(6).allSatisfy { $0 == nil })
    #expect(shifted.compactMap { $0 }.count == 30)
  }

  @Test("the App picker lists All apps, then apps by count, then Unknown app")
  func appOptions() {
    let options = HistoryFilterLabels.appOptions(
      ["Slack", "Mail", "Slack", nil, "", "Notes", "Mail", "Slack"])
    #expect(
      options == [
        .init(filter: .all, count: 8), .init(filter: .named("Slack"), count: 3),
        .init(filter: .named("Mail"), count: 2), .init(filter: .named("Notes"), count: 1),
        .init(filter: .unknown, count: 2),
      ])
    #expect(HistoryFilterLabels.appOptions(["Slack"]).contains { $0.filter == .unknown } == false)
  }

  @Test("help leaves out Polish again and states the real recording retention")
  func helpPerTab() throws {
    let dictations = HistoryHelpContent.items(for: .dictations, retention: .forever)
    #expect(dictations.contains { $0.title.contains("Polish again") } == false)
    let storage = try #require(dictations.first { $0.icon == "lock" })
    #expect(storage.body.contains("kept until you delete them"))
    let weekly = HistoryHelpContent.items(for: .dictations, retention: .day7)
    #expect(weekly.first { $0.icon == "lock" }?.body.contains("7 days") == true)
    let meetings = HistoryHelpContent.items(for: .meetings, retention: .forever)
    #expect(
      meetings.contains { $0.icon == "play.circle" } == false,
      "the dictation player is not a meetings feature")
  }

  @Test("a day of thousands of items on page one still counts every one of them")
  func largeDayCountsAll() {
    let items = (0..<5_000).map { Self.item(daysAgo: 0, minutes: 900 - $0 / 10) }
      + [Self.item(daysAgo: 1, minutes: 10)]
    let days = HistoryDiaryLayout.days(items: items, boundary: 30, calendar: Self.calendar)
    #expect(days.count == 1)
    #expect(days[0].items.count == 30)
    #expect(days[0].total == 5_000)
    let entries = HistoryDiaryLayout.entries(days)
    #expect(entries.count == 31, "one heading, then the 30 drawn items")
    #expect(entries.first?.id == .day(days[0].start))
  }

  @Test("a heading at the top saves the first item under it; nothing scrolled saves no anchor")
  func scrollAnchorFromPosition() {
    let items =
      [600, 500].map { Self.item(daysAgo: 0, minutes: $0) }
      + [700, 600].map { Self.item(daysAgo: 1, minutes: $0) }
    let yesterday = Self.calendar.date(
      byAdding: .day, value: -1, to: Self.calendar.startOfDay(for: Self.now))!
    #expect(
      HistoryDiaryLayout.anchorID(for: .day(yesterday), in: items, calendar: Self.calendar)
        == items[2].id)
    #expect(
      HistoryDiaryLayout.anchorID(for: .item(items[1].id), in: items, calendar: Self.calendar)
        == items[1].id)
    #expect(HistoryDiaryLayout.anchorID(for: nil, in: items, calendar: Self.calendar) == nil)
  }

  @Test("opening the live meeting under a filter that hides it clears the filters; a listed one keeps them")
  func openingUnderAHidingFilter() async throws {
    let coordinator = TranscriptCoordinator(
      store: TranscriptStore(
        directory: TestTemporaryDirectory.url
          .appendingPathComponent("ew-3147-open-\(UUID().uuidString)", isDirectory: true)))
    let meetingID = UUID()
    coordinator.setTranscriptsForTesting([Transcript(text: "standup", meetingID: meetingID)])
    let id = HistoryItemID.meeting(meetingID)

    var filtered = HistoryTabState()
    let calendar = Calendar.current
    let lastWeek = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: Date()))!
    filtered.dateInterval = DateInterval(start: lastWeek, duration: 86_400)
    filtered.query = "budget"
    coordinator.setHistoryState(filtered, for: .meetings)
    let listed = coordinator.matchingHistoryItems(in: .meetings).contains { $0.id == id }
    #expect(listed == false, "precondition: the filter hides today's meeting")

    let opened = HistoryDiaryLayout.opening(
      id, in: coordinator.historyState(for: .meetings), isListed: listed)
    coordinator.setHistoryState(opened, for: .meetings)
    #expect(coordinator.historyState(for: .meetings).openItemID == id)
    #expect(coordinator.historyState(for: .meetings).dateInterval == nil)

    var kept = HistoryTabState()
    kept.query = "standup"
    let stays = HistoryDiaryLayout.opening(id, in: kept, isListed: true)
    #expect(stays.query == "standup")
    #expect(stays.openItemID == id)
  }

  @Test("an open transcript stays open on its tab while the person uses another tab")
  func openItemSurvivesTabSwitch() async throws {
    let coordinator = TranscriptCoordinator(
      store: TranscriptStore(
        directory: TestTemporaryDirectory.url
          .appendingPathComponent("ew-3147-diary-\(UUID().uuidString)", isDirectory: true)))
    let transcript = Transcript(text: "an interview", importedFileName: "interview.m4a")
    let dictation = Transcript(text: "a dictation")
    coordinator.setTranscriptsForTesting([transcript, dictation])

    var state = coordinator.historyState(for: .transcripts)
    state.openItemID = .transcript(transcript.id)
    coordinator.setHistoryState(state, for: .transcripts)
    coordinator.selectHistoryTab(.dictations)
    coordinator.selectHistoryTab(.transcripts)

    #expect(coordinator.historyState(for: .transcripts).openItemID == .transcript(transcript.id))
    #expect(coordinator.historyState(for: .dictations).openItemID == nil)
  }
}
