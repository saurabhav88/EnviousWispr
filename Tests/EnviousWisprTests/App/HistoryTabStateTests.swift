import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// History's three tabs (#3147 §3.3): each lists only its kind, keeps its own search and filters,
/// lists every matching item across pages, and History search reads each dictation's preferred
/// text. Rows go through the production path (#4586): real folders and a real catalog session,
/// as `HistoryCatalogRig` wires them.
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

  @Test("each tab lists only its own kind")
  func tabsListTheirKind() async throws {
    let d = dictation("a dictation", age: 20)
    let t = imported("an interview", speakers: .single, age: 10)
    let m = Transcript(text: "a meeting", meetingID: UUID())
    let rig = try await HistoryCatalogRig.make(rows: [d, t, m])
    defer { rig.remove() }

    #expect(await rig.listedRowIDs(.dictations) == [d.id])
    #expect(await rig.listedRowIDs(.transcripts) == [t.id])
    #expect(await rig.listedRowIDs(.meetings) == [m.id])
  }

  @Test("a tab keeps its search when another tab searches or the user switches tabs")
  func tabsKeepTheirOwnSearch() async throws {
    let apple = dictation("apple pie", age: 20)
    let pear = dictation("pear tart", age: 10)
    let talk = imported("apple orchard talk", speakers: .single)
    let rig = try await HistoryCatalogRig.make(rows: [apple, pear, talk])
    defer { rig.remove() }
    let coordinator = rig.coordinator

    var dictations = coordinator.requestedHistoryState(for: .dictations)
    dictations.query = "pear"
    coordinator.setHistoryState(dictations, for: .dictations)
    var transcripts = coordinator.requestedHistoryState(for: .transcripts)
    transcripts.query = "orchard"
    coordinator.setHistoryState(transcripts, for: .transcripts)
    coordinator.selectHistoryTab(.transcripts)
    coordinator.selectHistoryTab(.dictations)

    #expect(coordinator.requestedHistoryState(for: .dictations).query == "pear")
    #expect(await rig.listedRowIDs(.dictations) == [pear.id])
    #expect(await rig.listedRowIDs(.transcripts) == [talk.id])
    #expect(coordinator.requestedHistoryState(for: .meetings) == HistoryTabState())
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
    let slack = dictation("to slack", app: "Slack", age: 30)
    let mail = dictation("to mail", app: "Mail", age: 20)
    let none = dictation("to nowhere", app: nil, age: 10)
    let rig = try await HistoryCatalogRig.make(rows: [slack, mail, none])
    defer { rig.remove() }

    var state = HistoryTabState()
    state.app = .named("Slack")
    rig.coordinator.setHistoryState(state, for: .dictations)
    #expect(await rig.listedRowIDs(.dictations) == [slack.id])

    state.app = .unknown
    rig.coordinator.setHistoryState(state, for: .dictations)
    #expect(await rig.listedRowIDs(.dictations) == [none.id])
  }

  @Test("date filter: start included, end excluded")
  func dateFilterBounds() async throws {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let end = start.addingTimeInterval(86_400)
    let atStart = Transcript(text: "at start", createdAt: start)
    let beforeEnd = Transcript(text: "before end", createdAt: end.addingTimeInterval(-0.001))
    let atEnd = Transcript(text: "at end", createdAt: end)
    let rig = try await HistoryCatalogRig.make(rows: [atStart, beforeEnd, atEnd])
    defer { rig.remove() }

    var state = HistoryTabState()
    state.dateInterval = DateInterval(start: start, end: end)
    rig.coordinator.setHistoryState(state, for: .dictations)
    #expect(Set(await rig.listedRowIDs(.dictations)) == [atStart.id, beforeEnd.id])
  }

  @Test("date filter keeps only items inside the interval")
  func dateFilter() async throws {
    let recent = dictation("recent", age: 60)
    let old = dictation("old", age: 3 * 86_400)
    let rig = try await HistoryCatalogRig.make(rows: [recent, old])
    defer { rig.remove() }

    var state = HistoryTabState()
    state.dateInterval = DateInterval(start: Date().addingTimeInterval(-86_400), end: Date())
    rig.coordinator.setHistoryState(state, for: .dictations)
    #expect(await rig.listedRowIDs(.dictations) == [recent.id])
  }

  // Deleted (#4586): "matching items cover every page, not only the 30 drawn" read the in-memory
  // list. The catalog's own page-and-count tests cover the same promise:
  // HistoryCatalogSessionTests (30 then 40 via `extending:`, `matchingIDs` = 40) and
  // Storage/HistoryCatalogTests (paging and `matchingKeys` over ties).

  @Test("a changed search or filter starts again at the top; an unchanged one keeps its place")
  func searchResetsScrollPosition() async throws {
    let coordinator = makeCoordinator()
    let apple = HistoryItemID.transcript(UUID())

    var state = HistoryTabState()
    state.scrollAnchorID = apple
    state.openItemID = apple
    coordinator.setHistoryState(state, for: .dictations)
    #expect(coordinator.requestedHistoryState(for: .dictations).scrollAnchorID == apple)
    #expect(coordinator.requestedHistoryState(for: .dictations).openItemID == apple)

    // Same search and filters (an open item changed): the place is kept.
    state.openItemID = nil
    coordinator.setHistoryState(state, for: .dictations)
    #expect(coordinator.requestedHistoryState(for: .dictations).scrollAnchorID == apple)

    state.query = "banana"
    coordinator.setHistoryState(state, for: .dictations)
    #expect(coordinator.requestedHistoryState(for: .dictations).scrollAnchorID == nil)

    state.scrollAnchorID = apple
    state.app = .named("Slack")
    coordinator.setHistoryState(state, for: .dictations)
    #expect(coordinator.requestedHistoryState(for: .dictations).scrollAnchorID == nil)
  }

  @Test("History search reads each dictation's preferred text")
  func searchReadsPreferredText() async throws {
    let row = dictation("um raw words", polished: "Clean words.").preferring(.original)
    let rig = try await HistoryCatalogRig.make(rows: [row])
    defer { rig.remove() }
    let coordinator = rig.coordinator

    var state = HistoryTabState()
    state.query = "raw"
    coordinator.setHistoryState(state, for: .dictations)
    let rawKey = coordinator.historyQueryKey(for: .dictations, state: state)
    let rawResult = await coordinator.historyResults(for: rawKey)
    #expect(rawResult?.ids == [.transcript(row.id)])

    state.query = "Clean"
    coordinator.setHistoryState(state, for: .dictations)
    #expect(await rig.listedIDs(.dictations).isEmpty)
    #expect(await coordinator.historyResults(for: rawKey) == nil)
    let cleanKey = coordinator.historyQueryKey(for: .dictations, state: state)
    #expect(await coordinator.historyResults(for: cleanKey)?.ids.isEmpty == true)
  }

  @Test("activity counts one entry per day under the tab's other filters")
  func activityCountsPerDay() async throws {
    let calendar = Calendar(identifier: .gregorian)
    let now = Date()
    let rows = [
      dictation("a", age: 0), dictation("b", age: 1), dictation("c", age: 3 * 86_400),
    ]
    let rig = try await HistoryCatalogRig.make(rows: rows)
    defer { rig.remove() }
    var state = HistoryTabState()
    state.dateInterval = DateInterval(start: now.addingTimeInterval(-60), end: now)
    rig.coordinator.setHistoryState(state, for: .dictations)

    let counts = await rig.coordinator.historyActivity(in: .dictations, calendar: calendar)
    let byDay = Dictionary(grouping: rows.map(\.createdAt)) { calendar.startOfDay(for: $0) }
      .mapValues(\.count)
    #expect(counts == byDay)
    #expect(counts.values.reduce(0, +) == 3)
  }
}
