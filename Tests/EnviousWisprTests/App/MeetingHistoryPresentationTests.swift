import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices
@testable import EnviousWisprStorage
import EnviousWisprAppKitTestSupport

/// #3972 R5, R19: when these fail, a meeting is filed as a dictation, pasted again as "the last
/// dictation", counted as a practice dictation, or hidden echo lines reach the list, search,
/// Copy, Save, Share or Paste.
@MainActor
@Suite("Meeting rows in History", .tags(.productOutcome, .localParallel))
struct MeetingHistoryPresentationTests {
  /// "Hello there." (You, 0..<12), then "Hello there." again on the mic (echo, 13..<25),
  /// then "Yes, I agree." (Speaker 1, 26..<39).
  static let text = "Hello there. Hello there. Yes, I agree."

  static func meetingRow(
    id: UUID = UUID(), meetingID: UUID = UUID(), text: String = text, attemptID: UUID? = nil
  ) -> Transcript {
    let turns = [
      Turn(
        id: "m0-0", speakerId: "sys:1", startMs: 0, endMs: 1_000, originalTextRange: 0..<12,
        wasPolished: true),
      Turn(
        id: "m1-1000", speakerId: "mic:you", startMs: 1_000, endMs: 2_000,
        originalTextRange: 13..<25, wasPolished: true),
      Turn(
        id: "m2-2000", speakerId: "mic:you", startMs: 2_000, endMs: 3_000,
        originalTextRange: 26..<39, wasPolished: true),
    ]
    return Transcript(
      id: id, text: text, backendType: .parakeet, speakerAnalysis: .labeled(count: 2),
      speakerNames: ["sys:1": "Speaker 1", "mic:you": "You"], turns: turns, meetingID: meetingID,
      meetingTranscriptAttemptID: attemptID)
  }

  final class Rig {
    let coordinator: TranscriptCoordinator
    /// Where the rig's History rows are saved.
    let directory: URL
    var infos: [UUID: MeetingHistoryInfo] = [:]

    @MainActor
    init() {
      let dir = TestTemporaryDirectory.url
        .appendingPathComponent("meeting-history-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      directory = dir
      let box = EventBox()
      coordinator = TranscriptCoordinator(
        store: TranscriptStore(directory: dir),
        emitRenameTelemetry: { box.renames.append($0) },
        emitTurnsDisplayedTelemetry: { box.displayed += 1 })
      events = box
      coordinator.meetingInfo = { [unowned self] in infos[$0] }
      coordinator.meetingRecords = { [unowned self] in records }
    }

    /// EnviousMeet's meetings as History reads them (`MeetingCoordinator.meetings`).
    var records: [MeetingRecord] = []

    let events: EventBox

    final class EventBox {
      var renames: [TelemetryService.FileImportRenameOutcome] = []
      var displayed = 0
    }

    @MainActor
    func addMeeting(echo: Set<String> = ["m1-1000"], title: String? = nil) async throws
      -> Transcript
    {
      let row = MeetingHistoryPresentationTests.meetingRow()
      infos[try #require(row.meetingID)] = MeetingHistoryInfo(echoTurnIDs: echo, title: title)
      try await coordinator.saveAndShowDurably(row)
      return row
    }
  }

  /// Meetings as EnviousMeet holds them, readable by the coordinator and changeable by a test.
  @MainActor
  final class Live {
    var records: [MeetingRecord] = []
  }

  /// The production History path with `records` as real meeting folders (#4586): the catalog
  /// indexes the folders and `rows`, and the coordinator reads the same records through the
  /// closures EnviousMeet wiring provides. `prepare` writes more into the meeting store (notes,
  /// facts) before indexing starts.
  static func catalogRig(
    records: [MeetingRecord] = [], rows: [Transcript] = [], live: Live = Live(),
    prepare: (MeetingStore) throws -> Void = { _ in }
  ) async throws -> HistoryCatalogRig {
    live.records = records
    return try await HistoryCatalogRig.make(rows: rows) { coordinator, store in
      for record in records { try store.create(record) }
      try prepare(store)
      coordinator.meetingRecords = { live.records }
      coordinator.meetingRecord = { id in live.records.first { $0.id == id } }
      coordinator.meetingInfo = { id in
        live.records.first { $0.id == id }.flatMap { MeetingHistoryInfo.paired(with: $0) }
      }
    }
  }

  @Test("a meeting is listed on Meetings, never on Dictations or Transcripts, and never a dictation")
  func kindAndCounts() async throws {
    let dictation = Transcript(text: "a dictation", backendType: .parakeet)
    let meeting = Self.meetingRow()
    let meetingID = try #require(meeting.meetingID)
    let rig = try await Self.catalogRig(rows: [dictation, meeting])
    defer { rig.remove() }

    #expect(await rig.listedIDs(.dictations) == [.transcript(dictation.id)])
    #expect(await rig.listedIDs(.transcripts).isEmpty)
    #expect(await rig.listedIDs(.meetings) == [.meeting(meetingID)])
    let total = try? await rig.session.itemCount(now: rig.coordinator.clock())
    #expect(total?.count == 2)
  }

  @Test("a meeting with no History row yet is one Meetings item, kept open when its row lands")
  func meetingItemFromStartToRow() async throws {
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.title = "Board review"
    let live = Live()
    let rig = try await Self.catalogRig(records: [record], live: live)
    defer { rig.remove() }
    #expect(await rig.listedIDs(.meetings) == [.meeting(record.id)])
    #expect(await rig.listedRowIDs(.meetings).isEmpty)
    rig.coordinator.openHistoryItem(.meeting(record.id), in: .meetings)
    #expect(rig.coordinator.openHistoryItemID(in: .meetings) == .meeting(record.id))

    // The ready record is saved before the row (the catalog pairs a row only with a committed
    // generation), then its row lands under the same meeting id: still one item, still open.
    record.state = .ready
    live.records = [record]
    try await rig.applying { try rig.meetings.save(record) }
    let row = MeetingHistoryPresentationTests.meetingRow(
      id: record.transcriptID, meetingID: record.id)
    try await rig.applying { try await rig.coordinator.saveAndShowDurably(row) }
    #expect(await rig.listedIDs(.meetings) == [.meeting(record.id)])
    #expect(rig.coordinator.openHistoryItemID(in: .meetings) == .meeting(record.id))
    #expect(await rig.listedRowIDs(.meetings) == [record.transcriptID])

    // Dictations never list it.
    #expect(await rig.listedIDs(.dictations).isEmpty)
  }

  @Test("History lists only meetings when its rows are all gone, and counts them for Delete All")
  func rowlessMeetingsCountAndDelete() async throws {
    var recording = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    recording.title = "Standup"
    var deleting = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    deleting.deletionRequested = true
    let rig = try await Self.catalogRig(records: [recording, deleting])
    defer { rig.remove() }
    var marked: [UUID] = []
    rig.coordinator.meetingsWillBeDeletedWithAll = { ids in
      marked = ids
      return true
    }
    #expect(await rig.listedIDs(.meetings) == [.meeting(recording.id)])
    #expect(rig.coordinator.deletableCount == 1)

    // Search covers finished meetings only (R35): one still recording never matches, even by
    // its title.
    rig.coordinator.setHistoryQuery("stand", in: .meetings)
    #expect(await rig.listedIDs(.meetings).isEmpty)
    rig.coordinator.setHistoryQuery("", in: .meetings)

    let confirmation = try #require(await rig.coordinator.deleteAllConfirmation())
    await rig.coordinator.deleteAll(confirmedSource: confirmation.source)
    #expect(Set(marked) == [recording.id, deleting.id])
  }

  @Test("deleting a meeting item asks EnviousMeet")
  func deleteMeetingItem() async throws {
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    let rig = try await Self.catalogRig(records: [record])
    defer { rig.remove() }
    var asked: [UUID] = []
    rig.coordinator.deleteMeeting = { asked.append($0); return true }
    let item = try #require(await rig.listed(.meetings).first)
    #expect(item.id == .meeting(record.id))
    await rig.coordinator.delete(item)
    #expect(asked == [record.id])
  }

  @Test("Show meetings opens the Meetings tab with no search and opens the meeting")
  func showMeetings() async throws {
    let rig = Rig()
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    rig.records = [record]
    rig.coordinator.setHistoryQuery("nothing matches", in: .meetings)
    rig.coordinator.showMeetings(meetingID: record.id)
    #expect(rig.coordinator.historyTab == .meetings)
    #expect(rig.coordinator.requestedHistoryState(for: .meetings).query.isEmpty)
    #expect(rig.coordinator.openHistoryItemID(in: .meetings) == .meeting(record.id))
  }

  @Test("a meeting marked for deletion is never listed, not even as its History row")
  func markedMeetingNotOrphaned() async throws {
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.deletionRequested = true
    let row = MeetingHistoryPresentationTests.meetingRow(
      id: record.transcriptID, meetingID: record.id)
    let rig = try await Self.catalogRig(records: [record], rows: [row])
    defer { rig.remove() }
    #expect(await rig.listedIDs(.meetings).isEmpty, "its deletion is running, stalled or failed")
    #expect(await rig.listedIDs(.dictations).isEmpty)
  }

  @Test("a finished meeting is searched by its words; while it is transcribed again it is not")
  func searchFinishedOnly() async throws {
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .ready
    let row = MeetingHistoryPresentationTests.meetingRow(
      id: record.transcriptID, meetingID: record.id)
    let live = Live()
    let rig = try await Self.catalogRig(records: [record], rows: [row], live: live)
    defer { rig.remove() }
    let word = try #require(row.text.split(separator: " ").first.map(String.init))
    rig.coordinator.setHistoryQuery(word, in: .meetings)
    #expect(await rig.listedIDs(.meetings) == [.meeting(record.id)])
    record.state = .processing  // Transcribe again keeps the old row
    live.records = [record]
    try await rig.applying { try rig.meetings.save(record) }
    #expect(await rig.listedIDs(.meetings).isEmpty)
  }


  @Test("a meeting is never the last dictation to paste or copy again")
  func neverReusedAsLastDictation() async throws {
    let rig = Rig()
    let dictation = Transcript(
      text: "older dictation", backendType: .parakeet, createdAt: Date(timeIntervalSinceNow: -60))
    try await rig.coordinator.saveAndShow(dictation)
    let meeting = try await rig.addMeeting()
    #expect(rig.coordinator.lastPasteableDictation()?.id == dictation.id)
    #expect(rig.coordinator.lastDictationTextForReuse(id: meeting.id) == nil)
  }

  @Test("delivery is the visible turns only, with names, in History's export format")
  func deliveryHidesEcho() async throws {
    let rig = Rig()
    let meeting = try await rig.addMeeting()
    let text = try #require(rig.coordinator.textForDelivery(meeting))
    #expect(text.contains("Speaker 1"))
    #expect(text.contains("Hello there."))
    #expect(text.contains("Yes, I agree."))
    // The echo line, the second "Hello there.", is not delivered.
    #expect(text.components(separatedBy: "Hello there.").count == 2)
    #expect(
      MeetingHistoryPresentation.previewText(rig.coordinator.meetingProjection(of: meeting))
        .components(separatedBy: "Hello there.").count == 2)

    rig.coordinator.setShowEcho(true, rowID: meeting.id)
    let shown = try #require(rig.coordinator.textForDelivery(meeting))
    #expect(shown.components(separatedBy: "Hello there.").count == 3)
  }

  @Test("the echo choice is per row and starts hidden")
  func echoChoiceDoesNotLeak() async throws {
    let rig = Rig()
    let first = try await rig.addMeeting()
    let second = try await rig.addMeeting()
    rig.coordinator.setShowEcho(true, rowID: first.id)
    #expect(rig.coordinator.isShowingEcho(rowID: first.id))
    #expect(rig.coordinator.isShowingEcho(rowID: second.id) == false)
    let secondText = try #require(rig.coordinator.textForDelivery(second))
    #expect(secondText.components(separatedBy: "Hello there.").count == 2)
    rig.coordinator.setShowEcho(false, rowID: first.id)
    #expect(rig.coordinator.isShowingEcho(rowID: first.id) == false)
  }

  @Test("every line hidden, or meeting facts unknown: nothing is shown or delivered")
  func failsClosed() async throws {
    let rig = Rig()
    let allEcho = try await rig.addMeeting(echo: ["m0-0", "m1-1000", "m2-2000"])
    #expect(rig.coordinator.meetingProjection(of: allEcho) == .everythingHidden)
    #expect(rig.coordinator.textForDelivery(allEcho) == nil)
    #expect(
      MeetingHistoryPresentation.previewText(rig.coordinator.meetingProjection(of: allEcho))
        == MeetingHistoryPresentation.everythingHiddenMessage)

    let unknown = Self.meetingRow()
    try await rig.coordinator.saveAndShowDurably(unknown)
    #expect(rig.coordinator.meetingProjection(of: unknown) == .unavailable)
    #expect(rig.coordinator.textForDelivery(unknown) == nil)
    #expect(
      MeetingHistoryPresentation.previewText(rig.coordinator.meetingProjection(of: unknown))
        == MeetingHistoryPresentation.unavailableMessage)
  }

  @Test("search finds visible words and the title, never words only in hidden echo")
  func searchSeesOnlyVisibleText() async throws {
    // The echo turn's words differ here, so a match on them can only come from hidden text.
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .ready
    record.title = "Board sync"
    record.echoTurnIDs = ["m1-1000"]
    let row = Self.meetingRow(
      id: record.transcriptID, meetingID: record.id,
      text: "Hello there. Secret echo. Yes, I agree.")
    let rig = try await Self.catalogRig(records: [record], rows: [row])
    defer { rig.remove() }

    rig.coordinator.setHistoryQuery("agree", in: .meetings)
    #expect(await rig.listedRowIDs(.meetings) == [row.id])
    rig.coordinator.setHistoryQuery("Board", in: .meetings)
    #expect(await rig.listedRowIDs(.meetings) == [row.id])
    rig.coordinator.setHistoryQuery("Secret", in: .meetings)
    #expect(await rig.listedRowIDs(.meetings).isEmpty)
    rig.coordinator.setShowEcho(true, rowID: row.id)
    #expect(await rig.listedRowIDs(.meetings) == [row.id])
  }

  @Test("both gap markers stay in the delivered text")
  func gapMarkersSurvive() async throws {
    let rig = Rig()
    let text = "[Could not transcribe 1:00 to 1:30] [Could not transcribe from 2:00]"
    let turns = [
      Turn(
        id: "m0-60000", speakerId: "mic:you", startMs: 60_000, endMs: 90_000,
        originalTextRange: 0..<35, wasPolished: true),
      Turn(
        id: "m1-120000", speakerId: "mic:you", startMs: 120_000, endMs: 120_000,
        originalTextRange: 36..<text.utf16.count, wasPolished: true),
    ]
    let row = Transcript(
      text: text, backendType: .parakeet, speakerAnalysis: .labeled(count: 1),
      speakerNames: ["mic:you": "You"], turns: turns, meetingID: UUID())
    rig.infos[try #require(row.meetingID)] = MeetingHistoryInfo(echoTurnIDs: [])
    try await rig.coordinator.saveAndShowDurably(row)
    let delivered = try #require(rig.coordinator.textForDelivery(row))
    #expect(delivered.contains("[Could not transcribe 1:00 to 1:30]"))
    #expect(delivered.contains("[Could not transcribe from 2:00]"))
  }

  @Test("a meeting deleted after the menu rendered delivers nothing")
  func deliveryAfterDeletion() async throws {
    let rig = Rig()
    let meeting = try await rig.addMeeting()
    try await rig.coordinator.removeRow(id: meeting.id)
    #expect(rig.coordinator.textForDelivery(meeting) == nil)
  }

  @Test("renaming a meeting's speaker works and sends no file-import telemetry, even once deleted")
  func renameWithoutImportTelemetry() async throws {
    let rig = Rig()
    let meeting = try await rig.addMeeting()
    await #expect(
      rig.coordinator.renameSpeaker(
        id: meeting.id, speakerId: "sys:1", name: "Ana", isMeeting: true) == nil)
    #expect(rig.coordinator.currentRow(id: meeting.id)?.speakerNames?["sys:1"] == "Ana")
    let delivered = try #require(rig.coordinator.textForDelivery(meeting))
    #expect(delivered.contains("Ana"))
    rig.coordinator.noteRenameCancelled(isMeeting: true)
    rig.coordinator.noteTurnsDisplayed(id: meeting.id, isMeeting: true)
    // Callbacks that arrive after the meeting's row is gone stay silent too.
    try await rig.coordinator.removeRow(id: meeting.id)
    await #expect(
      rig.coordinator.renameSpeaker(
        id: meeting.id, speakerId: "sys:1", name: "Bo", isMeeting: true) != nil)
    rig.coordinator.noteRenameCancelled(isMeeting: true)
    rig.coordinator.noteTurnsDisplayed(id: meeting.id, isMeeting: true)
    #expect(rig.events.renames.isEmpty)
    #expect(rig.events.displayed == 0)

    // An ordinary turn row still reports all three, before and after its deletion.
    let imported = Transcript(
      text: "Hello there.", backendType: .parakeet, importedFileName: "call.m4a",
      speakerAnalysis: .labeled(count: 1), speakerNames: ["s1": "A"],
      turns: [Turn(id: "t1", speakerId: "s1", startMs: 0, endMs: 1, originalTextRange: 0..<12)])
    try await rig.coordinator.saveAndShow(imported)
    rig.coordinator.noteRenameCancelled(isMeeting: false)
    rig.coordinator.noteTurnsDisplayed(id: imported.id, isMeeting: false)
    try await rig.coordinator.removeRow(id: imported.id)
    _ = await rig.coordinator.renameSpeaker(id: imported.id, speakerId: "s1", name: "B", isMeeting: false)
    #expect(rig.events.renames == [.cancelled, .failed])
    #expect(rig.events.displayed == 1)
  }

  typealias Harness = MeetingCoordinatorTests.Harness

  private func eventually(_ label: String, _ condition: @escaping @MainActor () -> Bool) async {
    await MeetingCoordinatorTests.eventually(label, condition)
  }

  /// #3973 C2: the ready record (with the echo IDs) is written before the History row, so while
  /// it is being written History has no row and no facts; once both are saved the row is read
  /// with its own generation's facts.
  @Test("History reads a meeting's facts only once its ready record and its row are both saved")
  func factsWaitForTheReadyWrite() async throws {
    let harness = try Harness()
    let gate = harness.writeGate
    harness.jobBehavior = { _ in
      gate.arm()  // the next meeting.json write is the ready barrier
      return MeetingCoordinatorTests.result()
    }
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await coordinator.stop(reason: .user)
    #expect(
      await Task.detached { MeetingCoordinatorTests.waitBlocking(gate.entered) }.value == .success)
    // The ready record is still being written: no row yet, and no facts.
    #expect(harness.saved.isEmpty)
    #expect(MeetingWiring.historyInfo(coordinator, meetingID: meetingID) == nil)
    gate.release.signal()
    await eventually("ready and published") {
      coordinator.record(id: meetingID)?.state == .ready && harness.saved.count == 1
    }
    #expect(gate.timedOut.withLock { $0 } == false, "a held write waited out its bound")
    let row = try #require(harness.saved.first)
    #expect(
      MeetingWiring.historyInfo(coordinator, meetingID: meetingID)?.matching(row)?.echoTurnIDs
        == ["mic-3"])
  }

  @Test("a ready write that fails leaves History showing nothing for the meeting")
  func factsStayClosedWhenReadyFails() async throws {
    let harness = try Harness()
    harness.writeGate.failWrites(inState: .ready)
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await coordinator.stop(reason: .user)
    await eventually("pass over") {
      coordinator.processing == nil && !coordinator.hasFinalPassWork
    }
    #expect(coordinator.record(id: meetingID)?.state != .ready)
    #expect(harness.saved.isEmpty, "#3973 C2: no row is written before the ready barrier")
    #expect(MeetingWiring.historyInfo(coordinator, meetingID: meetingID) == nil)
  }

  /// #3973 C2 (plan G4): while Transcribe again runs and until its row is published, the earlier
  /// row stays readable with ITS echo IDs; once published, the new row is read with the new
  /// echo IDs and the earlier generation's facts are gone.
  @Test("Transcribe again keeps the earlier row readable with its own echo IDs until the new one is published")
  func retryFactsFollowTheNewRow() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await coordinator.stop(reason: .user)
    // Retry is refused while the first pass is still clearing its progress: wait for both.
    await eventually("first ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    #expect(MeetingWiring.historyInfo(coordinator, meetingID: meetingID)?.echoTurnIDs == ["mic-3"])

    harness.jobBehavior = { _ in
      let first = MeetingCoordinatorTests.result()
      return MeetingTranscriptionJob.Result(
        composition: MeetingComposition(
          text: "hello again", turns: [], speakerNames: [:], echoTurnIDs: ["mic-9"],
          speakerCount: 1),
        speakerOutcomes: first.speakerOutcomes, forcedCuts: 0, failedPieces: 0,
        failedRanges: [:], resumedPieces: 0, checkpointSaveFailures: 0, yieldCount: 0,
        processingSeconds: 1, audioSeconds: 1,
        resolved: MeetingCoordinatorTests.placeholderResolved)
    }
    let earlier = try #require(harness.saved.last)
    func facts(of row: Transcript) -> Set<String>? {
      MeetingWiring.historyInfo(coordinator, meetingID: meetingID)?.matching(row)?.echoTurnIDs
    }
    let save = MeetingCoordinatorTests.Gate()
    harness.saveGate = save
    await MeetingCoordinatorTests.transcribeAgainOnceOffered(coordinator, meetingID: meetingID)
    #expect(coordinator.record(id: meetingID)?.state == .queued)
    #expect(facts(of: earlier) == ["mic-3"], "queued: the earlier row keeps its echo IDs")
    await eventually("retry save parked") { save.parked }
    // Committed, not yet published: History still holds the earlier row, read with its own IDs.
    #expect(coordinator.record(id: meetingID)?.state == .ready)
    #expect(facts(of: earlier) == ["mic-3"])
    save.open()
    await eventually("retry ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    let replaced = try #require(harness.saved.last)
    #expect(replaced.text == "hello again")
    #expect(replaced.id == earlier.id, "the same row, replaced")
    #expect(replaced.meetingTranscriptAttemptID != earlier.meetingTranscriptAttemptID)
    #expect(facts(of: replaced) == ["mic-9"])
    #expect(facts(of: earlier) == nil, "the earlier generation's facts are gone")
  }

  /// #3973 C2 (plan G4): a Transcribe again that fails leaves the earlier transcript readable
  /// with its own facts, and the meeting offers Transcribe again.
  @Test("a failed Transcribe again keeps the earlier row readable with its own echo IDs")
  func failedRetryKeepsTheEarlierRow() async throws {
    let harness = try Harness()
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await coordinator.stop(reason: .user)
    await eventually("first ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    let earlier = try #require(harness.saved.last)
    harness.jobBehavior = { _ in throw MeetingTranscriptionJob.JobError.engineUnavailable("x") }
    #expect(await coordinator.transcribeAgain(meetingID: meetingID, engine: .parakeet))
    await eventually("retry failed") {
      coordinator.record(id: meetingID)?.state == .failed && coordinator.processing == nil
    }
    let info = MeetingWiring.historyInfo(coordinator, meetingID: meetingID)
    #expect(info?.matching(earlier)?.echoTurnIDs == ["mic-3"])
    #expect(harness.saved.count == 1, "no second row was written")
    #expect(coordinator.canTranscribeAgain(meetingID))
    #expect(coordinator.record(id: meetingID)?.pendingAttempt != nil, "the failed attempt is kept")
  }

  @Test("a meeting whose ready save failed is recovered by Transcribe again into one readable row")
  func stalledReadyRecoversOneRow() async throws {
    let harness = try Harness()
    let history = Rig()
    var deps = harness.dependencies()
    // The real History owner and store, so a second save replaces the row, never adds one.
    deps.saveTranscript = { row, naming in
      try await history.coordinator.saveAndShowDurably(row, naming: naming)
    }
    let coordinator = MeetingCoordinator(dependencies: deps)
    history.coordinator.meetingRecords = { coordinator.meetings }
    let gate = harness.writeGate
    harness.jobBehavior = { _ in
      gate.failNext(1)  // the ready write
      return MeetingCoordinatorTests.result()
    }
    await coordinator.start(from: .history)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await coordinator.stop(reason: .user)
    await eventually("stalled") {
      coordinator.processing == nil && !coordinator.hasFinalPassWork
        && coordinator.record(id: meetingID)?.state == .processing
    }
    let record = try #require(coordinator.record(id: meetingID))
    #expect(
      MeetingWiring.historyInfo(coordinator, meetingID: meetingID) == nil,
      "nothing committed: no facts")
    func rows() async throws -> [Transcript] {
      try await TranscriptStore(directory: history.directory).loadAll().filter {
        $0.meetingID == meetingID
      }
    }
    // #3973 C2: the row is written only after the ready barrier, so nothing reached History.
    #expect(try await rows().isEmpty)

    harness.jobBehavior = { _ in
      let first = MeetingCoordinatorTests.result()
      return MeetingTranscriptionJob.Result(
        composition: MeetingComposition(
          text: "hello again", turns: [], speakerNames: [:], echoTurnIDs: ["mic-9"],
          speakerCount: 1),
        speakerOutcomes: first.speakerOutcomes, forcedCuts: 0, failedPieces: 0,
        failedRanges: [:], resumedPieces: 0, checkpointSaveFailures: 0, yieldCount: 0,
        processingSeconds: 1, audioSeconds: 1,
        resolved: MeetingCoordinatorTests.placeholderResolved)
    }
    #expect(await coordinator.transcribeAgain(meetingID: meetingID, engine: .parakeet))
    await eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    let after = try await rows()
    #expect(after.map(\.id) == [record.transcriptID], "one row, the original id")
    #expect(after.first?.text == "hello again", "the retried result")
    #expect(MeetingWiring.historyInfo(coordinator, meetingID: meetingID)?.echoTurnIDs == ["mic-9"])
  }

  @Test("Meetings says how many meetings a newer version saved, one sentence per count")
  func newerFormatLine() {
    #expect(HistoryDiaryLayout.newerFormatLine(0) == nil)
    #expect(
      HistoryDiaryLayout.newerFormatLine(1)
        == "A recording was saved by a newer version of EnviousWispr. Update the app to open it.")
    #expect(
      HistoryDiaryLayout.newerFormatLine(3)
        == "3 recordings were saved by a newer version of EnviousWispr. Update the app to open them."
    )
  }

  @Test("a meeting marked for deletion delivers nothing while its row is still held")
  func markedMeetingDeliversNothing() async throws {
    let rig = Rig()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .ready
    let row = MeetingHistoryPresentationTests.meetingRow(
      id: record.transcriptID, meetingID: record.id)
    try await rig.coordinator.saveAndShowDurably(row)
    // History's facts come from the shared gate, as in the app (`MeetingWiring.historyInfo`).
    var current = record
    rig.coordinator.meetingInfo = { _ in MeetingHistoryInfo.paired(with: current) }
    #expect(rig.coordinator.textForDelivery(row) != nil, "a ready meeting delivers its lines")

    // The mark is durable; the row's removal has not happened (held or failed).
    current.deletionRequested = true
    #expect(MeetingHistoryInfo.paired(with: current) == nil)
    #expect(rig.coordinator.textForDelivery(row) == nil)
    #expect(rig.coordinator.currentRow(id: row.id) != nil, "the row is still in the store")
  }

  @Test("a finished meeting is also found by its notes; an unfinished one is not")
  func searchByNotes() async throws {
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .ready
    let row = MeetingHistoryPresentationTests.meetingRow(
      id: record.transcriptID, meetingID: record.id)
    let live = Live()
    let rig = try await Self.catalogRig(records: [record], rows: [row], live: live) { store in
      try Data("Ask Priya about the budget".utf8).write(
        to: store.notesURL(for: record.id), options: .atomic)
    }
    defer { rig.remove() }
    rig.coordinator.setHistoryQuery("priya", in: .meetings)
    #expect(await rig.listedIDs(.meetings) == [.meeting(record.id)])
    record.state = .processing
    live.records = [record]
    try await rig.applying { try rig.meetings.save(record) }
    #expect(await rig.listedIDs(.meetings).isEmpty, "finished meetings only, notes included")
  }

  @Test("#4286: a finished meeting is found by an invited name, email or domain absent from its words")
  func searchByInvited() async throws {
    func attendees(of record: MeetingRecord) -> [MeetingFact] {
      // Dana (declined) with an email, Kim with a name only.
      [
        AttendeeFact(
          name: "Dana Lee", email: "dana@acme.com", role: .required, status: .declined,
          isSelf: false, isOrganizer: false),
        AttendeeFact(
          name: "Kim", email: nil, role: .required, status: .accepted, isSelf: false,
          isOrganizer: false),
      ].map { $0.fact(source: MeetingFact.eventKitSource, capturedAt: record.createdAt) }
    }
    var finished = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    finished.state = .ready
    // A ready meeting whose row belongs to another transcript generation: its facts are not shown.
    var otherGeneration = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    otherGeneration.state = .ready
    var failed = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    failed.state = .failed
    let finishedRow = MeetingHistoryPresentationTests.meetingRow(
      id: finished.transcriptID, meetingID: finished.id)
    let otherRow = MeetingHistoryPresentationTests.meetingRow(
      id: otherGeneration.transcriptID, meetingID: otherGeneration.id, attemptID: UUID())
    let failedRow = MeetingHistoryPresentationTests.meetingRow(
      id: failed.transcriptID, meetingID: failed.id)
    #expect(otherRow.meetingTranscriptGeneration != finishedRow.meetingTranscriptGeneration)
    let records = [finished, otherGeneration, failed]
    let rig = try await Self.catalogRig(
      records: records, rows: [finishedRow, otherRow, failedRow]
    ) { store in
      for record in records { try store.appendFacts(attendees(of: record), meeting: record.id) }
    }
    defer { rig.remove() }
    for query in ["dana lee", "DANA@ACME.COM", "acme.com", "kim"] {
      rig.coordinator.setHistoryQuery(query, in: .meetings)
      #expect(await rig.listedRowIDs(.meetings) == [finishedRow.id], "query: \(query)")
    }
    rig.coordinator.setHistoryQuery("globex", in: .meetings)
    #expect(await rig.listedRowIDs(.meetings).isEmpty, "a term nobody was invited by")
    // The other-generation and the failed meeting carry the same invited people yet never match:
    // only the finished meeting with its own generation's facts is listed above.
  }

  @Test("#4286: the detail's Invited line names invited people, an email when no name, one per email")
  func invitedLine() {
    func fact(_ name: String?, _ email: String?, status: AttendeeFact.Status = .accepted)
      -> MeetingFact
    {
      AttendeeFact(
        name: name, email: email, role: .required, status: status, isSelf: false,
        isOrganizer: false
      ).fact(source: MeetingFact.eventKitSource, capturedAt: Date(timeIntervalSinceReferenceDate: 1))
    }
    #expect(MeetingsPresentation.invitedLine(nil) == nil)
    #expect(MeetingsPresentation.invitedLine(MeetingContext()) == nil)
    let line = MeetingsPresentation.invitedLine(
      MeetingContext(facts: [
        fact("Dana Lee", "dana@acme.com"), fact(nil, "ops@acme.com"),
        fact("Li Wu", "li@acme.com", status: .declined), fact(nil, "DANA@acme.com"),
      ]))
    let text = try? #require(line)
    #expect(text?.hasPrefix("Invited: ") == true)
    #expect(text?.contains("Dana Lee") == true)
    #expect(text?.contains("ops@acme.com") == true)
    #expect(text?.contains("Li Wu") == true)
    #expect(text?.contains("dana@acme.com") == false, "the named person is not listed twice")
  }
}
