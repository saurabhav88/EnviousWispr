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
            if let unavailable = world.unavailable { return .failure(unavailable) }
            return .success(
              MeetingSummaryProviders.Prepared(
                execution: world.execution,
                window: MeetingSummary.Window(contextTokens: 128_000, outputReserveTokens: 1_500),
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

  @Test("the decision at ready: off, no provider and cleanup models start nothing")
  func plans() throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.enabled = false
    #expect(rig.owner.plan(for: id) == .off)
    rig.world.enabled = true
    rig.world.provider = .none
    #expect(rig.owner.plan(for: id) == .noProvider)
    rig.world.provider = .egOne
    #expect(rig.owner.plan(for: id) == .unsupported)
    rig.world.provider = .ollama
    rig.world.model = "eg-1:q4"
    #expect(rig.owner.plan(for: id) == .unsupported)
    #expect(rig.owner.isWriting(id) == false)
    #expect(rig.world.finished.isEmpty, "no attempt, no row")
  }

  @Test("a scheduled summary is written from what History shows, with its inputs, once")
  func written() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    #expect(rig.owner.plan(for: id) == .scheduled)
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
    _ = rig.owner.plan(for: id)
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.stale, .hosted)])
    #expect(rig.summaryOnDisk(id) == "My own words")
    #expect(try rig.manifest(id).summaryPending == nil)

    rig.owner.writeAgain(id, replacingUserEdit: false)
    await Self.eventually("second") { rig.world.finished.count == 2 }
    #expect(rig.summaryOnDisk(id) == "My own words", "an unconfirmed Write again keeps it")

    rig.owner.writeAgain(id, replacingUserEdit: true)
    await Self.eventually("third") { rig.world.finished.count == 3 }
    #expect(rig.world.finished.last == Self.row(.written, .hosted))
    #expect(rig.summaryOnDisk(id) == "## Overview\nShip Friday.")
  }

  @Test("a meeting that changes while its summary is written keeps no stale answer")
  func staleAnswer() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.duringCall = { rig.world.speakerNames = ["mic:you": "Priya"] }
    _ = rig.owner.plan(for: id)
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
    _ = rig.owner.plan(for: id)
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
    _ = rig.owner.plan(for: first)
    _ = rig.owner.plan(for: second)
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
    _ = rig.owner.plan(for: id)
    await Self.eventually("waiting") { rig.lane.summaryWaiting == 1 }
    rig.documents.forget(id)
    rig.owner.cancel(id)
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
    _ = rig.owner.plan(for: id)
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
      _ = rig.owner.plan(for: id)
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
    await coordinator.start(from: .history)
    let meetingID = try #require(coordinator.meetings.first?.id)
    coordinator.documents.setNotes(meetingID, "Ask Priya")
    await coordinator.stop()
    await Self.eventually("ready") { coordinator.record(id: meetingID)?.state == .ready }
    let ended = try #require(harness.ended.last)
    #expect(ended.summaryPlan == .scheduled)
    #expect(ended.hasNotes)
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
}
