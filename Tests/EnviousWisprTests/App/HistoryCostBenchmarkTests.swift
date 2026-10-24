import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #4001 step 0: how long History's list work takes with dictations, file transcripts and
/// meetings together, so the refactor is judged on numbers. A measurement, not a gate: it runs
/// only when `TEST_RUNNER_EW_HISTORY_BENCH=1` and writes one line per operation and size to the
/// file named by `TEST_RUNNER_EW_HISTORY_BENCH_OUT` (milliseconds, fastest of five, this Mac).
@Suite(
  "History cost benchmark", .tags(.harnessContract),
  .enabled(if: ProcessInfo.processInfo.environment["EW_HISTORY_BENCH"] != nil))
@MainActor
struct HistoryCostBenchmarkTests {

  /// About 40 words, like an ordinary dictation.
  static let dictationText =
    "Remind me to send the updated contract to the legal team today and to ask Maria whether the "
    + "screenshots for the help pages are ready before Friday morning, then book the room for "
    + "the release review."

  /// A meeting row of `turns` turns of about 15 words each (600 turns is about an hour).
  static func meetingRow(meetingID: UUID, rowID: UUID, turns count: Int, createdAt: Date)
    -> Transcript
  {
    var text = ""
    var turns: [Turn] = []
    for i in 0..<count {
      let line =
        "We agreed the build is ready and the testers signed off on item \(i) of the release list."
      if !text.isEmpty { text += "\n" }
      let lower = text.utf16.count
      text += line
      turns.append(
        Turn(
          id: "t\(i)", speakerId: i % 2 == 0 ? "sys:S1" : "mic:you", startMs: i * 6_000,
          endMs: i * 6_000 + 5_000, originalTextRange: lower..<text.utf16.count))
    }
    return Transcript(
      id: rowID, text: text, backendType: .parakeet, createdAt: createdAt,
      speakerAnalysis: .labeled(count: 2), speakerNames: ["sys:S1": "Maria", "mic:you": "You"],
      turns: turns, meetingID: meetingID)
  }

  struct Fixture {
    let coordinator: TranscriptCoordinator
    let records: [MeetingRecord]
  }

  static func fixture(dictations: Int, meetings: Int, turns: Int) -> Fixture {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-4001-bench-\(UUID().uuidString)", isDirectory: true)
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    var rows: [Transcript] = []
    var records: [MeetingRecord] = []
    let now = Date()
    for i in 0..<dictations {
      let created = now.addingTimeInterval(-TimeInterval(i * 60))
      rows.append(
        i % 10 == 0
          ? Transcript(
            text: dictationText, language: "en", duration: 61, backendType: .parakeet,
            createdAt: created, importedFileName: "file-\(i).m4a")
          : Transcript(text: dictationText, createdAt: created))
    }
    for i in 0..<meetings {
      let created = now.addingTimeInterval(-TimeInterval(i * 3_600 + 30))
      var record = MeetingRecord(
        createdAt: created, engine: .parakeet, trackStatus: [.microphone: .captured])
      record.state = .ready
      records.append(record)
      rows.append(
        meetingRow(
          meetingID: record.id, rowID: record.transcriptID, turns: turns, createdAt: created))
    }
    rows.sort { $0.createdAt > $1.createdAt }
    coordinator.setTranscriptsForTesting(rows)
    coordinator.meetingRecords = { records }
    let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    coordinator.meetingInfo = { id in byID[id].map(MeetingHistoryInfo.init(record:)) }
    coordinator.meetingNotes = { _ in "Ask Maria about screenshots" }
    return Fixture(coordinator: coordinator, records: records)
  }

  /// Fastest of five runs, in milliseconds; `setup` runs before each, untimed.
  static func fastest(setup: () -> Void = {}, _ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    var best = Duration.seconds(1_000)
    for _ in 0..<5 {
      setup()
      let start = clock.now
      body()
      best = min(best, clock.now - start)
    }
    let parts = best.components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
  }

  @Test("History list costs at 1,000 and 10,000 dictations with 100 hour-long meetings")
  func listCosts() throws {
    let environment = ProcessInfo.processInfo.environment
    let out = try #require(environment["EW_HISTORY_BENCH_OUT"], "EW_HISTORY_BENCH_OUT is not set")
    var lines: [String] = []
    for dictations in [1_000, 10_000] {
      let fixture = Self.fixture(dictations: dictations, meetings: 100, turns: 600)
      let c = fixture.coordinator
      func record(_ name: String, _ ms: Double) {
        lines.append("\(name)\t\(dictations)\t\(String(format: "%.2f", ms))")
      }
      c.historyFilter = .all
      c.searchQuery = ""
      record("listedItems", Self.fastest { _ = c.listedItems })
      record("listedCount", Self.fastest { _ = c.listedCount })
      record("deletableCount", Self.fastest { _ = c.deletableCount })
      record("emptyState", Self.fastest { _ = c.emptyState })
      let meetingItem = HistoryItemID.meeting(try #require(fixture.records.first).id)
      c.selectedItemID = meetingItem
      record("detail", Self.fastest { _ = c.detail })
      // One redraw of the History sidebar and its detail pane reads all of these.
      record(
        "sidebarRedraw",
        Self.fastest {
          _ = c.listedItems
          _ = c.emptyState
          _ = c.deletableCount
          _ = c.listedCount
          _ = c.detail
        })
      // The same redraw right after the filter changed, each direction timed on its own.
      func redraw() {
        _ = c.listedItems
        _ = c.emptyState
        _ = c.deletableCount
        _ = c.listedCount
        _ = c.detail
      }
      for (name, from, to) in [
        ("redrawAllToDictations", HistoryFilter.all, HistoryFilter.dictations),
        ("redrawDictationsToAll", .dictations, .all),
      ] {
        record(
          name,
          Self.fastest(setup: {
            c.historyFilter = from
            redraw()
          }) {
            c.historyFilter = to
            redraw()
          })
      }
      c.historyFilter = .all
      c.selectedItemID = nil
      // Each timed keystroke changes the query, so it measures a search that must run.
      var useZebra = false
      record(
        "searchKeystroke",
        Self.fastest {
          useZebra.toggle()
          c.searchQuery = useZebra ? "zebra" : "giraffe"
          _ = c.listedItems
        })
      c.searchQuery = ""
      let row = try #require(c.listedItems.compactMap(\.row).first { $0.isMeeting })
      let info = c.meetingInfo?(try #require(row.meetingID))
      record(
        "meetingPreview",
        Self.fastest {
          _ = MeetingHistoryPresentation.project(row, info: info, showEcho: false)
        })
    }
    try (lines.joined(separator: "\n") + "\n").write(
      toFile: out, atomically: true, encoding: .utf8)
    #expect(lines.count == 20)
  }
}
