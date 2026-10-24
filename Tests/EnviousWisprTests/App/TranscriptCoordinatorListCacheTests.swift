#if DEBUG
  import EnviousWisprCore
  import Foundation
  import Observation
  import Testing

  @testable import EnviousWisprAppKit
  @testable import EnviousWisprStorage

  /// #4001: when these fail, History shows a stale list (a row added, replaced, deleted, expired,
  /// filtered or searched does not appear or disappear), counts, selection or empties disagree
  /// with the list, or the window stops redrawing when something changes, because the list is
  /// now built once and kept.
  @MainActor
  @Suite("History kept list", .tags(.productOutcome))
  struct TranscriptCoordinatorListCacheTests {

    /// What the coordinators read from EnviousMeet and the notes owner. Observable on its own,
    /// so a missing subscription to one source is not masked by another.
    @MainActor @Observable
    final class Sources {
      var records: [MeetingRecord] = []
      /// Info that differs from what the record would give (an orphan's, or a stale pairing).
      var infoOverride: [UUID: MeetingHistoryInfo] = [:]
      var notes: [UUID: String] = [:]
    }

    /// One coordinator that keeps its list and one that never does, fed the same inputs.
    @MainActor
    final class World {
      let sources = Sources()
      var time = Date(timeIntervalSinceReferenceDate: 800_000_000)
      let cached: TranscriptCoordinator
      let reference: TranscriptCoordinator
      var both: [TranscriptCoordinator] { [cached, reference] }

      init() {
        func make() -> TranscriptCoordinator {
          let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ew-4001-cache-\(UUID().uuidString)", isDirectory: true)
          // No pulse ever runs: a pulse sweeps with the wall clock, not `time`.
          return TranscriptCoordinator(
            store: TranscriptStore(directory: dir),
            // test-fixture-timer: a pulse sleep that never ends, so no pulse runs in these tests
            pendingPulseSleep: { _ in try? await Task.sleep(for: .seconds(86_400)) })
        }
        cached = make()
        reference = make()
        reference.listCacheDisabledForTesting = true
        for c in both {
          c.clock = { [unowned self] in time }
          c.meetingRecords = { [unowned self] in sources.records }
          c.meetingInfo = { [unowned self] id in
            sources.infoOverride[id]
              ?? sources.records.first { $0.id == id }.flatMap(MeetingHistoryInfo.paired(with:))
          }
          c.meetingNotes = { [unowned self] in sources.notes[$0] }
        }
      }

      func setRows(_ rows: [Transcript]) { for c in both { c.setTranscriptsForTesting(rows) } }
      var rows: [Transcript] { cached.rawTranscriptsForTesting }
    }

    /// What every list reader answers.
    struct Snapshot: Equatable {
      struct Item: Equatable {
        let id: HistoryItemID
        let rowID: UUID?
        let rowText: String?
        let held: Bool
        let recordState: MeetingState?
        let recordTitle: String?
      }
      let items: [Item]
      let filteredRowIDs: [UUID]
      let listedCount: Int
      let deletableCount: Int
      let emptyState: HistoryEmptyState?
      let detail: String
      let selected: HistoryItemID?
    }

    static func snapshot(_ c: TranscriptCoordinator) -> Snapshot {
      let items = c.listedItems.map { item in
        let record: MeetingRecord? =
          if case .meeting(let meeting) = item { meeting.record } else { nil }
        return Snapshot.Item(
          id: item.id, rowID: item.row?.id, rowText: item.row?.displayText,
          held: item.row?.escapeRecoveredAt != nil, recordState: record?.state,
          recordTitle: record?.title)
      }
      let detail: String
      switch c.detail {
      case .row(let row): detail = "row \(row.id) \(row.displayText)"
      case .meeting(let meeting): detail = "meeting \(meeting.meetingID) \(meeting.row?.id as Any)"
      case .liveFallback: detail = "live"
      case .empty: detail = "empty"
      }
      return Snapshot(
        items: items, filteredRowIDs: c.filteredTranscripts.map(\.id),
        listedCount: c.listedCount, deletableCount: c.deletableCount, emptyState: c.emptyState,
        detail: detail, selected: c.selectedItemID)
    }

    static func expectAgree(_ w: World, _ step: String) {
      #expect(snapshot(w.cached) == snapshot(w.reference), "step: \(step)")
    }

    static func meetingRow(
      _ meetingID: UUID, rowID: UUID = UUID(), words: String, at: Date, heldAt: Date? = nil
    ) -> Transcript {
      Transcript(
        id: rowID, text: words, backendType: .parakeet, createdAt: at, escapeRecoveredAt: heldAt,
        escapeRecoveryTakeID: heldAt.map { _ in "take-\(rowID)" },
        speakerAnalysis: .labeled(count: 1), speakerNames: ["sys:S1": "Maria"],
        turns: [
          Turn(
            id: "t0", speakerId: "sys:S1", startMs: 0, endMs: 1_000,
            originalTextRange: 0..<words.utf16.count)
        ], meetingID: meetingID)
    }

    static func record(at: Date, ready: Bool) -> MeetingRecord {
      var record = MeetingRecord(
        createdAt: at, engine: .parakeet, trackStatus: [.microphone: .captured])
      record.state = ready ? .ready : .processing
      return record
    }

    @Test("after every kind of change the kept list equals a list that is never kept")
    func keptListMatchesNeverKept() {
      let w = World()
      var rng = SeededGenerator(seed: 4001)
      let retention = AppConstants.pendingTranscriptRetention
      for step in 0..<600 {
        let at = w.time.addingTimeInterval(-Double(step) - 1)
        switch Int.random(in: 0..<20, using: &rng) {
        case 0:
          w.setRows(w.rows + [Transcript(text: "dictation \(step) zebra", createdAt: at)])
        case 1:
          let row = Transcript(
            text: "file \(step)", language: "en", duration: 10, backendType: .parakeet,
            createdAt: at, importedFileName: "giraffe-\(step).m4a")
          w.setRows(w.rows + [row])
        case 2:
          // A held (Escape-recovered) row, stamped near the end of its window or in the future.
          let stamp = w.time.addingTimeInterval(
            [-retention + 2, -retention + 30, -10, 30, 90].randomElement(using: &rng)!)
          w.setRows(
            w.rows + [
              Transcript(
                text: "held \(step) zebra", createdAt: at, escapeRecoveredAt: stamp,
                escapeRecoveryTakeID: "take-\(step)")
            ])
        case 3:
          if let victim = w.rows.randomElement(using: &rng) {
            for c in w.both { try? c.removeRow(id: victim.id) }
          }
        case 4:
          // Replaced under the same id, through the save path.
          if let old = w.rows.first(where: { !$0.isMeeting && $0.escapeRecoveredAt == nil }) {
            let new = Transcript(
              id: old.id, text: "replaced \(step) giraffe", createdAt: old.createdAt)
            for c in w.both { try? c.saveAndShow(new) }
          }
        case 5:
          // Bulk replacement: the same rows in a new order, one dropped.
          w.setRows(Array(w.rows.shuffled(using: &rng).dropFirst()))
        case 6:
          let record = Self.record(at: at, ready: Bool.random(using: &rng))
          w.sources.records.append(record)
          if Bool.random(using: &rng) {
            w.setRows(w.rows + [Self.meetingRow(record.id, words: "meeting \(step) zebra", at: at)])
          }
        case 7:
          // An orphan: a meeting row whose meeting EnviousMeet does not hold.
          let id = UUID()
          w.setRows(w.rows + [Self.meetingRow(id, words: "orphan \(step)", at: at)])
          if Bool.random(using: &rng) {
            w.sources.infoOverride[id] = MeetingHistoryInfo(echoTurnIDs: [], title: "Orphan zebra")
          }
        case 8:
          // A held meeting row (its notes still count in a search).
          if let record = w.sources.records.randomElement(using: &rng) {
            let row = Self.meetingRow(
              record.id, words: "held meeting \(step)", at: at,
              heldAt: w.time.addingTimeInterval(
                [-5, -retention + 2].randomElement(using: &rng)!))
            w.setRows(w.rows + [row])
          }
        case 9:
          if !w.sources.records.isEmpty {
            let i = Int.random(in: 0..<w.sources.records.count, using: &rng)
            w.sources.records[i].title = Bool.random(using: &rng) ? "Zebra sync" : nil
          }
        case 10:
          if !w.sources.records.isEmpty {
            let i = Int.random(in: 0..<w.sources.records.count, using: &rng)
            w.sources.records[i].deletionRequested.toggle()
          }
        case 11:
          if !w.sources.records.isEmpty {
            let i = Int.random(in: 0..<w.sources.records.count, using: &rng)
            w.sources.records[i].state = w.sources.records[i].state == .ready ? .processing : .ready
            w.sources.records[i].echoTurnIDs = Bool.random(using: &rng) ? ["t0"] : []
          }
        case 12:
          if let id = w.rows.compactMap(\.meetingID).randomElement(using: &rng) {
            w.sources.infoOverride[id] =
              Bool.random(using: &rng)
              ? MeetingHistoryInfo(echoTurnIDs: ["t0"], title: "Giraffe review") : nil
          }
        case 13:
          if let id = (w.sources.records.map(\.id) + w.rows.compactMap(\.meetingID))
            .randomElement(using: &rng)
          {
            w.sources.notes[id] = Bool.random(using: &rng) ? "ask about zebra" : "nothing"
          }
        case 14:
          if let row = w.rows.first(where: \.isMeeting) {
            let show = !w.cached.isShowingEcho(rowID: row.id)
            for c in w.both { c.setShowEcho(show, rowID: row.id) }
          }
        case 15:
          let filter = HistoryFilter.allCases.randomElement(using: &rng)!
          for c in w.both { c.historyFilter = filter }
        case 16:
          let query = ["", "zebra", "giraffe", "maria", "meeting"].randomElement(using: &rng)!
          for c in w.both { c.searchQuery = query }
        case 17:
          let pick = w.cached.listedItems.randomElement(using: &rng)?.id
          for c in w.both { c.selectedItemID = pick }
        case 18:
          // Deleting the selected row moves the selection to a neighbour of a warmed list.
          _ = w.cached.listedItems
          if case .transcript(let id)? = w.cached.selectedItemID {
            for c in w.both { try? c.removeRow(id: id) }
          }
        default:
          // Time passes without a pulse, across held rows' expiry and future-skew boundaries.
          w.time = w.time.addingTimeInterval([1, 20, 45, 61, 120].randomElement(using: &rng)!)
        }
        Self.expectAgree(w, "\(step)")
      }
    }

    @Test("a held row leaves the kept list exactly at its moment, without a pulse")
    func heldRowExpiresAtItsMoment() {
      let w = World()
      let stamp = w.time
      let held = Transcript(
        text: "held", createdAt: stamp, escapeRecoveredAt: stamp, escapeRecoveryTakeID: "take")
      w.setRows([held])
      let pulse = w.cached.expiryPulse
      let expiry = stamp.addingTimeInterval(AppConstants.pendingTranscriptRetention)
      w.time = expiry.addingTimeInterval(-0.001)
      #expect(w.cached.listedItems.map(\.id) == [.transcript(held.id)])
      Self.expectAgree(w, "just before")
      w.time = expiry
      #expect(w.cached.listedItems.isEmpty)
      Self.expectAgree(w, "at expiry")
      #expect(w.cached.expiryPulse == pulse, "no pulse ran")
    }

    @Test("a held row stamped in the future appears once the clock is within the skew tolerance")
    func futureStampCrossesTheSkewBoundary() {
      let w = World()
      let tolerance = AppConstants.pendingClockSkewTolerance
      let stamp = w.time.addingTimeInterval(tolerance + 1)
      let held = Transcript(
        text: "held", createdAt: w.time, escapeRecoveredAt: stamp, escapeRecoveryTakeID: "take")
      w.setRows([held])
      #expect(w.cached.listedItems.isEmpty, "a stamp past the tolerance is corrupt")
      Self.expectAgree(w, "corrupt")
      w.time = w.time.addingTimeInterval(1)
      #expect(w.cached.listedItems.map(\.id) == [.transcript(held.id)])
      Self.expectAgree(w, "within tolerance")
    }

    @Test("counts the kept list gives for orphans, marked meetings, held rows and repeated ids")
    func countsForEveryKind() {
      let w = World()
      let ready = Self.record(at: w.time, ready: true)
      var marked = Self.record(at: w.time, ready: true)
      marked.deletionRequested = true
      let rowless = Self.record(at: w.time, ready: false)
      let expiredOnly = Self.record(at: w.time, ready: true)
      w.sources.records = [ready, marked, rowless, rowless, expiredOnly]
      let orphan = UUID()
      w.setRows([
        Transcript(text: "a", createdAt: w.time),
        Transcript(
          text: "held", createdAt: w.time, escapeRecoveredAt: w.time, escapeRecoveryTakeID: "t"),
        Self.meetingRow(ready.id, words: "ready", at: w.time),
        Self.meetingRow(marked.id, words: "marked", at: w.time),
        Self.meetingRow(orphan, words: "orphan", at: w.time),
        // A meeting whose only row is a held row past its time: the meeting has no visible row.
        Self.meetingRow(
          expiredOnly.id, words: "expired", at: w.time,
          heldAt: w.time.addingTimeInterval(-AppConstants.pendingTranscriptRetention)),
      ])
      // Listed: a, held, ready, rowless (once per record), orphan, expiredOnly without its row;
      // the marked meeting is not.
      #expect(w.cached.listedItems.count == 7)
      #expect(w.cached.listedCount == 6, "the held row is not counted")
      // Every visible row (5) plus each unmarked record without a visible row (rowless twice,
      // expiredOnly once).
      #expect(w.cached.deletableCount == 8)
      Self.expectAgree(w, "counts")
    }

    @Test("a meeting whose notes start to match appears in the search")
    func notesBecomingAMatchAppear() {
      let w = World()
      let record = Self.record(at: w.time, ready: true)
      w.sources.records = [record]
      w.setRows([Self.meetingRow(record.id, words: "standup", at: w.time)])
      for c in w.both { c.searchQuery = "zebra" }
      #expect(w.cached.listedItems.isEmpty)
      w.sources.notes[record.id] = "ask about zebra"
      #expect(w.cached.listedItems.map(\.id) == [.meeting(record.id)])
      Self.expectAgree(w, "notes match")
    }

    /// After a kept answer, a `listedItems` read must be told about `change`.
    func expectObserved(_ name: String, _ w: World, change: () -> Void) {
      let c = w.cached
      _ = c.listedItems
      _ = c.listedItems  // the second read is a kept answer
      let fired = Flag()
      withObservationTracking {
        _ = c.listedItems
      } onChange: {
        fired.value = true
      }
      change()
      #expect(fired.value, "\(name) did not reach a reader of the kept list")
    }

    final class Flag: @unchecked Sendable { var value = false }

    @Test("a reader of the kept list is told about every input change")
    func everyInputIsObserved() throws {
      let w = World()
      let c = w.cached
      let record = Self.record(at: w.time, ready: true)
      let orphan = UUID()
      w.sources.records = [record]
      w.setRows([
        Transcript(text: "a", createdAt: w.time),
        Self.meetingRow(record.id, words: "standup", at: w.time),
        Self.meetingRow(orphan, words: "orphan", at: w.time),
      ])
      expectObserved("a saved row", w) { try? c.saveAndShow(Transcript(text: "new")) }
      let first = try #require(c.rawTranscriptsForTesting.first)
      expectObserved("a row replaced under its id", w) {
        try? c.saveAndShow(Transcript(id: first.id, text: "changed", createdAt: first.createdAt))
      }
      expectObserved("a bulk replacement", w) {
        c.setTranscriptsForTesting(c.rawTranscriptsForTesting.reversed())
      }
      expectObserved("the filter", w) { c.historyFilter = .dictations }
      c.historyFilter = .all
      expectObserved("the pulse", w) { c.bumpExpiryPulseForTesting() }
      expectObserved("an echo choice", w) { c.setShowEcho(true, rowID: UUID()) }
      expectObserved("a meeting record", w) { w.sources.records[0].title = "Zebra" }
      expectObserved("the search", w) { c.searchQuery = "zebra" }
      // While searching, each meeting's facts are watched, matching or not. The orphan's words,
      // title and speaker names do not match "zebra", so only its notes can make it a match.
      expectObserved("an orphan's info", w) {
        w.sources.infoOverride[orphan] = MeetingHistoryInfo(echoTurnIDs: [], title: "Giraffe")
      }
      #expect(!c.listedItems.contains { $0.id == .meeting(orphan) })
      expectObserved("unmatched notes", w) { w.sources.notes[orphan] = "zebra" }
      #expect(c.listedItems.contains { $0.id == .meeting(orphan) })
      expectObserved("a matched meeting's notes", w) { w.sources.notes[record.id] = "x" }
      let row = try #require(c.rawTranscriptsForTesting.first { !$0.isMeeting })
      expectObserved("a deletion", w) { try? c.removeRow(id: row.id) }
    }
  }

  /// A small deterministic generator (SplitMix64), so a failing step reproduces.
  struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }
#endif
