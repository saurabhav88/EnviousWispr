#if DEBUG
  import EnviousWisprCore
  import Foundation
  import Observation
  import Testing

  @testable import EnviousWisprAppKit
  @testable import EnviousWisprStorage
  import EnviousWisprAppKitTestSupport

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
          let dir = TestTemporaryDirectory.url
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
    func keptListMatchesNeverKept() async {
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
            for c in w.both { try? await c.removeRow(id: victim.id) }
            // #4075 S1: each command now suspends, so both lists settle their post-removal
            // refresh before they are compared.
            for c in w.both { await c.waitForRefreshForTesting() }
          }
        case 4:
          // Replaced under the same id, through the save path.
          if let old = w.rows.first(where: { !$0.isMeeting && $0.escapeRecoveredAt == nil }) {
            let new = Transcript(
              id: old.id, text: "replaced \(step) giraffe", createdAt: old.createdAt)
            for c in w.both { try? await c.saveAndShow(new) }
            // #4075 S1: each command now suspends, so both lists settle their post-removal
            // refresh before they are compared.
            for c in w.both { await c.waitForRefreshForTesting() }
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
            for c in w.both { try? await c.removeRow(id: id) }
            // #4075 S1: each command now suspends, so both lists settle their post-removal
            // refresh before they are compared.
            for c in w.both { await c.waitForRefreshForTesting() }
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

    /// #4075 S1: the same check for a change made by an awaited History command.
    func expectObserved(_ name: String, _ w: World, change: () async -> Void) async {
      let c = w.cached
      _ = c.listedItems
      _ = c.listedItems  // the second read is a kept answer
      let fired = Flag()
      withObservationTracking {
        _ = c.listedItems
      } onChange: {
        fired.value = true
      }
      await change()
      #expect(fired.value, "\(name) did not reach a reader of the kept list")
    }

    final class Flag: @unchecked Sendable { var value = false }

    @Test("a reader of the kept list is told about every input change")
    func everyInputIsObserved() async throws {
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
      await expectObserved("a saved row", w) { try? await c.saveAndShow(Transcript(text: "new")) }
      let first = try #require(c.rawTranscriptsForTesting.first)
      await expectObserved("a row replaced under its id", w) {
        try? await c.saveAndShow(Transcript(id: first.id, text: "changed", createdAt: first.createdAt))
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
      await expectObserved("a deletion", w) { try? await c.removeRow(id: row.id) }
    }

    // MARK: - Meeting preview text (#4001 step 2a)

    /// A two-turn meeting row: turn t0 is Maria's, t1 is yours.
    static func twoTurnRow(
      _ meetingID: UUID, at: Date, first: String = "Ship it Friday.",
      second: String = "Agreed."
    ) -> Transcript {
      let text = first + "\n" + second
      let split = first.utf16.count
      return Transcript(
        text: text, backendType: .parakeet, createdAt: at,
        speakerAnalysis: .labeled(count: 2), speakerNames: ["sys:S1": "Maria"],
        turns: [
          Turn(
            id: "t0", speakerId: "sys:S1", startMs: 0, endMs: 1_000,
            originalTextRange: 0..<split),
          Turn(
            id: "t1", speakerId: "mic:you", startMs: 1_000, endMs: 2_000,
            originalTextRange: (split + 1)..<text.utf16.count),
        ], meetingID: meetingID)
    }

    /// The preview the row showed before step 2a: the whole projection, cut to its preview.
    static func projectedPreview(_ c: TranscriptCoordinator, _ row: Transcript) -> String {
      MeetingHistoryPresentation.previewText(c.meetingProjection(of: row))
    }

    static func expectPreviewAgrees(_ w: World, _ row: Transcript, _ step: String) {
      let expected = projectedPreview(w.reference, row)
      #expect(w.cached.meetingPreviewText(of: row) == expected, "cached, \(step)")
      #expect(w.reference.meetingPreviewText(of: row) == expected, "reference, \(step)")
      #expect(
        projectedPreview(w.cached, row) == expected, "both coordinators project alike, \(step)")
    }

    @Test("a meeting preview is the projection's preview for every kind of meeting")
    func previewMatchesTheProjectionForEveryKind() {
      let w = World()
      var visible = Self.record(at: w.time, ready: true)
      visible.title = "Visible"
      var mixed = Self.record(at: w.time, ready: true)
      mixed.echoTurnIDs = ["t0"]
      var hidden = Self.record(at: w.time, ready: true)
      hidden.echoTurnIDs = ["t0", "t1"]
      let unavailable = Self.record(at: w.time, ready: false)
      let empty = Self.record(at: w.time, ready: true)
      w.sources.records = [visible, mixed, hidden, unavailable, empty]
      let rows = [
        Self.twoTurnRow(visible.id, at: w.time), Self.twoTurnRow(mixed.id, at: w.time),
        Self.twoTurnRow(hidden.id, at: w.time), Self.twoTurnRow(unavailable.id, at: w.time),
        Transcript(
          text: "", backendType: .parakeet, createdAt: w.time, speakerAnalysis: .labeled(count: 0),
          turns: [], meetingID: empty.id),
        Self.twoTurnRow(UUID(), at: w.time),  // an orphan with no info
        Transcript(text: "a dictation", createdAt: w.time),  // not a meeting
      ]
      w.setRows(rows)
      for (i, row) in rows.enumerated() { Self.expectPreviewAgrees(w, row, "kind \(i)") }
      #expect(w.cached.meetingPreviewText(of: rows[0]).contains("Ship it Friday."))
      #expect(!w.cached.meetingPreviewText(of: rows[1]).contains("Ship it Friday."))
      #expect(
        w.cached.meetingPreviewText(of: rows[2])
          == MeetingHistoryPresentation.everythingHiddenMessage)
      #expect(
        w.cached.meetingPreviewText(of: rows[3]) == MeetingHistoryPresentation.unavailableMessage)
      #expect(
        w.cached.meetingPreviewText(of: rows[6]) == MeetingHistoryPresentation.unavailableMessage)
    }

    @Test("the meeting detail shares kept text and preserves the direct projection (#4075)")
    func detailProjectionReusesKeptText() {
      let w = World()
      let c = w.cached
      var record = Self.record(at: w.time, ready: true)
      w.sources.records = [record]
      let row = Self.twoTurnRow(
        record.id, at: w.time,
        first: "[Could not transcribe 1:00 to 1:30]",
        second: "[Could not transcribe from 2:00]")
      w.setRows([row])

      func check(_ row: Transcript) {
        let info = row.meetingID.flatMap { c.meetingInfo?($0) }
        let expected = MeetingHistoryPresentation.project(
          row, info: info, showEcho: c.isShowingEcho(rowID: row.id))
        let actual = c.meetingProjection(of: row)
        #expect(actual == expected)
        if case .visible(_, let actualText) = actual,
          case .visible(_, let expectedText) = expected
        {
          #expect(Array(actualText.utf8) == Array(expectedText.utf8))
        }
      }

      // A cold detail must populate the shared cache. The old direct call
      // leaves this counter unchanged and fails this assertion.
      let before = c.meetingTextBuildsForTesting
      check(row)
      #expect(c.meetingTextBuildsForTesting == before + 1)
      let built = c.meetingTextBuildsForTesting
      _ = c.meetingPreviewText(of: row)
      check(row)
      #expect(c.meetingTextBuildsForTesting == built)

      record.echoTurnIDs = ["t0"]
      w.sources.records = [record]
      check(row)

      record.echoTurnIDs = ["t0", "t1"]
      w.sources.records = [record]
      check(row)

      c.setShowEcho(true, rowID: row.id)
      check(row)
      c.setShowEcho(false, rowID: row.id)
      check(row)

      let empty = Transcript(
        text: "", backendType: .parakeet, createdAt: w.time,
        turns: [], meetingID: record.id)
      check(empty)

      record.state = .processing
      w.sources.records = [record]
      check(row)
      check(Transcript(text: "ordinary"))
    }

    @Test("the meeting detail never reuses byte-distinct speaker names (#4075)")
    func detailProjectionFollowsNameBytes() {
      let w = World()
      let c = w.cached
      let record = Self.record(at: w.time, ready: true)
      w.sources.records = [record]
      let base = Self.twoTurnRow(record.id, at: w.time)

      func named(_ name: String) -> Transcript {
        Transcript(
          id: base.id, text: base.text, backendType: .parakeet,
          createdAt: base.createdAt, speakerAnalysis: base.speakerAnalysis,
          speakerNames: ["sys:S1": name], turns: base.turns,
          meetingID: record.id)
      }

      let first = named("Ren\u{00E9}e")
      w.setRows([first])
      _ = c.meetingProjection(of: first)
      let built = c.meetingTextBuildsForTesting

      let replaced = named("Rene\u{0301}e")
      #expect(first.speakerNames == replaced.speakerNames)
      w.setRows([replaced])
      let actual = c.meetingProjection(of: replaced)
      let expected = MeetingHistoryPresentation.project(
        replaced, info: c.meetingInfo?(record.id), showEcho: false)
      #expect(c.meetingTextBuildsForTesting == built + 1)
      if case .visible(_, let actualText) = actual,
        case .visible(_, let expectedText) = expected
      {
        #expect(Array(actualText.utf8) == Array(expectedText.utf8))
      } else {
        Issue.record("Expected both projections to be visible")
      }
    }

    @Test("search and the preview share one kept entry, whichever reads first")
    func searchAndPreviewShareOneEntry() {
      for searchFirst in [true, false] {
        let w = World()
        let c = w.cached
        let record = Self.record(at: w.time, ready: true)
        w.sources.records = [record]
        let row = Self.twoTurnRow(record.id, at: w.time)
        w.setRows([row])
        func search() {
          c.searchQuery = "friday"
          _ = c.listedItems
          c.searchQuery = ""
        }
        if searchFirst { search() } else { _ = c.meetingPreviewText(of: row) }
        let built = c.meetingTextBuildsForTesting
        #expect(built == 1, "searchFirst \(searchFirst): one projection for the first read")
        if searchFirst { _ = c.meetingPreviewText(of: row) } else { search() }
        #expect(c.meetingTextBuildsForTesting == built, "searchFirst \(searchFirst): reused")
        // Hidden and unavailable meetings never match a search on their hidden words.
        w.sources.infoOverride[record.id] = MeetingHistoryInfo(echoTurnIDs: ["t0", "t1"])
        c.searchQuery = "friday"
        #expect(c.listedItems.isEmpty, "searchFirst \(searchFirst): hidden words do not match")
        c.searchQuery = ""
      }
    }

    @Test("each projection input changes the preview exactly as the projection does")
    func everyInputChangesThePreview() {
      let w = World()
      var record = Self.record(at: w.time, ready: true)
      w.sources.records = [record]
      var row = Self.twoTurnRow(record.id, at: w.time)
      w.setRows([row])
      Self.expectPreviewAgrees(w, row, "start")
      let first = w.cached.meetingPreviewText(of: row)
      // Raw text, with the same id.
      row = Self.twoTurnRow(record.id, at: w.time, first: "Ship it Monday.")
      row = Transcript(
        id: w.rows[0].id, text: row.text, backendType: .parakeet, createdAt: row.createdAt,
        speakerAnalysis: row.speakerAnalysis, speakerNames: row.speakerNames, turns: row.turns,
        meetingID: record.id)
      w.setRows([row])
      Self.expectPreviewAgrees(w, row, "raw text")
      #expect(w.cached.meetingPreviewText(of: row) != first)
      // Turn ranges: t0 now covers less of the text.
      let ranged = Transcript(
        id: row.id, text: row.text, backendType: .parakeet, createdAt: row.createdAt,
        speakerAnalysis: row.speakerAnalysis, speakerNames: row.speakerNames,
        turns: [
          Turn(id: "t0", speakerId: "sys:S1", startMs: 0, endMs: 1_000, originalTextRange: 0..<4),
          row.turns![1],
        ], meetingID: record.id)
      w.setRows([ranged])
      Self.expectPreviewAgrees(w, ranged, "turn ranges")
      // Speaker names.
      let renamed = Transcript(
        id: row.id, text: ranged.text, backendType: .parakeet, createdAt: row.createdAt,
        speakerAnalysis: row.speakerAnalysis, speakerNames: ["sys:S1": "Zach"],
        turns: ranged.turns, meetingID: record.id)
      w.setRows([renamed])
      Self.expectPreviewAgrees(w, renamed, "speaker names")
      #expect(w.cached.meetingPreviewText(of: renamed).contains("Zach"))
      // Echo IDs from the record, then the echo choice shows them again.
      record.echoTurnIDs = ["t0"]
      w.sources.records = [record]
      Self.expectPreviewAgrees(w, renamed, "echo IDs")
      for c in w.both { c.setShowEcho(true, rowID: renamed.id) }
      Self.expectPreviewAgrees(w, renamed, "echo shown")
      // Info availability: the meeting stops being ready.
      record.state = .processing
      w.sources.records = [record]
      Self.expectPreviewAgrees(w, renamed, "info unavailable")
      #expect(
        w.cached.meetingPreviewText(of: renamed) == MeetingHistoryPresentation.unavailableMessage)
    }

    @Test("a kept preview still tells its reader about the echo choice and the meeting info")
    func previewReadersAreTold() {
      let w = World()
      let c = w.cached
      var record = Self.record(at: w.time, ready: true)
      w.sources.records = [record]
      let row = Self.twoTurnRow(record.id, at: w.time)
      w.setRows([row])
      func expectToldAbout(_ name: String, change: () -> Void) {
        _ = c.meetingPreviewText(of: row)
        let built = c.meetingTextBuildsForTesting
        let fired = Flag()
        withObservationTracking {
          _ = c.meetingPreviewText(of: row)
        } onChange: {
          fired.value = true
        }
        #expect(c.meetingTextBuildsForTesting == built, "\(name): the tracked read was a kept one")
        change()
        #expect(fired.value, "\(name) did not reach a reader of a kept preview")
      }
      expectToldAbout("the echo choice") { c.setShowEcho(true, rowID: row.id) }
      expectToldAbout("the meeting record") {
        record.echoTurnIDs = ["t1"]
        w.sources.records = [record]
      }
      expectToldAbout("an info override") {
        w.sources.infoOverride[record.id] = MeetingHistoryInfo(echoTurnIDs: [], title: "New")
      }
    }

    // MARK: - Summary text (#4001 step 2b-C)

    static func directSummaryText(_ c: TranscriptCoordinator, _ row: Transcript) -> String? {
      guard let id = row.meetingID,
        case .visible(_, let text) = MeetingHistoryPresentation.project(
          row, info: c.meetingInfo?(id), showEcho: false), !text.isEmpty
      else { return nil }
      return text
    }

    @Test("the summary text is the echo-hidden projection for every kind, whatever echo is shown")
    func summaryTextMatchesTheEchoHiddenProjection() {
      let w = World()
      var visible = Self.record(at: w.time, ready: true)
      visible.echoTurnIDs = ["t0"]
      var hidden = Self.record(at: w.time, ready: true)
      hidden.echoTurnIDs = ["t0", "t1"]
      let unavailable = Self.record(at: w.time, ready: false)
      w.sources.records = [visible, hidden, unavailable]
      let rows = [
        Self.twoTurnRow(visible.id, at: w.time), Self.twoTurnRow(hidden.id, at: w.time),
        Self.twoTurnRow(unavailable.id, at: w.time),
        Transcript(text: "a dictation", createdAt: w.time),
      ]
      w.setRows(rows)
      for show in [false, true] {
        for c in w.both { for row in rows { c.setShowEcho(show, rowID: row.id) } }
        for (i, row) in rows.enumerated() {
          let info = row.meetingID.flatMap { w.cached.meetingInfo?($0) }
          let expected = Self.directSummaryText(w.reference, row)
          #expect(
            w.cached.summaryVisibleText(of: row, info: info) == expected, "row \(i) show \(show)")
          #expect(w.reference.summaryVisibleText(of: row, info: info) == expected)
        }
      }
      #expect(
        w.cached.summaryVisibleText(of: rows[0], info: w.cached.meetingInfo?(visible.id))?
          .contains("Ship it Friday.") == false, "echo stays hidden for the summary")
    }

    @Test("a byte-distinct but equal-looking speaker name is projected again, never reused")
    func summaryTextFollowsBytes() {
      let w = World()
      let c = w.cached
      let record = Self.record(at: w.time, ready: true)
      w.sources.records = [record]
      // Only the name's bytes differ: the words and turn ranges stay identical, so the
      // projection inputs compare equal under == and only the byte check tells them apart.
      func row(named name: String, id: UUID) -> Transcript {
        let base = Self.twoTurnRow(record.id, at: w.time)
        return Transcript(
          id: id, text: base.text, backendType: .parakeet, createdAt: base.createdAt,
          speakerAnalysis: base.speakerAnalysis, speakerNames: ["sys:S1": name],
          turns: base.turns, meetingID: record.id)
      }
      let id = UUID()
      let first = row(named: "Ren\u{00E9}e", id: id)
      w.setRows([first])
      let info = c.meetingInfo?(record.id)
      let a = c.summaryVisibleText(of: first, info: info)
      let built = c.meetingTextBuildsForTesting
      _ = c.summaryVisibleText(of: first, info: info)
      #expect(c.meetingTextBuildsForTesting == built, "the same bytes reuse the kept text")
      let replaced = row(named: "Rene\u{0301}e", id: id)
      #expect(replaced.speakerNames == first.speakerNames, "equal to ==")
      w.setRows([replaced])
      let b = c.summaryVisibleText(of: replaced, info: info)
      #expect(c.meetingTextBuildsForTesting == built + 1, "different bytes are projected again")
      #expect(a == b, "they look the same to ==")
      #expect(
        b.map { Array($0.utf8) }
          == Self.directSummaryText(w.reference, replaced).map { Array($0.utf8) },
        "and the kept text has the new bytes")
    }

    @Test("the summary-only cache is pruned with the list even when search kept nothing")
    func summaryCacheIsPruned() {
      let w = World()
      let c = w.cached
      let record = Self.record(at: w.time, ready: true)
      w.sources.records = [record]
      let row = Self.twoTurnRow(record.id, at: w.time)
      w.setRows([row])
      let info = c.meetingInfo?(record.id)
      _ = c.summaryVisibleText(of: row, info: info)
      let built = c.meetingTextBuildsForTesting
      w.setRows([])
      _ = c.listedItems  // a rebuild prunes
      w.setRows([row])
      _ = c.summaryVisibleText(of: row, info: info)
      #expect(c.meetingTextBuildsForTesting == built + 1, "the removed row's kept text was dropped")
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
