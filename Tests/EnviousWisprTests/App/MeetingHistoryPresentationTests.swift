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
@Suite("Meeting rows in History", .tags(.productOutcome))
struct MeetingHistoryPresentationTests {
  /// "Hello there." (You, 0..<12), then "Hello there." again on the mic (echo, 13..<25),
  /// then "Yes, I agree." (Speaker 1, 26..<39).
  static let text = "Hello there. Hello there. Yes, I agree."

  static func meetingRow(id: UUID = UUID(), meetingID: UUID = UUID(), text: String = text)
    -> Transcript
  {
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
      speakerNames: ["sys:1": "Speaker 1", "mic:you": "You"], turns: turns, meetingID: meetingID)
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

  @Test("a meeting is a Recording, never a Dictation or a Transcript, and never a dictation")
  func kindAndCounts() async throws {
    let rig = Rig()
    let dictation = Transcript(text: "a dictation", backendType: .parakeet)
    try await rig.coordinator.saveAndShow(dictation)
    let meeting = try await rig.addMeeting()
    let meetingID = try #require(meeting.meetingID)

    rig.coordinator.historyFilter = .dictations
    #expect(rig.coordinator.listedItems.map(\.id) == [.transcript(dictation.id)])
    rig.coordinator.historyFilter = .transcripts
    #expect(rig.coordinator.listedItems.isEmpty)
    #expect(rig.coordinator.emptyState == .noTranscripts)
    rig.coordinator.historyFilter = .recordings
    #expect(rig.coordinator.listedItems.map(\.id) == [.meeting(meetingID)])
    rig.coordinator.historyFilter = .all
    #expect(rig.coordinator.listedCount == 2)
    #expect(rig.coordinator.dictationCount == 1)
  }

  @Test("a meeting with no History row yet is one Meetings item, kept when its row lands")
  func meetingItemFromStartToRow() async throws {
    let rig = Rig()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.title = "Board review"
    rig.records = [record]
    rig.coordinator.historyFilter = .recordings
    #expect(rig.coordinator.listedItems.map(\.id) == [.meeting(record.id)])
    #expect(rig.coordinator.emptyState == nil)
    rig.coordinator.selectedItemID = .meeting(record.id)
    guard case .meeting(let shown) = rig.coordinator.detail else {
      Issue.record("the selected meeting is not the detail")
      return
    }
    #expect(shown.row == nil)

    // Its row lands under the same meeting id: still one item, still selected.
    let row = MeetingHistoryPresentationTests.meetingRow(
      id: record.transcriptID, meetingID: record.id)
    try await rig.coordinator.saveAndShowDurably(row)
    #expect(rig.coordinator.listedItems.map(\.id) == [.meeting(record.id)])
    #expect(rig.coordinator.selectedItemID == .meeting(record.id))
    #expect(rig.coordinator.listedItems.first?.row?.id == record.transcriptID)

    // Dictations never list it; the selection leaves with it.
    rig.coordinator.historyFilter = .dictations
    #expect(rig.coordinator.selectedItemID == nil)
  }

  @Test("History lists only meetings when its rows are all gone, and counts them for Delete All")
  func rowlessMeetingsCountAndDelete() async throws {
    let rig = Rig()
    var marked: [UUID] = []
    rig.coordinator.meetingsWillBeDeletedWithAll = { ids in
      marked = ids
      return true
    }
    var recording = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    recording.title = "Standup"
    var deleting = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    deleting.deletionRequested = true
    rig.records = [recording, deleting]
    #expect(rig.coordinator.emptyState == nil, "a meeting still recording is not nothing")
    #expect(rig.coordinator.listedItems.map(\.id) == [.meeting(recording.id)])
    #expect(rig.coordinator.deletableCount == 1)

    // Search covers finished meetings only (R35): one still recording never matches, even by
    // its title.
    rig.coordinator.searchQuery = "stand"
    #expect(rig.coordinator.listedItems.isEmpty)
    rig.coordinator.searchQuery = ""

    await rig.coordinator.deleteAll()
    #expect(Set(marked) == [recording.id, deleting.id])
  }

  @Test("deleting a meeting item asks EnviousMeet and moves the selection beside it")
  func deleteMeetingItem() async throws {
    let rig = Rig()
    var asked: [UUID] = []
    rig.coordinator.deleteMeeting = { asked.append($0) }
    let dictation = Transcript(
      text: "older", backendType: .parakeet, createdAt: Date(timeIntervalSinceNow: -60))
    try await rig.coordinator.saveAndShow(dictation)
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    rig.records = [record]
    let item = try #require(rig.coordinator.listedItems.first)
    #expect(item.id == .meeting(record.id))
    rig.coordinator.selectedItemID = item.id
    await rig.coordinator.delete(item)
    #expect(asked == [record.id])
    #expect(rig.coordinator.selectedItemID == .transcript(dictation.id))
  }

  @Test("Show recordings lists Meetings with no search and selects the meeting")
  func showRecordings() async throws {
    let rig = Rig()
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    rig.records = [record]
    rig.coordinator.searchQuery = "nothing matches"
    rig.coordinator.showRecordings(meetingID: record.id)
    #expect(rig.coordinator.historyFilter == .recordings)
    #expect(rig.coordinator.searchQuery.isEmpty)
    #expect(rig.coordinator.selectedItemID == .meeting(record.id))
    // An empty Meetings filter says how to record one, also on a fresh install (R34).
    rig.records = []
    #expect(rig.coordinator.emptyState == .noRecordings)
    rig.coordinator.historyFilter = .all
    #expect(rig.coordinator.emptyState == .nothingYet)
  }

  @Test("a meeting marked for deletion is never listed, not even as its History row")
  func markedMeetingNotOrphaned() async throws {
    let rig = Rig()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    let row = MeetingHistoryPresentationTests.meetingRow(
      id: record.transcriptID, meetingID: record.id)
    try await rig.coordinator.saveAndShowDurably(row)
    record.deletionRequested = true
    rig.records = [record]
    #expect(rig.coordinator.listedItems.isEmpty, "its deletion is running, stalled or failed")
  }

  @Test("a finished meeting is searched by its words; while it is transcribed again it is not")
  func searchFinishedOnly() async throws {
    let rig = Rig()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    let row = MeetingHistoryPresentationTests.meetingRow(
      id: record.transcriptID, meetingID: record.id)
    rig.infos[record.id] = MeetingHistoryInfo(echoTurnIDs: [], title: nil)
    try await rig.coordinator.saveAndShowDurably(row)
    record.state = .ready
    rig.records = [record]
    let word = try #require(row.text.split(separator: " ").first.map(String.init))
    rig.coordinator.searchQuery = word
    #expect(rig.coordinator.listedItems.map(\.id) == [.meeting(record.id)])
    record.state = .processing  // Transcribe again keeps the old row
    rig.records = [record]
    #expect(rig.coordinator.listedItems.isEmpty)
  }

  #if DEBUG
    @Test("a meeting removed elsewhere leaves no stale selection once EnviousMeet publishes")
    func externalRemovalClearsSelection() async throws {
      let rig = Rig()
      let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
      rig.records = [record]
      rig.coordinator.selectedItemID = .meeting(record.id)
      rig.records = []
      rig.coordinator.meetingsDidChange()
      // #4001 H4: the reconcile is queued; until it runs, the gone meeting shows nothing.
      guard case .empty = rig.coordinator.detail else {
        Issue.record("a removed meeting must resolve to an empty detail before the reconcile runs")
        return
      }
      let pending = try #require(rig.coordinator.pendingMeetingReconcileForTesting)
      await pending.value
      #expect(rig.coordinator.selectedItemID == nil)
      guard case .empty = rig.coordinator.detail else {
        Issue.record("still empty after the reconcile")
        return
      }
    }

    @Test("a burst of meeting changes shares one reconcile and one list build (#4001 H4)")
    func burstSharesOneReconcile() async throws {
      let rig = Rig()
      var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
      rig.records = [record]
      rig.coordinator.selectedItemID = .meeting(record.id)
      _ = rig.coordinator.listedItems.count
      let before = rig.coordinator.listBuildsForTesting
      rig.coordinator.meetingsDidChange()
      let first = try #require(rig.coordinator.pendingMeetingReconcileForTesting)
      for i in 1...4 {
        record.title = "title \(i)"
        rig.records = [record]
        rig.coordinator.meetingsDidChange()
        #expect(rig.coordinator.pendingMeetingReconcileForTesting == first)
      }
      await first.value
      #expect(rig.coordinator.listBuildsForTesting - before == 1)
      #expect(rig.coordinator.selectedItemID == .meeting(record.id))
      #expect(rig.coordinator.pendingMeetingReconcileForTesting == nil)

      // A later change schedules a new reconcile.
      rig.records = []
      rig.coordinator.meetingsDidChange()
      let second = try #require(rig.coordinator.pendingMeetingReconcileForTesting)
      #expect(second != first)
      await second.value
      #expect(rig.coordinator.selectedItemID == nil)
    }

    @Test("a selection made before the queued reconcile runs is kept (#4001 H4)")
    func newerSelectionSurvives() async throws {
      let rig = Rig()
      let gone = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
      let kept = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
      rig.records = [gone, kept]
      rig.coordinator.selectedItemID = .meeting(gone.id)
      rig.records = [kept]
      rig.coordinator.meetingsDidChange()
      rig.coordinator.selectedItemID = .meeting(kept.id)
      await rig.coordinator.pendingMeetingReconcileForTesting?.value
      #expect(rig.coordinator.selectedItemID == .meeting(kept.id))
    }

    @Test("a reconcile with nothing to check builds no list (#4001 H4)")
    func nothingToCheckBuildsNothing() async throws {
      let rig = Rig()
      var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
      rig.records = [record]
      record.title = "changed"
      rig.records = [record]
      let before = rig.coordinator.listBuildsForTesting
      rig.coordinator.meetingsDidChange()
      await rig.coordinator.pendingMeetingReconcileForTesting?.value
      #expect(rig.coordinator.listBuildsForTesting == before, "no selection, no fallback row")
    }
  #endif

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
    let rig = Rig()
    // The echo turn's words differ here, so a match on them can only come from hidden text.
    let row = Self.meetingRow(text: "Hello there. Secret echo. Yes, I agree.")
    let meetingID = try #require(row.meetingID)
    rig.infos[meetingID] = MeetingHistoryInfo(echoTurnIDs: ["m1-1000"], title: "Board sync")
    try await rig.coordinator.saveAndShowDurably(row)

    rig.coordinator.searchQuery = "agree"
    #expect(rig.coordinator.filteredTranscripts.map(\.id) == [row.id])
    rig.coordinator.searchQuery = "Board"
    #expect(rig.coordinator.filteredTranscripts.map(\.id) == [row.id])
    rig.coordinator.searchQuery = "Secret"
    #expect(rig.coordinator.filteredTranscripts.isEmpty)
    rig.coordinator.setShowEcho(true, rowID: row.id)
    #expect(rig.coordinator.filteredTranscripts.map(\.id) == [row.id])
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
    await coordinator.stop()
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
    await coordinator.stop()
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
    await coordinator.stop()
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
    await coordinator.stop()
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
    await coordinator.stop()
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
    #expect(SidebarStatsHeader.newerFormatLine(0) == nil)
    #expect(
      SidebarStatsHeader.newerFormatLine(1)
        == "A recording was saved by a newer version of EnviousWispr. Update the app to open it.")
    #expect(
      SidebarStatsHeader.newerFormatLine(3)
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
    let rig = Rig()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    let row = MeetingHistoryPresentationTests.meetingRow(
      id: record.transcriptID, meetingID: record.id)
    rig.infos[record.id] = MeetingHistoryInfo(echoTurnIDs: [], title: nil)
    try await rig.coordinator.saveAndShowDurably(row)
    record.state = .ready
    rig.records = [record]
    rig.coordinator.meetingNotes = { $0 == record.id ? "Ask Priya about the budget" : nil }
    rig.coordinator.searchQuery = "priya"
    #expect(rig.coordinator.listedItems.map(\.id) == [.meeting(record.id)])
    record.state = .processing
    rig.records = [record]
    #expect(rig.coordinator.listedItems.isEmpty, "finished meetings only, notes included")
  }
}
