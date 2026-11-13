import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// History's three tabs (#3147 §3.3): each lists only its kind, keeps its own search and filters,
/// lists every matching item across pages, and History search reads each dictation's preferred
/// text. Rows go through a real `TranscriptStore` under a temp directory.
@MainActor
/// Class: `.productOutcome` — which items each History tab lists, and what the user's search,
/// filters and open item do when tabs switch.
@Suite("History tabs: kinds, per-tab state and filters (#3147)", .tags(.productOutcome))
struct HistoryTabStateTests {

  private func makeCoordinator() -> TranscriptCoordinator {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-3147-tabs-\(UUID().uuidString)", isDirectory: true)
    return TranscriptCoordinator(store: TranscriptStore(directory: dir))
  }

  private func dictation(
    _ text: String, polished: String? = nil, app: String? = nil, age: TimeInterval = 0
  ) -> Transcript {
    var metrics = ExecutionMetrics()
    metrics.targetApp = app
    return Transcript(
      text: text, polishedText: polished, createdAt: Date().addingTimeInterval(-age),
      metrics: metrics)
  }

  private func imported(
    _ text: String, speakers: TranscriptSpeakerAnalysis?, age: TimeInterval = 0
  ) -> Transcript {
    Transcript(
      text: text, createdAt: Date().addingTimeInterval(-age), importedFileName: "\(text).m4a",
      speakerAnalysis: speakers)
  }

  private func rowIDs(_ items: [HistoryListItem]) -> [UUID] { items.compactMap(\.row?.id) }

  @Test("each tab lists only its own kind")
  func tabsListTheirKind() async throws {
    let coordinator = makeCoordinator()
    let d = dictation("a dictation", age: 20)
    let t = imported("an interview", speakers: .single, age: 10)
    let m = Transcript(text: "a meeting", meetingID: UUID())
    for row in [d, t, m] { try await coordinator.saveAndShow(row) }

    #expect(rowIDs(coordinator.matchingHistoryItems(in: .dictations)) == [d.id])
    #expect(rowIDs(coordinator.matchingHistoryItems(in: .transcripts)) == [t.id])
    #expect(rowIDs(coordinator.matchingHistoryItems(in: .meetings)) == [m.id])
  }

  @Test("a tab keeps its search when another tab searches or the user switches tabs")
  func tabsKeepTheirOwnSearch() async throws {
    let coordinator = makeCoordinator()
    let apple = dictation("apple pie", age: 20)
    let pear = dictation("pear tart", age: 10)
    let talk = imported("apple orchard talk", speakers: .single)
    for row in [apple, pear, talk] { try await coordinator.saveAndShow(row) }

    var dictations = coordinator.historyState(for: .dictations)
    dictations.query = "pear"
    coordinator.setHistoryState(dictations, for: .dictations)
    var transcripts = coordinator.historyState(for: .transcripts)
    transcripts.query = "orchard"
    coordinator.setHistoryState(transcripts, for: .transcripts)
    coordinator.selectHistoryTab(.transcripts)
    coordinator.selectHistoryTab(.dictations)

    #expect(coordinator.historyState(for: .dictations).query == "pear")
    #expect(rowIDs(coordinator.matchingHistoryItems(in: .dictations)) == [pear.id])
    #expect(rowIDs(coordinator.matchingHistoryItems(in: .transcripts)) == [talk.id])
    #expect(coordinator.historyState(for: .meetings) == HistoryTabState())
  }

  @Test("choosing a tab remembers it once; reopening at launch remembers nothing")
  func tabChoiceIsRemembered() {
    let coordinator = makeCoordinator()
    var remembered: [HistoryTab] = []
    coordinator.onHistoryTabSelected = { remembered.append($0) }

    coordinator.restoreHistoryTab(.meetings)
    #expect(coordinator.historyTab == .meetings)
    #expect(remembered.isEmpty)

    coordinator.selectHistoryTab(.transcripts)
    coordinator.selectHistoryTab(.transcripts)
    #expect(coordinator.historyTab == .transcripts)
    #expect(remembered == [.transcripts])
  }

  @Test("App filter: one named app, or the dictations with no recorded app")
  func appFilter() async throws {
    let coordinator = makeCoordinator()
    let slack = dictation("to slack", app: "Slack", age: 30)
    let mail = dictation("to mail", app: "Mail", age: 20)
    let none = dictation("to nowhere", app: nil, age: 10)
    for row in [slack, mail, none] { try await coordinator.saveAndShow(row) }

    var state = HistoryTabState()
    state.app = .named("Slack")
    coordinator.setHistoryState(state, for: .dictations)
    #expect(rowIDs(coordinator.matchingHistoryItems(in: .dictations)) == [slack.id])

    state.app = .unknown
    coordinator.setHistoryState(state, for: .dictations)
    #expect(rowIDs(coordinator.matchingHistoryItems(in: .dictations)) == [none.id])
  }

  @Test("date filter: start included, end excluded")
  func dateFilterBounds() async throws {
    let coordinator = makeCoordinator()
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let end = start.addingTimeInterval(86_400)
    let atStart = Transcript(text: "at start", createdAt: start)
    let beforeEnd = Transcript(text: "before end", createdAt: end.addingTimeInterval(-0.001))
    let atEnd = Transcript(text: "at end", createdAt: end)
    for row in [atStart, beforeEnd, atEnd] { try await coordinator.saveAndShow(row) }

    var state = HistoryTabState()
    state.dateInterval = DateInterval(start: start, end: end)
    coordinator.setHistoryState(state, for: .dictations)
    #expect(
      Set(rowIDs(coordinator.matchingHistoryItems(in: .dictations)))
        == [atStart.id, beforeEnd.id])
  }

  @Test("date filter keeps only items inside the interval")
  func dateFilter() async throws {
    let coordinator = makeCoordinator()
    let recent = dictation("recent", age: 60)
    let old = dictation("old", age: 3 * 86_400)
    for row in [recent, old] { try await coordinator.saveAndShow(row) }

    var state = HistoryTabState()
    state.dateInterval = DateInterval(start: Date().addingTimeInterval(-86_400), end: Date())
    coordinator.setHistoryState(state, for: .dictations)
    #expect(rowIDs(coordinator.matchingHistoryItems(in: .dictations)) == [recent.id])
  }

  @Test("Speakers filter counts from the speaker analysis; an unanalyzed row never matches it")
  func speakerFilter() async throws {
    let coordinator = makeCoordinator()
    let one = imported("solo", speakers: .single, age: 30)
    let two = imported("pair", speakers: .labeled(count: 2), age: 20)
    let unknown = imported("unknown", speakers: .unanalyzed, age: 10)
    for row in [one, two, unknown] { try await coordinator.saveAndShow(row) }

    var state = HistoryTabState()
    state.speakerCount = 2...10
    coordinator.setHistoryState(state, for: .transcripts)
    #expect(rowIDs(coordinator.matchingHistoryItems(in: .transcripts)) == [two.id])

    state.speakerCount = 1...1
    coordinator.setHistoryState(state, for: .transcripts)
    #expect(rowIDs(coordinator.matchingHistoryItems(in: .transcripts)) == [one.id])
  }

  @Test("matching items cover every page, not only the 30 drawn")
  func matchingCoversAllPages() async throws {
    let coordinator = makeCoordinator()
    for i in 0..<45 { try await coordinator.saveAndShow(dictation("row \(i)", age: Double(i))) }
    #expect(coordinator.matchingHistoryItems(in: .dictations).count == 45)
  }

  @Test("a changed search starts paging again; an open item that stops matching reads as closed")
  func searchResetsPagingAndClosesHiddenItem() async throws {
    let coordinator = makeCoordinator()
    let apple = dictation("apple", age: 10)
    try await coordinator.saveAndShow(apple)

    var state = HistoryTabState()
    state.requestedCount = 90
    state.openItemID = .transcript(apple.id)
    coordinator.setHistoryState(state, for: .dictations)
    #expect(coordinator.historyState(for: .dictations).requestedCount == 90)
    #expect(coordinator.historyState(for: .dictations).openItemID == .transcript(apple.id))

    state.query = "banana"
    coordinator.setHistoryState(state, for: .dictations)
    let after = coordinator.historyState(for: .dictations)
    #expect(after.requestedCount == HistoryTabState.pageSize)
    #expect(after.openItemID == nil)
  }

  @Test("History search reads each dictation's preferred text")
  func searchReadsPreferredText() async throws {
    let coordinator = makeCoordinator()
    let row = dictation("um raw words", polished: "Clean words.").preferring(.original)
    try await coordinator.saveAndShow(row)

    var state = HistoryTabState()
    state.query = "raw"
    coordinator.setHistoryState(state, for: .dictations)
    #expect(rowIDs(coordinator.matchingHistoryItems(in: .dictations)) == [row.id])

    state.query = "Clean"
    coordinator.setHistoryState(state, for: .dictations)
    #expect(coordinator.matchingHistoryItems(in: .dictations).isEmpty)
  }

  @Test("activity counts one entry per day under the tab's other filters")
  func activityCountsPerDay() async throws {
    let coordinator = makeCoordinator()
    let calendar = Calendar(identifier: .gregorian)
    let now = Date()
    let rows = [
      dictation("a", age: 0), dictation("b", age: 1), dictation("c", age: 3 * 86_400),
    ]
    for row in rows { try await coordinator.saveAndShow(row) }
    var state = HistoryTabState()
    state.dateInterval = DateInterval(start: now.addingTimeInterval(-60), end: now)
    coordinator.setHistoryState(state, for: .dictations)

    let counts = await coordinator.historyActivity(in: .dictations, calendar: calendar)
    let byDay = Dictionary(grouping: rows.map(\.createdAt)) { calendar.startOfDay(for: $0) }
      .mapValues(\.count)
    #expect(counts == byDay)
    #expect(counts.values.reduce(0, +) == 3)
  }
}
