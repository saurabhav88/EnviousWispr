import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// #3973 C2 (plan §3 item 5, G4): when these fail, Transcribe again loses the transcript the
/// user had, shows it with another pass's hidden echo lines, or a crash leaves a meeting whose
/// committed transcript never reaches History.
@MainActor
@Suite("MeetingTranscriptReplacement", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingTranscriptReplacementTests {
  typealias Harness = MeetingCoordinatorTests.Harness

  /// Waits through Observation: the condition must read observable state (a file read alone is
  /// never re-evaluated), so file checks follow an observable wait.
  private func eventually(_ label: String, _ condition: @escaping @MainActor () -> Bool) async {
    await MeetingCoordinatorTests.eventually(label, condition)
  }

  private func receipt(_ harness: Harness, _ meetingID: UUID) -> MeetingTranscriptReplacement? {
    if case .receipt(let receipt) = harness.store.loadTranscriptReplacement(meeting: meetingID) {
      return receipt
    }
    return nil
  }

  private func hasNoReceipt(_ harness: Harness, _ meetingID: UUID) -> Bool {
    if case .none = harness.store.loadTranscriptReplacement(meeting: meetingID) { return true }
    return false
  }

  /// A ready meeting with one committed transcript ("hello there", echo `mic-3`).
  private func readyMeeting(_ harness: Harness) async throws -> (UUID, Transcript) {
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    await coordinator.stop()
    await eventually("first ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    return (meetingID, try #require(harness.saved.last))
  }

  private static func rerunResult(_ access: MeetingTranscriptionJob.CheckpointAccess?)
    -> MeetingTranscriptionJob.Result
  {
    let first = MeetingCoordinatorTests.result()
    return MeetingTranscriptionJob.Result(
      composition: MeetingComposition(
        text: "hello again", turns: [], speakerNames: [:], echoTurnIDs: ["mic-9"],
        speakerCount: 1),
      speakerOutcomes: first.speakerOutcomes, forcedCuts: 0, failedPieces: 0, failedRanges: [:],
      resumedPieces: 0, checkpointSaveFailures: 0, yieldCount: 0, processingSeconds: 1,
      audioSeconds: 1, resolved: MeetingCoordinatorTests.placeholderResolved)
  }

  @Test(
    "a launch keeps a History row that already holds the committed generation; an unreadable or deleted one publishes nothing"
  )
  func launchKeepsAPublishedRow() async throws {
    let harness = try Harness()
    let (meetingID, _) = try await readyMeeting(harness)
    harness.jobBehavior = Self.rerunResult
    let save = MeetingCoordinatorTests.Gate()
    harness.saveGate = save
    #expect(await harness.coordinator.transcribeAgain(meetingID: meetingID, engine: .parakeet))
    await eventually("History save parked") { save.parked }
    // A crash now leaves the committed record and its receipt, as one whose History write
    // landed but whose receipt removal failed would.
    let kept = try #require(receipt(harness, meetingID))

    // History's file cannot be read: nothing is published and the receipt stays.
    let unreadable = try Harness(copying: harness.root)
    unreadable.historyReadError = CocoaError(.fileReadCorruptFile)
    unreadable.coordinator.launch()
    await eventually("refused") { unreadable.coordinator.notice == .storageFailed }
    #expect(unreadable.saved.isEmpty)
    #expect(unreadable.coordinator.isCommitReceiptPending(meetingID))
    #expect(receipt(unreadable, meetingID) != nil)

    // History's file already holds the committed generation (the user may have edited it
    // since): it is kept as it is.
    let relaunched = try Harness(copying: harness.root)
    relaunched.historyFiles[kept.candidateRow.id] = kept.candidateRow
    relaunched.coordinator.launch()
    // Pending is false before launch reads the receipt too; launch over is the settled signal.
    await eventually("launch over") { relaunched.coordinator.canTranscribeAgain(meetingID) }
    #expect(!relaunched.coordinator.isCommitReceiptPending(meetingID))
    #expect(relaunched.saved.isEmpty, "the edited row was not rewritten from the receipt")
    #expect(hasNoReceipt(relaunched, meetingID))

    // A deletion while launch reads History's file: the deleted meeting's row is not saved back.
    let deleted = try Harness(copying: harness.root)
    let read = MeetingCoordinatorTests.Gate()
    deleted.historyReadGate = read
    deleted.coordinator.launch()
    await eventually("History read parked") { read.parked }
    #expect(await deleted.coordinator.delete(meetingID: meetingID))
    read.open()
    // Deleting a meeting launch has not listed waits for launch to end.
    _ = await deleted.coordinator.delete(meetingID: UUID())
    #expect(deleted.saveRequests.isEmpty, "the deleted meeting's row was not published")
    save.open()
  }

  @Test(
    "a crash after the ready barrier: the next launch shows the earlier row with its own facts, then publishes the committed one"
  )
  func crashAfterBarrierPublishesTheCommittedRow() async throws {
    let harness = try Harness()
    let (meetingID, earlier) = try await readyMeeting(harness)
    harness.jobBehavior = Self.rerunResult
    let save = MeetingCoordinatorTests.Gate()
    harness.saveGate = save
    #expect(await harness.coordinator.transcribeAgain(meetingID: meetingID, engine: .parakeet))
    await eventually("History save parked") { save.parked }
    // A crash now: the record on disk is committed, History still holds the earlier row.
    let committed = try harness.store.load(id: meetingID)
    let kept = try #require(receipt(harness, meetingID))
    #expect(committed.state == .ready)
    #expect(committed.committedTranscriptGeneration == kept.candidate.generation)
    #expect(kept.previous?.echoTurnIDs == ["mic-3"])
    #expect(kept.candidateRow.text == "hello again")

    let relaunched = try Harness(copying: harness.root)
    let publish = MeetingCoordinatorTests.Gate()
    relaunched.saveGate = publish
    relaunched.coordinator.launch()
    await eventually("publication parked") { publish.parked }
    // Until it is published, History's earlier row is read with the earlier facts only.
    let info = MeetingWiring.historyInfo(relaunched.coordinator, meetingID: meetingID)
    #expect(info?.matching(earlier)?.echoTurnIDs == ["mic-3"])
    #expect(info?.matching(kept.candidateRow)?.echoTurnIDs == ["mic-9"])
    publish.open()
    await eventually("published") { relaunched.saved.count == 1 }
    #expect(relaunched.saved.first?.meetingTranscriptAttemptID == kept.candidate.generation)
    await eventually("receipt settled") {
      !relaunched.coordinator.isCommitReceiptPending(meetingID)
    }
    #expect(hasNoReceipt(relaunched, meetingID))
    let after = MeetingWiring.historyInfo(relaunched.coordinator, meetingID: meetingID)
    #expect(after?.matching(earlier) == nil, "the earlier generation's facts are gone")
    save.open()
  }

  @Test(
    "an unreadable receipt blocks a ready meeting until settled, and is dropped for one that is not ready"
  )
  func unreadableReceiptByState() async throws {
    let harness = try Harness()
    let (meetingID, _) = try await readyMeeting(harness)
    try Data("not a receipt".utf8).write(to: harness.store.transcriptReplacementURL(for: meetingID))

    // Ready: the receipt may belong to the commit that made it ready, so it is kept.
    let ready = try Harness(copying: harness.root)
    ready.coordinator.launch()
    await eventually("refused") { ready.coordinator.notice == .storageFailed }
    #expect(ready.coordinator.isCommitReceiptPending(meetingID))
    #expect(!ready.coordinator.canTranscribeAgain(meetingID))

    // Not ready: no ready write landed, so it committed nothing and is dropped.
    var record = try harness.store.load(id: meetingID)
    record.state = .failed
    try harness.store.save(record)
    let failed = try Harness(copying: harness.root)
    failed.coordinator.launch()
    await eventually("launch over") { failed.coordinator.canTranscribeAgain(meetingID) }
    #expect(hasNoReceipt(failed, meetingID))
    #expect(!failed.coordinator.isCommitReceiptPending(meetingID))
    #expect(failed.coordinator.notice == nil)
  }

  @Test(
    "a receipt whose candidate the record never committed is dropped at launch; nothing is published"
  )
  func uncommittedReceiptIsDropped() async throws {
    let harness = try Harness()
    let (meetingID, earlier) = try await readyMeeting(harness)
    let record = try harness.store.load(id: meetingID)
    // A crash between the receipt and the ready barrier leaves exactly this.
    let candidate = MeetingTranscriptReplacement.Facts(
      generation: UUID(), echoTurnIDs: ["mic-9"], speakerOutcomes: [:])
    try harness.store.saveTranscriptReplacement(
      MeetingTranscriptReplacement(
        meetingID: meetingID,
        previous: .init(
          generation: try #require(record.committedTranscriptGeneration),
          echoTurnIDs: record.echoTurnIDs, speakerOutcomes: record.speakerOutcomes),
        previousRow: earlier, candidate: candidate,
        candidateRow: Transcript(
          id: record.transcriptID, text: "never committed", meetingID: meetingID,
          meetingTranscriptAttemptID: candidate.generation)))

    let relaunched = try Harness(copying: harness.root)
    relaunched.coordinator.launch()
    await eventually("launch over") { relaunched.coordinator.canTranscribeAgain(meetingID) }
    #expect(hasNoReceipt(relaunched, meetingID), "the uncommitted receipt was dropped")
    #expect(relaunched.saved.isEmpty, "nothing was published")
    let info = MeetingWiring.historyInfo(relaunched.coordinator, meetingID: meetingID)
    #expect(info?.matching(earlier)?.echoTurnIDs == ["mic-3"])
  }

  @Test(
    "a ready write that fails without landing drops the receipt; Transcribe again works at once")
  func failedReadyWriteSettlesFromDisk() async throws {
    let harness = try Harness()
    let (meetingID, earlier) = try await readyMeeting(harness)
    harness.jobBehavior = Self.rerunResult
    harness.writeGate.failWrites { $0.state == .ready && $0.echoTurnIDs == ["mic-9"] }
    #expect(await harness.coordinator.transcribeAgain(meetingID: meetingID, engine: .parakeet))
    // #4218: the queue Task is set before `transcribeAgain` returns but claims `processing`
    // later, so the drain ending (not `processing == nil`) proves this pass ran.
    await eventually("pass over and settled") {
      !harness.coordinator.hasFinalPassWork
        && !harness.coordinator.isCommitReceiptPending(meetingID)
    }
    #expect(hasNoReceipt(harness, meetingID))
    #expect(harness.saved.count == 1, "the earlier row only")
    let info = MeetingWiring.historyInfo(harness.coordinator, meetingID: meetingID)
    #expect(info?.matching(earlier)?.echoTurnIDs == ["mic-3"])
    #expect(harness.coordinator.canTranscribeAgain(meetingID))
  }

  /// #3973 C2 (chunk review 1, confirming review): a ready write that landed but reported
  /// failure has committed the new transcript. The record read back is adopted, and a rename
  /// sent as the failure is reported (racing the read-back) waits for it, so neither it nor any
  /// later edit writes the older record over the commit; the new row is published.
  @Test("a ready write that lands but reports failure is adopted; a racing rename keeps the commit")
  func landedReadyWriteIsAdopted() async throws {
    let harness = try Harness()
    let (meetingID, earlier) = try await readyMeeting(harness)
    harness.jobBehavior = Self.rerunResult
    let coordinator = harness.coordinator
    harness.writeGate.failAfterLanding { $0.state == .ready && $0.echoTurnIDs == ["mic-9"] }
    harness.writeGate.onLandingFailure.withLock {
      $0 = { Task { @MainActor in await coordinator.rename(meetingID: meetingID, title: "Raced") } }
    }
    #expect(await harness.coordinator.transcribeAgain(meetingID: meetingID, engine: .parakeet))
    await eventually("published") {
      harness.saved.count == 2 && harness.coordinator.processing == nil
        && !harness.coordinator.isCommitReceiptPending(meetingID)
    }
    let committed = try #require(harness.saved.last?.meetingTranscriptAttemptID)
    #expect(harness.saved.last?.text == "hello again")
    #expect(harness.coordinator.record(id: meetingID)?.committedTranscriptGeneration == committed)
    #expect(hasNoReceipt(harness, meetingID))
    let info = MeetingWiring.historyInfo(harness.coordinator, meetingID: meetingID)
    #expect(info?.matching(earlier) == nil)

    await eventually("raced rename saved") {
      harness.coordinator.record(id: meetingID)?.title == "Raced"
    }
    var onDisk = try harness.store.load(id: meetingID)
    #expect(onDisk.committedTranscriptGeneration == committed, "the racing rename kept the commit")
    #expect(onDisk.echoTurnIDs == ["mic-9"])

    await harness.coordinator.rename(meetingID: meetingID, title: "Renamed")
    onDisk = try harness.store.load(id: meetingID)
    #expect(onDisk.title == "Renamed")
    #expect(onDisk.committedTranscriptGeneration == committed, "a later rename kept the commit")
  }

  /// #3973 C2 (second confirming review): when the record cannot even be read back, whether the
  /// ready write landed is unknown, so no rename writes the record (it could put the earlier
  /// record over a landed commit); the next launch decides from the file and publishes.
  @Test("a ready write whose outcome cannot be read back blocks record edits until the next launch")
  func unknownCommitBlocksEdits() async throws {
    let harness = try Harness()
    let (meetingID, _) = try await readyMeeting(harness)
    harness.jobBehavior = Self.rerunResult
    let recordURL = harness.store.recordURL(for: meetingID)
    let hidden = recordURL.appendingPathExtension("hidden")
    harness.writeGate.failAfterLanding { $0.state == .ready && $0.echoTurnIDs == ["mic-9"] }
    // The landed file is moved aside as the failure is reported, so the read-back fails.
    harness.writeGate.onLandingFailure.withLock {
      $0 = { try? FileManager.default.moveItem(at: recordURL, to: hidden) }
    }
    #expect(await harness.coordinator.transcribeAgain(meetingID: meetingID, engine: .parakeet))
    await eventually("pass over") { !harness.coordinator.hasFinalPassWork }
    #expect(harness.coordinator.isCommitReceiptPending(meetingID))
    await harness.coordinator.rename(meetingID: meetingID, title: "Refused")
    #expect(!FileManager.default.fileExists(atPath: recordURL.path), "the rename wrote nothing")
    await harness.coordinator.deleteAudio(meetingID: meetingID)
    #expect(!FileManager.default.fileExists(atPath: recordURL.path), "Delete audio wrote nothing")
    #expect(try !harness.store.segmentFiles(meeting: meetingID).isEmpty, "the audio stayed")
    try FileManager.default.moveItem(at: hidden, to: recordURL)
    #expect(try harness.store.load(id: meetingID).echoTurnIDs == ["mic-9"], "the landed commit")

    let relaunched = try Harness(copying: harness.root)
    relaunched.coordinator.launch()
    await eventually("published") { relaunched.saved.count == 1 }
    #expect(relaunched.saved.first?.text == "hello again")
  }

  /// #3973 C2 (chunk review 3): a summary is written from, and judged against, only the
  /// committed generation's row. While a committed replacement is not yet in History the row
  /// History holds is the earlier one, so it counts as no row.
  @Test("only the committed generation's row feeds a summary")
  func summariesReadOnlyTheCommittedRow() {
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    let legacyRow = Transcript(text: "a", meetingID: record.id)
    #expect(!MeetingWiring.isCommittedRow(legacyRow, of: record), "nothing committed")
    record.state = .ready
    #expect(MeetingWiring.isCommittedRow(legacyRow, of: record), "a legacy ready record and row")
    let attempt = MeetingAttemptConfiguration(requestedEngine: .parakeet, language: .auto)
    record.beginAttempt(attempt)
    record.commitAttempt(
      MeetingResolvedAttempt(
        attemptID: attempt.attemptID, requestedEngine: .parakeet, resolvedEngine: .parakeet,
        effectiveLanguage: nil, modelIdentity: nil, fallbackReason: nil))
    #expect(!MeetingWiring.isCommittedRow(legacyRow, of: record), "the earlier row, unpublished")
    let newRow = Transcript(
      text: "a", meetingID: record.id, meetingTranscriptAttemptID: attempt.attemptID)
    #expect(MeetingWiring.isCommittedRow(newRow, of: record))
  }

  @Test("Delete audio keeps an unsettled receipt; deleting the meeting removes it")
  func deletionAndReceipts() async throws {
    let harness = try Harness()
    let (meetingID, earlier) = try await readyMeeting(harness)
    let receipt = MeetingTranscriptReplacement(
      meetingID: meetingID, previous: nil, previousRow: nil,
      candidate: .init(generation: UUID(), echoTurnIDs: [], speakerOutcomes: [:]),
      candidateRow: earlier)
    try harness.store.saveTranscriptReplacement(receipt)
    try harness.store.deleteAudio(meeting: meetingID)
    #expect(self.receipt(harness, meetingID) != nil, "Delete audio keeps it")
    #expect(await harness.coordinator.delete(meetingID: meetingID))
    #expect(
      !FileManager.default.fileExists(
        atPath: harness.store.transcriptReplacementURL(for: meetingID).path))
  }

  @Test("a receipt round-trips; another format or another meeting's is unusable, never trusted")
  func receiptStorage() throws {
    let harness = try Harness()
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(record)
    #expect(hasNoReceipt(harness, record.id))
    let row = Transcript(
      id: record.transcriptID, text: "héllo 👋", meetingID: record.id,
      meetingTranscriptAttemptID: UUID())
    let saved = MeetingTranscriptReplacement(
      meetingID: record.id, previous: nil, previousRow: nil,
      candidate: .init(
        generation: try #require(row.meetingTranscriptAttemptID), echoTurnIDs: ["m1"],
        speakerOutcomes: [.microphone: .single]),
      candidateRow: row)
    try harness.store.saveTranscriptReplacement(saved)
    let loaded = try #require(receipt(harness, record.id))
    #expect(loaded.candidate == saved.candidate)
    #expect(loaded.candidateRow.text == "héllo 👋")
    #expect(loaded.candidateRow.meetingTranscriptAttemptID == row.meetingTranscriptAttemptID)

    // Another meeting's receipt in this folder, in the current format, is never trusted.
    let other = MeetingTranscriptReplacement(
      meetingID: UUID(), previous: nil, previousRow: nil, candidate: saved.candidate,
      candidateRow: row)
    try MeetingStore.encoder.encode(other)
      .write(to: harness.store.transcriptReplacementURL(for: record.id))
    guard case .unusable = harness.store.loadTranscriptReplacement(meeting: record.id) else {
      Issue.record("another meeting's receipt was trusted")
      return
    }
    try harness.store.saveTranscriptReplacement(saved)
    guard case .receipt = harness.store.loadTranscriptReplacement(meeting: record.id) else {
      Issue.record("the control receipt did not load")
      return
    }

    var object = try #require(
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: harness.store.transcriptReplacementURL(for: record.id)))
        as? [String: Any])
    object["formatVersion"] = 2
    try JSONSerialization.data(withJSONObject: object)
      .write(to: harness.store.transcriptReplacementURL(for: record.id))
    guard case .unusable = harness.store.loadTranscriptReplacement(meeting: record.id) else {
      Issue.record("a newer receipt format was trusted")
      return
    }
    // A meeting folder that is gone is never recreated by a late receipt.
    try harness.store.deleteFolder(meeting: record.id)
    #expect(throws: MeetingStore.StoreError.meetingMissing) {
      try harness.store.saveTranscriptReplacement(saved)
    }
  }
}
