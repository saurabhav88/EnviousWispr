#if DEBUG
  import EnviousWisprCore
  import Foundation
  import Observation
  import Testing

  @testable import EnviousWisprAppKit
  @testable import EnviousWisprStorage
  import EnviousWisprAppKitTestSupport

  /// #4001, #4586: when these fail, History lists the wrong held, marked, rowless or searched
  /// meetings and rows, or a meeting's preview and summary text disagree with the projection or
  /// are kept for rows that are gone.
  @MainActor
  @Suite("History kept list", .tags(.productOutcome, .localParallel))
  struct TranscriptCoordinatorListCacheTests {

    /// What the coordinators read from EnviousMeet and the notes owner. Observable on its own,
    /// so a missing subscription to one source is not masked by another.
    @MainActor @Observable
    final class Sources {
      var records: [MeetingRecord] = []
      /// Info that differs from what the record would give (an orphan's, or a stale pairing).
      var infoOverride: [UUID: MeetingHistoryInfo] = [:]
      var notes: [UUID: String] = [:]
      /// #4286: each meeting's invited search terms.
      var invited: [UUID: [String]] = [:]
    }

    /// One coordinator fed the meeting sources the tests change, as History reads them.
    @MainActor
    final class World {
      let sources = Sources()
      var time = Date(timeIntervalSinceReferenceDate: 800_000_000)
      let cached: TranscriptCoordinator

      init() {
        let dir = TestTemporaryDirectory.url
          .appendingPathComponent("ew-4001-cache-\(UUID().uuidString)", isDirectory: true)
        // No pulse ever runs: a pulse sweeps with the wall clock, not `time`.
        cached = TranscriptCoordinator(
          store: TranscriptStore(directory: dir),
          // test-fixture-timer: a pulse sleep that never ends, so no pulse runs in these tests
          pendingPulseSleep: { _ in try? await Task.sleep(for: .seconds(86_400)) })
        let c = cached
        c.clock = { [unowned self] in time }
        c.meetingRecords = { [unowned self] in sources.records }
        c.meetingInfo = { [unowned self] id in
          sources.infoOverride[id]
            ?? sources.records.first { $0.id == id }.flatMap { MeetingHistoryInfo.paired(with: $0) }
        }
        c.meetingNotes = { [unowned self] in sources.notes[$0] }
        c.meetingInvited = { [unowned self] in sources.invited[$0] ?? [] }
      }

      func setRows(_ rows: [Transcript]) { cached.setTranscriptsForTesting(rows) }
      var rows: [Transcript] { cached.rawTranscriptsForTesting }
    }

    final class Flag: @unchecked Sendable { var value = false }

    /// A clock a catalog test moves by hand.
    @MainActor
    final class TestClock {
      var now: Date
      init(_ now: Date) { self.now = now }
    }

    /// The production History path (#4586): `records` become real meeting folders, `rows` and
    /// `pending` real transcript files, a catalog indexes them, and the coordinator reads the
    /// same records through `sources` as the EnviousMeet wiring gives them. `prepare` writes more
    /// into the meeting store before indexing starts.
    static func catalogRig(
      records: [MeetingRecord] = [], rows: [Transcript] = [], pending: [Transcript] = [],
      sources: Sources = Sources(), clock: TestClock? = nil,
      prepare: (MeetingStore) throws -> Void = { _ in }
    ) async throws -> HistoryCatalogRig {
      sources.records = records
      return try await HistoryCatalogRig.make(rows: rows, pending: pending) { coordinator, store in
        for record in records { try store.create(record) }
        try prepare(store)
        if let clock { coordinator.clock = { clock.now } }
        coordinator.meetingRecords = { sources.records }
        coordinator.meetingRecord = { id in sources.records.first { $0.id == id } }
        coordinator.meetingInfo = { id in
          sources.records.first { $0.id == id }.flatMap { MeetingHistoryInfo.paired(with: $0) }
        }
      }
    }

    static func attendee(_ name: String?, _ email: String?, at: Date) -> MeetingFact {
      AttendeeFact(
        name: name, email: email, role: .required, status: .accepted, isSelf: false,
        isOrganizer: false
      ).fact(source: MeetingFact.eventKitSource, capturedAt: at)
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

    @Test("a held row leaves the list exactly at its moment, without a pulse")
    func heldRowExpiresAtItsMoment() async throws {
      let stamp = Date()
      let held = Transcript(
        text: "held", createdAt: stamp, escapeRecoveredAt: stamp, escapeRecoveryTakeID: "take")
      let time = TestClock(stamp)
      let rig = try await Self.catalogRig(pending: [held], clock: time)
      defer { rig.remove() }
      let pulse = rig.coordinator.expiryPulse
      let expiry = stamp.addingTimeInterval(AppConstants.pendingTranscriptRetention)
      time.now = expiry.addingTimeInterval(-0.001)
      #expect(await rig.listedRowIDs(.dictations) == [held.id], "just before")
      time.now = expiry
      #expect(await rig.listedRowIDs(.dictations).isEmpty, "at expiry")
      #expect(rig.coordinator.expiryPulse == pulse, "no pulse ran")
    }

    // #4586 C: the old "appears once the clock is within the skew tolerance" half cannot be
    // staged. The catalog admits a pending row once, at index time, against the wall clock, so a
    // moved test clock never re-admits a corrupt stamp. The corrupt half and the tolerance edge
    // are kept; the rule itself is Core/PendingAdmissionTests.
    @Test("a held row stamped past the skew tolerance is corrupt and never listed; within it, it is")
    func futureStampIsCorruptPastTheTolerance() async throws {
      let now = Date()
      let tolerance = AppConstants.pendingClockSkewTolerance
      let corrupt = Transcript(
        text: "corrupt", createdAt: now, escapeRecoveredAt: now.addingTimeInterval(tolerance + 30),
        escapeRecoveryTakeID: "take-corrupt")
      let early = Transcript(
        text: "early", createdAt: now, escapeRecoveredAt: now.addingTimeInterval(tolerance / 2),
        escapeRecoveryTakeID: "take-early")
      let ordinary = Transcript(text: "ordinary", createdAt: now)
      let rig = try await Self.catalogRig(rows: [ordinary], pending: [corrupt, early])
      defer { rig.remove() }
      let listed = Set(await rig.listedRowIDs(.dictations))
      #expect(listed.contains(corrupt.id) == false, "a stamp past the tolerance is corrupt")
      #expect(listed == [ordinary.id, early.id], "a stamp within the tolerance is listed")
    }

    @Test("what History lists for orphans, marked meetings, held rows and meetings with no row")
    func countsForEveryKind() async throws {
      let now = Date()
      let ready = Self.record(at: now, ready: true)
      var marked = Self.record(at: now, ready: true)
      marked.deletionRequested = true
      let rowless = Self.record(at: now, ready: false)
      let orphan = UUID()
      let dictation = Transcript(text: "a", createdAt: now)
      let held = Transcript(
        text: "held", createdAt: now, escapeRecoveredAt: now, escapeRecoveryTakeID: "t")
      let rig = try await Self.catalogRig(
        records: [ready, marked, rowless],
        rows: [
          dictation,
          Self.meetingRow(ready.id, rowID: ready.transcriptID, words: "ready", at: now),
          Self.meetingRow(marked.id, rowID: marked.transcriptID, words: "marked", at: now),
          Self.meetingRow(orphan, words: "orphan", at: now),
        ], pending: [held])
      defer { rig.remove() }
      #expect(Set(await rig.listedRowIDs(.dictations)) == [dictation.id, held.id])
      #expect(await rig.listedIDs(.transcripts).isEmpty)
      // The marked meeting is not listed, not even as its row; the meeting with no row is.
      #expect(
        Set(await rig.listedIDs(.meetings))
          == [.meeting(ready.id), .meeting(rowless.id), .meeting(orphan)])
      #expect(await rig.listedIDs(.meetings).count == 3, "each meeting is one item")
    }

    @Test("a meeting whose notes start to match appears in the search")
    func notesBecomingAMatchAppear() async throws {
      let at = Date()
      let record = Self.record(at: at, ready: true)
      let rig = try await Self.catalogRig(
        records: [record],
        rows: [Self.meetingRow(record.id, rowID: record.transcriptID, words: "standup", at: at)])
      defer { rig.remove() }
      rig.coordinator.setHistoryQuery("zebra", in: .meetings)
      #expect(await rig.listedIDs(.meetings).isEmpty)
      try await rig.applying {
        try Data("ask about zebra".utf8).write(
          to: rig.meetings.notesURL(for: record.id), options: .atomic)
        // Saving the record again is the change notice the catalog re-reads the folder on.
        try rig.meetings.save(record)
      }
      #expect(await rig.listedIDs(.meetings) == [.meeting(record.id)])
    }

    // #4586 C: invited people are saved as appended facts, so the old "changed list no longer
    // matches" and "removed terms no longer match" halves cannot exist on disk; a new person
    // added later is the update that can.
    @Test("#4286: a meeting found only by its invited people appears and picks up added people")
    func invitedTermsMatch() async throws {
      let at = Date()
      let record = Self.record(at: at, ready: true)
      let rig = try await Self.catalogRig(
        records: [record],
        rows: [Self.meetingRow(record.id, rowID: record.transcriptID, words: "standup", at: at)])
      defer { rig.remove() }
      rig.coordinator.setHistoryQuery("ACME", in: .meetings)
      #expect(await rig.listedIDs(.meetings).isEmpty)
      try await rig.applying {
        try rig.meetings.appendFacts(
          [Self.attendee("Dana Lee", "dana@acme.com", at: at)], meeting: record.id)
      }
      #expect(await rig.listedIDs(.meetings) == [.meeting(record.id)], "case-insensitive substring")
      rig.coordinator.setHistoryQuery("li wu", in: .meetings)
      #expect(await rig.listedIDs(.meetings).isEmpty)
      try await rig.applying {
        try rig.meetings.appendFacts(
          [Self.attendee("Li Wu", "li@other.org", at: at)], meeting: record.id)
      }
      #expect(await rig.listedIDs(.meetings) == [.meeting(record.id)])
    }

    @Test("#4286: invited people never make an unfinished or withheld meeting a match")
    func invitedRespectsFences() async throws {
      let at = Date()
      let processing = Self.record(at: at, ready: false)
      let withheld = Self.record(at: at, ready: true)
      let control = Self.record(at: at, ready: true)
      let sources = Sources()
      let rig = try await Self.catalogRig(
        records: [processing, withheld, control],
        rows: [processing, withheld, control].map {
          Self.meetingRow($0.id, rowID: $0.transcriptID, words: "standup", at: at)
        }, sources: sources
      ) { store in
        for record in [processing, withheld, control] {
          try store.appendFacts([Self.attendee("Dana", "dana@acme.com", at: at)], meeting: record.id)
        }
        // The deletion mark lands after the facts: a marked meeting refuses new facts.
        var marked = withheld
        marked.deletionRequested = true
        try store.save(marked)
        sources.records = [processing, marked, control]
      }
      defer { rig.remove() }
      rig.coordinator.setHistoryQuery("acme", in: .meetings)
      let listed = await rig.listedIDs(.meetings)
      #expect(listed == [.meeting(control.id)], "only the finished, unmarked meeting matches")
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
      // The pure projection, read straight from the sources: never the kept meeting text.
      guard let meetingID = row.meetingID else {
        return MeetingHistoryPresentation.unavailableMessage
      }
      return MeetingHistoryPresentation.previewText(
        MeetingHistoryPresentation.project(
          row, info: c.meetingInfo?(meetingID), showEcho: c.isShowingEcho(rowID: row.id)))
    }

    static func expectPreviewAgrees(_ w: World, _ row: Transcript, _ step: String) {
      #expect(w.cached.meetingPreviewText(of: row) == projectedPreview(w.cached, row), "\(step)")
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
      let before = c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting
      check(row)
      #expect(c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting == before + 1)
      let built = c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting
      _ = c.meetingPreviewText(of: row)
      check(row)
      #expect(c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting == built)

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
      let built = c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting

      let replaced = named("Rene\u{0301}e")
      #expect(first.speakerNames == replaced.speakerNames)
      w.setRows([replaced])
      let actual = c.meetingProjection(of: replaced)
      let expected = MeetingHistoryPresentation.project(
        replaced, info: c.meetingInfo?(record.id), showEcho: false)
      #expect(c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting == built + 1)
      if case .visible(_, let actualText) = actual,
        case .visible(_, let expectedText) = expected
      {
        #expect(Array(actualText.utf8) == Array(expectedText.utf8))
      } else {
        Issue.record("Expected both projections to be visible")
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
      w.cached.setShowEcho(true, rowID: renamed.id)
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
        let built = c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting
        let fired = Flag()
        withObservationTracking {
          _ = c.meetingPreviewText(of: row)
        } onChange: {
          fired.value = true
        }
        #expect(
          c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting == built,
          "\(name): the tracked read was a kept one")
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
        for row in rows { w.cached.setShowEcho(show, rowID: row.id) }
        for (i, row) in rows.enumerated() {
          let info = row.meetingID.flatMap { w.cached.meetingInfo?($0) }
          let expected = Self.directSummaryText(w.cached, row)
          #expect(
            w.cached.summaryVisibleText(of: row, info: info) == expected, "row \(i) show \(show)")
        }
      }
      #expect(
        w.cached.summaryVisibleText(of: rows[0], info: w.cached.meetingInfo?(visible.id))?
          .contains("Ship it Friday.") == false, "echo stays hidden for the summary")
    }

    @Test("#4148: summary emptiness tells visible words, empty, all hidden and unavailable apart")
    func summaryEmptiness() {
      let w = World()
      let record = Self.record(at: w.time, ready: true)
      let row = Self.twoTurnRow(record.id, at: w.time)
      let empty = Transcript(text: "", createdAt: w.time, meetingID: record.id)
      let cases: [(Transcript, MeetingHistoryInfo?, Bool)] = [
        (row, .init(echoTurnIDs: []), false),
        (empty, .init(echoTurnIDs: []), true),
        (row, .init(echoTurnIDs: ["t0", "t1"]), true),
        (empty, nil, false),
      ]
      let c = w.cached
      let counter = { c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting }
      for (i, (r, info, noWords)) in cases.enumerated() {
        #expect(c.summaryHasNoWords(of: r, info: info) == noWords, "case \(i)")
        let built = counter()
        // The same inputs again: answered from the kept text.
        #expect(c.summaryHasNoWords(of: r, info: info) == noWords, "case \(i) again")
        #expect(counter() == built, "case \(i) reuse")
      }
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
      let built = c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting
      _ = c.summaryVisibleText(of: first, info: info)
      #expect(
        c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting == built,
        "the same bytes reuse the kept text")
      let replaced = row(named: "Rene\u{0301}e", id: id)
      #expect(replaced.speakerNames == first.speakerNames, "equal to ==")
      w.setRows([replaced])
      let b = c.summaryVisibleText(of: replaced, info: info)
      #expect(
        c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting == built + 1,
        "different bytes are projected again")
      #expect(a == b, "they look the same to ==")
      #expect(
        b.map { Array($0.utf8) }
          == Self.directSummaryText(w.cached, replaced).map { Array($0.utf8) },
        "and the kept text has the new bytes")
    }

    @Test("the meeting-text cache follows live rows: a removed or replaced row's kept text is dropped")
    func meetingTextIsPrunedWithLiveRows() {
      for replacement in [[], [Transcript(text: "another", createdAt: Date())]] {
        let w = World()
        let c = w.cached
        let record = Self.record(at: w.time, ready: true)
        w.sources.records = [record]
        let row = Self.twoTurnRow(record.id, at: w.time)
        w.setRows([row])
        let info = c.meetingInfo?(record.id)
        _ = c.summaryVisibleText(of: row, info: info)
        _ = c.meetingPreviewText(of: row)
        let built = c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting
        w.setRows(replacement)  // the row leaves the live list: the pruning trigger
        w.setRows([row])
        _ = c.summaryVisibleText(of: row, info: info)
        #expect(
          c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting == built + 1,
          "the removed row's kept summary text was dropped (replacement of \(replacement.count))")
        _ = c.meetingPreviewText(of: row)
        #expect(
          c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting == built + 2,
          "the removed row's kept preview text was dropped (replacement of \(replacement.count))")
      }
    }

    // #4586 C: the old test pruned through the in-memory browse. Production prunes when live rows
    // change (above) and when hydrated detail payloads leave the cache (here).
    @Test("a hydrated detail payload leaving the cache drops its meeting text; payload rows stay")
    func meetingTextIsPrunedWhenPayloadsLeave() async throws {
      let at = Date()
      let a = Self.twoTurnRow(UUID(), at: at)
      let b = Self.twoTurnRow(UUID(), at: at)
      let neither = Self.twoTurnRow(UUID(), at: at)  // never saved, never live, never hydrated
      let rig = try await Self.catalogRig(rows: [a, b])
      defer { rig.remove() }
      let c = rig.coordinator
      let info = MeetingHistoryInfo(echoTurnIDs: [])
      let hydratedA = try #require(await c.loadCatalogDetail(a.id, authoritative: true))
      let hydratedB = try #require(await c.loadCatalogDetail(b.id, authoritative: true))
      for row in [hydratedA, hydratedB, neither] { _ = c.summaryVisibleText(of: row, info: info) }
      let built = c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting
      #expect(built == 3)

      // A's payload is evicted by its removal (`detailCache.clear`), which prunes the text.
      try await c.removeRow(id: a.id)
      _ = c.summaryVisibleText(of: hydratedB, info: info)
      #expect(
        c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting == built,
        "a row whose payload is still held keeps its text")
      _ = c.summaryVisibleText(of: hydratedA, info: info)
      #expect(
        c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting == built + 1,
        "the evicted payload's text was dropped")
      _ = c.summaryVisibleText(of: neither, info: info)
      #expect(
        c.meetingDocumentCacheForTesting.meetingTextBuildsForTesting == built + 2,
        "a row that is neither live nor hydrated keeps no text")
    }
  }
#endif