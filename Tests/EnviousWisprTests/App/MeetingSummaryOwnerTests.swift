import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprLLM
@testable import EnviousWisprStorage

/// #3972 R39, R46, R50, R54 (build chunk C13a): when these fail, a meeting gets no summary or
/// two, a summary overwrites the user's own text or describes a meeting that changed, a local
/// model runs beside dictation or a final pass, a deleted meeting is summarized, a quit loses
/// an owed summary, or `meeting.summary_finished` is sent zero or two times for one attempt.
@MainActor
@Suite("Meeting summary owner", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingSummaryOwnerTests {
  static func eventually(
    _ label: String, _ condition: @escaping @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    await MeetingCoordinatorTests.eventually(label, condition, sourceLocation: sourceLocation)
  }

  /// Everything the owner reads and sends, observable so `eventually` sees it change.
  @MainActor
  @Observable
  final class World {
    var enabled = true
    var provider: LLMProvider = .openAI
    var model = "gpt-4o-mini"
    var execution: MeetingSummary.Execution = .hosted
    var unavailable: MeetingSummaryProviders.Unavailable?
    var window = MeetingSummary.Window(contextTokens: 128_000, outputReserveTokens: 1_500)
    /// When set, preparation waits for `releasePrepare()`.
    var holdPrepare = false
    @ObservationIgnored private var heldPrepare: CheckedContinuation<Void, Never>?
    private(set) var preparing = false

    func prepare() async {
      guard holdPrepare else { return }
      preparing = true
      await withCheckedContinuation { heldPrepare = $0 }
      preparing = false
    }

    func releasePrepare() {
      heldPrepare?.resume()
      heldPrepare = nil
    }
    var transcript = "You: we ship Friday"
    var speakerNames = ["mic:you": "You"]
    var localTurn = true
    var finished: [MeetingSummaryFinishedTelemetry] = []
    var calls: [String] = []
    /// When set, every call waits for `releaseCall()`.
    var holdCalls = false
    var answer = "## Overview\nShip Friday."
    /// Runs inside the call, before it answers.
    @ObservationIgnored var duringCall: (@MainActor () -> Void)?
    @ObservationIgnored private var heldCalls: [CheckedContinuation<Void, Never>] = []
    private(set) var callsWaiting = 0

    func call(_ prompt: String) async -> String {
      calls.append(prompt)
      duringCall?()
      if holdCalls {
        callsWaiting += 1
        await withCheckedContinuation { heldCalls.append($0) }
        callsWaiting -= 1
      }
      return answer
    }

    func releaseCall() {
      guard !heldCalls.isEmpty else { return }
      heldCalls.removeFirst().resume()
    }
  }

  @MainActor
  final class Rig {
    let root: URL
    let store: MeetingStore
    let documents: MeetingDocumentsOwner
    let lane = MeetingLocalModelLane()
    let world = World()
    lazy var owner = makeOwner()

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingSummaryOwnerTests-\(UUID().uuidString)", isDirectory: true)
      store = MeetingStore(root: root)
      try store.prepareRoot()
      documents = Self.documents(store)
    }

    static func documents(_ store: MeetingStore) -> MeetingDocumentsOwner {
      MeetingDocumentsOwner(
        writer: MeetingFileWriter(store: store, writeRecord: { try $0.save($1) }),
        dependencies: .init(debounce: {}, log: { _ in }))
    }

    /// A ready meeting on disk.
    func readyMeeting() throws -> UUID {
      var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
      try store.create(record)
      record.state = .ready
      try store.save(record)
      return record.id
    }

    func makeOwner(documents: MeetingDocumentsOwner? = nil) -> MeetingSummaryOwner {
      let world = world
      return MeetingSummaryOwner(
        dependencies: .init(
          isEnabled: { world.enabled },
          selection: { (world.provider, world.model) },
          prepare: { _, _ in
            await world.prepare()
            if let unavailable = world.unavailable { return .failure(unavailable) }
            return .success(
              MeetingSummaryProviders.Prepared(
                execution: world.execution, window: world.window,
                complete: { @MainActor _, prompt in await world.call(prompt) }))
          },
          visibleTranscript: { _ in
            .init(text: world.transcript, speakerNames: world.speakerNames)
          },
          isLocalTurn: { world.localTurn },
          wakes: nil,
          emitFinished: { world.finished.append($0) },
          log: { _ in }),
        documents: documents ?? self.documents, lane: lane)
    }

    func summaryOnDisk(_ id: UUID) -> String? {
      try? String(contentsOf: store.summaryURL(for: id), encoding: .utf8)
    }

    func manifest(_ id: UUID) throws -> MeetingDocumentsManifest {
      try store.loadDocuments(meeting: id).manifest
    }
  }

  static func row(
    _ outcome: MeetingSummaryFinishedTelemetry.Outcome,
    _ kind: MeetingSummaryFinishedTelemetry.ProviderKind
  )
    -> MeetingSummaryFinishedTelemetry
  {
    MeetingSummaryFinishedTelemetry(outcome: outcome, providerKind: kind)
  }

  /// What the coordinator does at the ready barrier: decide, make an owed summary durable, then
  /// start it.
  static func schedule(_ rig: Rig, _ id: UUID) async -> MeetingEndedTelemetry.SummaryPlan {
    let plan = rig.owner.decide()
    if plan == .scheduled {
      await rig.documents.setSummaryPending(id, true)
      rig.owner.startOwed(id)
    }
    return plan
  }

  @Test("the decision at ready: off, no provider and cleanup models start nothing")
  func plans() throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.enabled = false
    #expect(rig.owner.decide() == .off)
    rig.world.enabled = true
    rig.world.provider = .none
    #expect(rig.owner.decide() == .noProvider)
    rig.world.provider = .egOne
    #expect(rig.owner.decide() == .unsupported)
    rig.world.provider = .ollama
    rig.world.model = "eg-1:q4"
    #expect(rig.owner.decide() == .unsupported)
    #expect(rig.owner.isWriting(id) == false)
    #expect(rig.world.finished.isEmpty, "no attempt, no row")
  }

  @Test("a scheduled summary is written from what History shows, with its inputs, once")
  func written() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    #expect(await Self.schedule(rig, id) == .scheduled)
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.written, .hosted)])
    #expect(rig.summaryOnDisk(id) == "## Overview\nShip Friday.")
    #expect(rig.world.calls.first?.contains("You: we ship Friday") == true)
    let manifest = try rig.manifest(id)
    #expect(manifest.summary?.origin == .generated)
    #expect(manifest.summaryPending == nil, "the attempt is over")
    let inputs = try #require(manifest.summary?.inputs)
    #expect(inputs.transcriptSHA256 == MeetingDocumentHash.sha256("You: we ship Friday"))
    #expect(inputs.providerID == "openAI")
    #expect(
      inputs.configurationSHA256
        == MeetingSummary.configurationFingerprint(provider: .openAI, model: "gpt-4o-mini"))
    #expect(inputs.speakerNamesSHA256 == MeetingSummaryOwner.speakerNamesSHA256(["mic:you": "You"]))
    #expect(rig.owner.activity[id] == nil)
  }

  @Test("the user's own summary is kept, and replaced only by a confirmed Write again")
  func userEditKept() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    _ = try rig.store.saveSummary("My own words", origin: .userEdited, inputs: nil, meeting: id)
    _ = await Self.schedule(rig, id)
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.stale, .hosted)])
    #expect(rig.summaryOnDisk(id) == "My own words")
    #expect(try rig.manifest(id).summaryPending == nil)

    rig.owner.writeAgain(id, replacing: nil)
    await Self.eventually("second") { rig.world.finished.count == 2 }
    #expect(rig.summaryOnDisk(id) == "My own words", "an unconfirmed Write again keeps it")

    rig.owner.writeAgain(id, replacing: MeetingDocumentHash.sha256("My own words"))
    await Self.eventually("third") { rig.world.finished.count == 3 }
    #expect(rig.world.finished.last == Self.row(.written, .hosted))
    #expect(rig.summaryOnDisk(id) == "## Overview\nShip Friday.")
  }

  @Test("a meeting that changes while its summary is written keeps no stale answer")
  func staleAnswer() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.duringCall = { rig.world.speakerNames = ["mic:you": "Priya"] }
    _ = await Self.schedule(rig, id)
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.stale, .hosted)])
    #expect(rig.summaryOnDisk(id) == nil)
    #expect(try rig.manifest(id).summaryPending == nil)
  }

  @Test("a local model waits for its turn and holds the lane only while it calls")
  func localTurn() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.execution = .local
    rig.world.localTurn = false
    rig.world.holdCalls = true
    _ = await Self.schedule(rig, id)
    await Self.eventually("waiting") { rig.lane.summaryWaiting == 1 }
    #expect(rig.owner.activity[id] == .waiting)
    #expect(rig.world.calls.isEmpty, "no call while dictation or meeting work has the turn")
    #expect(rig.lane.summaryActive, "previews give way to a waiting summary")
    #expect(rig.lane.summaryCallRunning == false, "a final pass may still run")

    rig.world.localTurn = true
    await Self.eventually("calling") { rig.world.callsWaiting == 1 }
    #expect(rig.lane.summaryCallRunning)
    #expect(rig.owner.activity[id] == .writing)
    rig.world.releaseCall()
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.written, .local)])
    #expect(rig.lane.summaryCallRunning == false)
    #expect(rig.lane.summaryActive == false)
  }

  @Test("local summaries run one after another")
  func localOneAtATime() async throws {
    let rig = try Rig()
    let first = try rig.readyMeeting()
    let second = try rig.readyMeeting()
    rig.world.execution = .local
    rig.world.holdCalls = true
    _ = await Self.schedule(rig, first)
    _ = await Self.schedule(rig, second)
    await Self.eventually("first calling") { rig.world.callsWaiting == 1 }
    #expect(rig.world.calls.count == 1, "the second waits for the whole first summary")
    #expect(rig.lane.summaryWaiting == 2)
    rig.world.releaseCall()
    await Self.eventually("second calling") {
      rig.world.calls.count == 2 && rig.world.callsWaiting == 1
    }
    rig.world.releaseCall()
    await Self.eventually("both") { rig.world.finished.count == 2 }
    #expect(rig.lane.summaryWaiting == 0)
  }

  @Test("deleting a meeting ends its summary: one cancelled row, nothing written")
  func deletion() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.execution = .local
    rig.world.localTurn = false
    _ = await Self.schedule(rig, id)
    await Self.eventually("waiting") { rig.lane.summaryWaiting == 1 }
    rig.documents.forget(id)
    await rig.owner.cancelAndWait(id)
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.cancelled, .local)])
    #expect(rig.world.calls.isEmpty)
    #expect(rig.summaryOnDisk(id) == nil)
    await Self.eventually("lane free") { rig.lane.summaryActive == false }
  }

  @Test("a quit leaves the summary owed and sends nothing; the relaunch finishes it once")
  func quitAndRelaunch() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.execution = .local
    rig.world.localTurn = false
    _ = await Self.schedule(rig, id)
    await Self.eventually("waiting") { rig.lane.summaryWaiting == 1 }
    #expect(try rig.manifest(id).summaryPending == true)
    rig.owner.prepareForTermination()
    await Self.eventually("stopped") { rig.lane.summaryActive == false }
    #expect(rig.world.finished.isEmpty, "the attempt is not over")
    #expect(try rig.manifest(id).summaryPending == true)

    // The relaunch: a new owner over fresh documents.
    rig.world.localTurn = true
    let relaunched = rig.makeOwner(documents: Rig.documents(rig.store))
    await relaunched.resumeOwed(readyMeetingIDs: [id])
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.written, .local)])
    #expect(try rig.manifest(id).summaryPending == nil)
    await relaunched.resumeOwed(readyMeetingIDs: [id])
    #expect(relaunched.isWriting(id) == false, "nothing is owed any more")
  }

  @Test("a provider that cannot write now is reported, and the summary is no longer owed")
  func problems() async throws {
    let cases:
      [(
        MeetingSummaryProviders.Unavailable, MeetingSummaryOwner.Problem,
        MeetingSummaryFinishedTelemetry.Outcome
      )] = [
        (.notReady, .notReady, .unsupported), (.ollamaTooOld, .ollamaTooOld, .unsupported),
        (.notForSummaries, .notForSummaries, .unsupported), (.noProvider, .noProvider, .noProvider),
      ]
    for (unavailable, problem, outcome) in cases {
      let rig = try Rig()
      let id = try rig.readyMeeting()
      rig.world.unavailable = unavailable
      _ = await Self.schedule(rig, id)
      await Self.eventually("finished") { rig.world.finished.count == 1 }
      #expect(
        rig.world.finished == [Self.row(outcome, outcome == .noProvider ? .none : .hosted)],
        "R57: none exactly with noProvider")
      #expect(rig.owner.activity[id] == .failed(problem))
      #expect(try rig.manifest(id).summaryPending == nil)
    }
  }

  // MARK: - With the coordinator

  @Test("meeting.ended carries the decision and the notes snapshot; a scheduled summary is written")
  func coordinatorReady() async throws {
    let harness = try MeetingCoordinatorTests.Harness()
    let rig = try Rig()
    let coordinator = harness.coordinator
    coordinator.summaries = rig.makeOwner(documents: coordinator.documents)
    // The owed mark is durable by the time the meeting is ready and its row is sent, so a quit
    // right then never loses the summary.
    var owedAtEnd: Bool?
    harness.onEnded = { _ in
      let id = coordinator.meetings.first?.id
      owedAtEnd = id.flatMap { try? harness.store.loadDocuments(meeting: $0).manifest.summaryPending }
    }
    await coordinator.start(from: .history)
    let meetingID = try #require(coordinator.meetings.first?.id)
    coordinator.documents.setNotes(meetingID, "Ask Priya")
    await coordinator.stop()
    await Self.eventually("ready") { coordinator.record(id: meetingID)?.state == .ready }
    let ended = try #require(harness.ended.last)
    #expect(ended.summaryPlan == .scheduled)
    #expect(ended.hasNotes)
    #expect(owedAtEnd == true, "owed on disk before the ready row")
    await Self.eventually("written") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.written, .hosted)])
    #expect(rig.world.calls.first?.contains("Ask Priya") == true, "the saved notes reach the call")
  }

  @Test("with the setting off, meeting.ended says off and nothing is written")
  func coordinatorOff() async throws {
    let harness = try MeetingCoordinatorTests.Harness()
    let rig = try Rig()
    rig.world.enabled = false
    let coordinator = harness.coordinator
    coordinator.summaries = rig.makeOwner(documents: coordinator.documents)
    await coordinator.start(from: .history)
    let meetingID = try #require(coordinator.meetings.first?.id)
    await coordinator.stop()
    await Self.eventually("ready") { coordinator.record(id: meetingID)?.state == .ready }
    #expect(harness.ended.last?.summaryPlan == .off)
    #expect(harness.ended.last?.hasNotes == false)
    #expect(rig.world.finished.isEmpty)
  }

  @Test("deleting a meeting from the coordinator ends its waiting summary")
  func coordinatorDelete() async throws {
    let harness = try MeetingCoordinatorTests.Harness()
    let rig = try Rig()
    rig.world.execution = .local
    rig.world.localTurn = false
    let coordinator = harness.coordinator
    coordinator.summaries = rig.makeOwner(documents: coordinator.documents)
    await coordinator.start(from: .history)
    let meetingID = try #require(coordinator.meetings.first?.id)
    await coordinator.stop()
    await Self.eventually("waiting") { rig.lane.summaryWaiting == 1 }
    await coordinator.delete(meetingID: meetingID)
    await Self.eventually("cancelled") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.cancelled, .local)])
    #expect(rig.world.calls.isEmpty)
  }

  // MARK: - Drains, settling and fences (Codex C13a r1)

  /// Makes every `documents.json` write fail: the file is a directory, so the atomic replace
  /// throws. Returns the undo.
  static func breakManifest(_ rig: Rig, _ id: UUID) throws -> () throws -> Void {
    let url = rig.store.documentsURL(for: id)
    let saved = try? Data(contentsOf: url)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return {
      try FileManager.default.removeItem(at: url)
      if let saved { try saved.write(to: url) }
    }
  }

  @Test("a call in flight holds a relaunch; a deletion returns only once the call has ended")
  func drains() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.holdCalls = true
    _ = await Self.schedule(rig, id)
    await Self.eventually("calling") { rig.world.callsWaiting == 1 }
    #expect(rig.owner.hasWorkInFlight, "a relaunch waits for a hosted call")
    rig.documents.forget(id)
    let deletion = Task { await rig.owner.cancelAndWait(id) }
    // The held call ignores cancellation, as a slow provider may: the deletion waits for it.
    await Task.yield()
    #expect(rig.owner.isWriting(id), "still draining")
    rig.world.releaseCall()
    await deletion.value
    #expect(rig.owner.isWriting(id) == false)
    #expect(rig.owner.hasWorkInFlight == false)
    #expect(rig.summaryOnDisk(id) == nil, "nothing is saved for a deleted meeting")
    #expect(rig.world.finished == [Self.row(.cancelled, .hosted)])
  }

  @Test("a local summary waiting for its turn does not hold a relaunch")
  func waitingDoesNotHoldRelaunch() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.execution = .local
    rig.world.localTurn = false
    _ = await Self.schedule(rig, id)
    await Self.eventually("waiting") { rig.lane.summaryWaiting == 1 }
    #expect(rig.owner.hasWorkInFlight == false, "it is owed on disk and resumes")
    rig.owner.prepareForTermination()
  }

  @Test("a quit right after the start sends nothing and leaves the summary owed")
  func quitBeforeTheTaskRuns() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    await rig.documents.setSummaryPending(id, true)
    rig.owner.startOwed(id)
    rig.owner.prepareForTermination()
    await Self.eventually("stopped") { !rig.owner.isWriting(id) }
    #expect(rig.world.finished.isEmpty)
    #expect(try rig.manifest(id).summaryPending == true)
  }

  @Test("a mark that cannot be cleared leaves the attempt owed and silent; a relaunch settles it once")
  func unsettledAttempt() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.unavailable = .notReady
    _ = await Self.schedule(rig, id)
    let undo = try Self.breakManifest(rig, id)
    await Self.eventually("failed") { rig.owner.activity[id] == .failed(.storageFailed) }
    #expect(rig.world.finished.isEmpty, "not settled, so no row yet")

    try undo()
    #expect(try rig.manifest(id).summaryPending == true)
    let relaunched = rig.makeOwner(documents: Rig.documents(rig.store))
    await relaunched.resumeOwed(readyMeetingIDs: [id])
    await Self.eventually("settled") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.unsupported, .hosted)])
    #expect(try rig.manifest(id).summaryPending == nil)
  }

  @Test("Write again with no mark written ends at once with one failed row")
  func writeAgainWithoutMark() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    let undo = try Self.breakManifest(rig, id)
    rig.owner.writeAgain(id, replacing: nil)
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.failed, .hosted)], "R57: a hosted kind, never none")
    #expect(rig.world.calls.isEmpty)
    try undo()
  }

  @Test("an edit made after confirming Write again is kept")
  func editAfterConfirmationKept() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    _ = try rig.store.saveSummary("My own words", origin: .userEdited, inputs: nil, meeting: id)
    rig.world.holdCalls = true
    rig.owner.writeAgain(id, replacing: MeetingDocumentHash.sha256("My own words"))
    await Self.eventually("calling") { rig.world.callsWaiting == 1 }
    _ = try rig.store.saveSummary("Newer words", origin: .userEdited, inputs: nil, meeting: id)
    rig.world.releaseCall()
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.stale, .hosted)])
    #expect(rig.summaryOnDisk(id) == "Newer words")
  }

  @Test("a rename while the save is parked after its check: saved with the old names, counted stale")
  func changeDuringSave() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    var release: DispatchSemaphore?
    // The file queue is held from inside the call, so the save the owner queues after its
    // pre-save check is parked behind it.
    rig.world.duringCall = { release = MeetingDocumentsOwnerTests.holdFileQueue() }
    _ = await Self.schedule(rig, id)
    // The call has happened (the queue is held), and the save it queued is waiting behind it.
    // The plain wait: `eventually` also drains the file queue, which the hold blocks.
    await MeetingWorkAdmission.waitUntil {
      rig.world.calls.count == 1 && rig.documents.hasPendingWork
    }
    rig.world.speakerNames = ["mic:you": "Priya"]
    try #require(release).signal()
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.stale, .hosted)], "the post-save check saw the rename")
    #expect(rig.summaryOnDisk(id) == "## Overview\nShip Friday.", "the save itself went through")
    let inputs = try #require(try rig.manifest(id).summary?.inputs)
    #expect(
      inputs.speakerNamesSHA256 == MeetingSummaryOwner.speakerNamesSHA256(["mic:you": "You"]),
      "it records the names it was written from, so it shows out of date")
  }

  @Test("a mark that cannot be written at ready still ends with exactly one row")
  func markWriteFailsAtReady() async throws {
    let harness = try MeetingCoordinatorTests.Harness()
    let rig = try Rig()
    let coordinator = harness.coordinator
    let owner = rig.makeOwner(documents: coordinator.documents)
    coordinator.summaries = owner
    await coordinator.start(from: .history)
    let meetingID = try #require(coordinator.meetings.first?.id)
    let url = harness.store.documentsURL(for: meetingID)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    // Settled in the same turn as the ready row: read at that moment.
    var rowsAtEnd: [MeetingSummaryFinishedTelemetry]?
    harness.onEnded = { _ in rowsAtEnd = rig.world.finished }
    await coordinator.stop()
    await Self.eventually("ready") { coordinator.record(id: meetingID)?.state == .ready }
    #expect(harness.ended.last?.summaryPlan == .scheduled)
    #expect(rowsAtEnd == [], "nothing settled before the ready row")
    #expect(rig.world.finished == [Self.row(.failed, .hosted)], "settled at once, no attempt to lose")
    #expect(owner.isWriting(meetingID) == false, "no attempt was started")
    #expect(owner.activity[meetingID] == .failed(.storageFailed))
    #expect(rig.world.calls.isEmpty, "nothing is written without its mark")
    try FileManager.default.removeItem(at: url)
  }

  @Test("a replaced attempt never ends the new one, and a deletion waits for both")
  func replacedAttempts() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.holdCalls = true
    _ = await Self.schedule(rig, id)
    await Self.eventually("A calling") { rig.world.callsWaiting == 1 }
    rig.owner.writeAgain(id, replacing: nil)
    await Self.eventually("B calling") { rig.world.callsWaiting == 2 }
    // A's call ignores cancellation and ends first; B stays the current attempt.
    rig.world.releaseCall()
    await Self.eventually("A settled") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.cancelled, .hosted)])
    #expect(rig.owner.isWriting(id), "B is still the meeting's attempt")

    // A third attempt C replaces B while B still runs; deleting waits for both B and C.
    rig.owner.writeAgain(id, replacing: nil)
    await Self.eventually("C calling") { rig.world.callsWaiting == 2 }
    rig.documents.forget(id)
    let deletion = Task { await rig.owner.cancelAndWait(id) }
    rig.world.releaseCall()
    await Task.yield()
    #expect(rig.world.finished.count < 3, "the deletion is still draining C")
    rig.world.releaseCall()
    await deletion.value
    #expect(rig.world.finished.count == 3)
    #expect(rig.summaryOnDisk(id) == nil)
  }

  @Test("a quit during preparation keeps the summary owed and silent; a deletion is a cancel")
  func cancelledDuringPreparation() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.holdPrepare = true
    rig.world.unavailable = .notReady
    _ = await Self.schedule(rig, id)
    await Self.eventually("preparing") { rig.world.preparing }
    rig.owner.prepareForTermination()
    rig.world.releasePrepare()
    await Self.eventually("stopped") { !rig.owner.isWriting(id) }
    #expect(rig.world.finished.isEmpty)
    #expect(try rig.manifest(id).summaryPending == true)

    let other = try Rig()
    let doomed = try other.readyMeeting()
    other.world.holdPrepare = true
    other.world.unavailable = .notReady
    _ = await Self.schedule(other, doomed)
    await Self.eventually("preparing") { other.world.preparing }
    other.documents.forget(doomed)
    let deletion = Task { await other.owner.cancelAndWait(doomed) }
    await Task.yield()
    other.world.releasePrepare()
    await deletion.value
    #expect(other.world.finished == [Self.row(.cancelled, .hosted)])
  }

  @Test("a summary paused for its turn between two calls does not hold a relaunch")
  func pausedBetweenCalls() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.execution = .local
    rig.world.window = MeetingSummary.Window(contextTokens: 4_096, outputReserveTokens: 1_500)
    rig.world.transcript = Array(repeating: "Speaker 1: " + String(repeating: "word ", count: 60), count: 120)
      .joined(separator: "\n")
    // After the first call, dictation takes the turn.
    rig.world.duringCall = { rig.world.localTurn = false }
    _ = await Self.schedule(rig, id)
    await Self.eventually("paused") { rig.world.calls.count == 1 && rig.owner.activity[id] == .waiting }
    #expect(rig.owner.hasWorkInFlight == false, "owed on disk; a relaunch may go ahead")
    #expect(rig.lane.summaryCallRunning == false)
    rig.world.duringCall = nil
    rig.world.localTurn = true
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.written, .local)])
  }

  @Test("deleting a recording with notes reports has_notes")
  func deletionKeepsNotesFact() async throws {
    let harness = try MeetingCoordinatorTests.Harness()
    let rig = try Rig()
    let coordinator = harness.coordinator
    coordinator.summaries = rig.makeOwner(documents: coordinator.documents)
    await coordinator.start(from: .history)
    let meetingID = try #require(coordinator.meetings.first?.id)
    coordinator.documents.setNotes(meetingID, "Ask Priya")
    await coordinator.delete(meetingID: meetingID)
    let ended = try #require(harness.ended.last)
    #expect(ended.outcome == .deletedBeforeReady)
    #expect(ended.hasNotes)
  }

  @Test("a queued meeting the queue cannot run never holds summaries back")
  func unrunnableQueueDoesNotBlock() async throws {
    let harness = try MeetingCoordinatorTests.Harness()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try harness.store.create(record)
    record.state = .queued
    try harness.store.save(record)
    // Too little disk: the queue stops and leaves the meeting queued.
    harness.freeBytes = 10_000_000
    let coordinator = harness.coordinator
    coordinator.launch()
    await Self.eventually("listed") { coordinator.record(id: record.id) != nil }
    await Self.eventually("queue stopped") { !coordinator.hasFinalPassWork }
    #expect(coordinator.record(id: record.id)?.state == .queued)
  }

  @Test("an attempt replaced while its failing clear waits still settles once; nothing stays owed")
  func replacedDuringFailedClear() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.unavailable = .notReady
    // A ends at once (not ready); its clear is parked behind a held file queue, held right
    // after A starts and before its task runs.
    await rig.documents.setSummaryPending(id, true)
    rig.owner.startOwed(id)
    let hold = MeetingDocumentsOwnerTests.holdFileQueue()
    await MeetingWorkAdmission.waitUntil { rig.documents.hasPendingWork }
    // A's clear will fail; the manifest is restored right after it, before B's own writes.
    let undo = try Self.breakManifest(rig, id)
    MeetingFileWriter.queue.async { try? undo() }
    rig.owner.writeAgain(id, replacing: nil)
    hold.signal()
    await Self.eventually("both settled") { rig.world.finished.count == 2 }
    #expect(rig.world.finished == [Self.row(.unsupported, .hosted), Self.row(.unsupported, .hosted)])
    #expect(try rig.manifest(id).summaryPending == nil, "no owed work is left")
    #expect(rig.owner.isWriting(id) == false)
  }
}
