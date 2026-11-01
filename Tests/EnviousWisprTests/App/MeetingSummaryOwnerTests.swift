import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprLLM
@testable import EnviousWisprStorage
import EnviousWisprAppKitTestSupport

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
    /// False: History cannot show the meeting now (its facts are not available).
    var visible = true
    /// #4148: the meeting is known and ready, but has no visible transcript text.
    var noWords = false
    var speakerNames = ["mic:you": "You"]
    /// #4286: what the summary is told about the meeting.
    var facts: MeetingPromptFacts?
    /// #3973 C2: the shown History row's transcript attempt.
    var transcriptAttemptID: UUID?
    var localTurn = true
    /// When set, replaces `localTurn` (production also waits for final-pass work).
    @ObservationIgnored var localTurnCheck: (@MainActor () -> Bool)?
    var finished: [MeetingSummaryFinishedTelemetry] = []
    /// #4012: titles the owner handed to the coordinator, in order.
    var titles: [String] = []
    var calls: [String] = []
    /// When set, every call waits for `releaseCall()`.
    var holdCalls = false
    var answer = "## Overview\nShip Friday."
    /// Runs inside the call, before it answers.
    @ObservationIgnored var duringCall: (@MainActor () -> Void)?
    @ObservationIgnored private var heldCalls: [CheckedContinuation<Void, Never>] = []
    private(set) var callsWaiting = 0

    /// #4286: when true, the next call answers that its input was too long (once).
    var overflowNext = false

    func call(_ prompt: String) async throws -> String {
      calls.append(prompt)
      if overflowNext {
        overflowNext = false
        throw LLMError.classified(.inputTooLong)
      }
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
      root = TestTemporaryDirectory.url
        .appendingPathComponent("MeetingSummaryOwnerTests-\(UUID().uuidString)", isDirectory: true)
      store = MeetingStore(root: root)
      try store.prepareRoot()
      documents = Self.documents(store)
    }

    /// The same store, with other documents (a test's own debounce).
    init(sharing other: Rig, documents: MeetingDocumentsOwner) throws {
      root = other.root
      store = other.store
      self.documents = documents
    }

    static func documents(
      _ store: MeetingStore, debounce: @escaping @Sendable () async -> Void = {},
      afterGeneratedWrite: @escaping @MainActor () async -> Void = {}
    ) -> MeetingDocumentsOwner {
      MeetingDocumentsOwner(
        writer: MeetingFileWriter(store: store, writeRecord: { try $0.save($1) }),
        dependencies: .init(
          debounce: debounce, log: { _ in }, afterGeneratedWrite: afterGeneratedWrite))
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
                complete: { @MainActor _, prompt in try await world.call(prompt) }))
          },
          visibleTranscript: { _ in
            world.visible && !world.noWords
              ? .init(
                text: world.transcript, speakerNames: world.speakerNames,
                transcriptAttemptID: world.transcriptAttemptID) : nil
          },
          hasNoWords: { _ in world.visible && world.noWords },
          promptFacts: { _ in world.facts },
          isLocalTurn: { world.localTurnCheck?() ?? world.localTurn },
          wakes: nil,
          emitFinished: { world.finished.append($0) },
          log: { _ in },
          assignTitle: { _, title in world.titles.append(title) }),
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

  @Test("turning the setting off does not stop a summary already started, nor one owed at relaunch")
  func offAfterStart() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.holdCalls = true
    #expect(await Self.schedule(rig, id) == .scheduled)
    await Self.eventually("calling") { rig.world.callsWaiting == 1 }
    rig.world.enabled = false
    rig.world.releaseCall()
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.written, .hosted)])
    #expect(rig.summaryOnDisk(id) == "## Overview\nShip Friday.")

    // An owed summary found at relaunch with the setting off is still written.
    let owed = try rig.readyMeeting()
    rig.world.holdCalls = false
    await rig.documents.setSummaryPending(owed, true)
    let relaunched = rig.makeOwner(documents: Rig.documents(rig.store))
    await relaunched.resumeOwed(readyMeetingIDs: [owed])
    await Self.eventually("owed finished") { rig.world.finished.count == 2 }
    #expect(rig.summaryOnDisk(owed) == "## Overview\nShip Friday.")
    #expect(try rig.manifest(owed).summaryPending == nil)
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

  @Test("#4012: the answer's Title line names the meeting and never reaches the saved summary")
  func aiTitle() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.answer = "Title: Friday launch plan\n## Overview\nShip Friday."
    _ = await Self.schedule(rig, id)
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.summaryOnDisk(id) == "## Overview\nShip Friday.")
    #expect(rig.world.titles == ["Friday launch plan"])
  }

  @Test("#4012: an answer that is only a Title line keeps the summary saved before")
  func titleOnlyKeepsSummary() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    _ = await Self.schedule(rig, id)
    await Self.eventually("first") { rig.world.finished.count == 1 }
    #expect(rig.summaryOnDisk(id) == "## Overview\nShip Friday.")
    rig.world.answer = "Title: Launch planning"
    rig.owner.writeAgain(id, replacing: nil)
    await Self.eventually("second") { rig.world.finished.count == 2 }
    #expect(rig.summaryOnDisk(id) == "## Overview\nShip Friday.")
    #expect(rig.world.titles.isEmpty)
  }

  @Test("#4012: with the summary setting off, Write again saves the summary but names nothing")
  func aiTitleNeedsTheSetting() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.enabled = false
    rig.world.answer = "Title: Friday launch plan\n## Overview\nShip Friday."
    rig.owner.writeAgain(id, replacing: nil)
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.summaryOnDisk(id) == "## Overview\nShip Friday.")
    #expect(rig.world.titles.isEmpty)
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

  static let acmeFacts = MeetingPromptFacts(
    startedAt: Date(timeIntervalSinceReferenceDate: 815_000_000), recordedDurationMs: 2_700_000,
    callAppName: "Zoom", calendarTitle: "Acme renewal",
    participants: MeetingParticipants.resolve(attendees: [
      AttendeeFact(
        name: "Dana Lee", email: "dana@acme.com", role: .required, status: .accepted,
        isSelf: false, isOrganizer: true)
    ]))

  @Test("#4286: the summary is told the meeting facts and records their fingerprint")
  func factsSentAndFingerprinted() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.facts = Self.acmeFacts
    _ = await Self.schedule(rig, id)
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.written, .hosted)])
    let block = MeetingSummary.factsBlock(Self.acmeFacts)
    #expect(rig.world.calls.first?.contains(block) == true)
    #expect(rig.world.calls.first?.contains("Dana Lee (acme.com, organizer)") == true)
    let inputs = try #require(try rig.manifest(id).summary?.inputs)
    #expect(inputs.contextSHA256 == MeetingDocumentHash.sha256(block))
    #expect(rig.owner.isOutOfDate(id) == false)

    rig.world.facts?.calendarTitle = "Acme renewal (moved)"
    #expect(rig.owner.isOutOfDate(id), "a changed fact makes the summary out of date")
  }

  @Test("#4286: without facts nothing is fingerprinted, and facts arriving later make it out of date")
  func noFactsThenFacts() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    _ = await Self.schedule(rig, id)
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(try rig.manifest(id).summary?.inputs?.contextSHA256 == nil)
    #expect(rig.world.calls.first?.contains("Meeting facts") == false)
    #expect(rig.owner.isOutOfDate(id) == false)
    rig.world.facts = Self.acmeFacts
    #expect(rig.owner.isOutOfDate(id))
  }

  @Test("#4286: facts that change while the summary is written keep no stale answer")
  func factsChangeDuringCall() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.facts = Self.acmeFacts
    rig.world.duringCall = { rig.world.facts?.calendarTitle = "Other meeting" }
    _ = await Self.schedule(rig, id)
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.stale, .hosted)])
    #expect(rig.summaryOnDisk(id) == nil)
  }

  @Test("#4286: at a 4,096-token window the saved fingerprint is of the exact block sent, also after a re-plan")
  func smallWindowHashMatchesSent() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.window = MeetingSummary.Window(
      contextTokens: 4_096, outputReserveTokens: MeetingSummary.outputTokens)
    rig.world.execution = .local
    var facts = Self.acmeFacts
    facts.participants = MeetingParticipants.resolve(
      attendees: (1...6).map {
        AttendeeFact(
          name: "Person \($0)", email: "p\($0)@acme.com", role: .required, status: .accepted,
          isSelf: false, isOrganizer: false)
      })
    rig.world.facts = facts
    rig.world.overflowNext = true
    _ = await Self.schedule(rig, id)
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.written, .local)])
    let block = MeetingSummary.factsBlock(facts)
    #expect(rig.world.calls.count == 2, "the estimate call, then the byte re-plan")
    #expect(rig.world.calls.allSatisfy { $0.contains(block) })
    let inputs = try #require(try rig.manifest(id).summary?.inputs)
    #expect(inputs.contextSHA256 == MeetingDocumentHash.sha256(block))
  }

  @Test("#4286: a block too long for a 4,096-token byte re-plan fails the summary, never drops the facts")
  func smallWindowFactsTooLongFails() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.window = MeetingSummary.Window(
      contextTokens: 4_096, outputReserveTokens: MeetingSummary.outputTokens)
    rig.world.execution = .local
    var facts = Self.acmeFacts
    facts.participants = MeetingParticipants.resolve(
      attendees: (1...25).map {
        AttendeeFact(
          name: "Participant Number \($0)", email: "participant.\($0)@example.org",
          role: .required, status: .accepted, isSelf: false, isOrganizer: false)
      })
    rig.world.facts = facts
    rig.world.overflowNext = true
    _ = await Self.schedule(rig, id)
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.world.calls.count == 1, "the byte plan was refused before any call")
    #expect(rig.world.calls.first?.contains(MeetingSummary.factsBlock(facts)) == true)
    #expect(rig.summaryOnDisk(id) == nil)
    #expect(rig.owner.activity[id] == .failed(.notForSummaries))
  }

  @Test("#4286: a summary the user wrote is not made out of date by facts")
  func userSummaryIgnoresFacts() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    try #require(await rig.documents.load(id))
    rig.documents.setSummary(id, "My own summary")
    #expect(await rig.documents.flushSummary(id))
    rig.world.facts = Self.acmeFacts
    #expect(rig.owner.isOutOfDate(id) == false)
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

  /// #4287: dictation's Ollama eviction must not unload the model a summary call is using.
  @Test("a running local Ollama call pins its own model until the call physically ends")
  func runningOllamaCallPinsItsModel() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.provider = .ollama
    rig.world.model = "mistral"
    rig.world.execution = .local
    rig.world.localTurn = false
    rig.world.holdCalls = true
    _ = await Self.schedule(rig, id)
    await Self.eventually("waiting") { rig.lane.summaryWaiting == 1 }
    #expect(rig.owner.summaryPinnedOllamaModel == nil, "waiting for a turn pins nothing")

    rig.world.localTurn = true
    await Self.eventually("calling") { rig.world.callsWaiting == 1 }
    #expect(rig.owner.summaryPinnedOllamaModel == "mistral")
    rig.world.model = "llama3"
    #expect(rig.owner.summaryPinnedOllamaModel == "mistral", "the attempt's own model, not the setting")

    rig.world.releaseCall()
    await Self.eventually("finished") { rig.world.finished.count == 1 }
    #expect(rig.owner.summaryPinnedOllamaModel == nil)
  }

  @Test("hosted Ollama and local non-Ollama calls pin no Ollama model")
  func onlyLocalOllamaPins() async throws {
    for (provider, execution) in [
      (LLMProvider.ollama, MeetingSummary.Execution.hosted), (.appleIntelligence, .local),
    ] {
      let rig = try Rig()
      let id = try rig.readyMeeting()
      rig.world.provider = provider
      rig.world.model = "mistral"
      rig.world.execution = execution
      rig.world.holdCalls = true
      _ = await Self.schedule(rig, id)
      await Self.eventually("calling") { rig.world.callsWaiting == 1 }
      #expect(rig.owner.summaryPinnedOllamaModel == nil, "\(provider) \(execution)")
      rig.world.releaseCall()
      await Self.eventually("finished") { rig.world.finished.count == 1 }
    }
  }

  @Test("a deleted meeting's call keeps its pin until the call ends, then releases it")
  func cancelledCallReleasesPinAtItsEnd() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.provider = .ollama
    rig.world.model = "mistral"
    rig.world.execution = .local
    rig.world.holdCalls = true
    _ = await Self.schedule(rig, id)
    await Self.eventually("calling") { rig.world.callsWaiting == 1 }
    rig.documents.forget(id)
    let deletion = Task { await rig.owner.cancelAndWait(id) }
    // `cancelAndWait` clears the activity and cancels the attempt in one main-actor step.
    await Self.eventually("cancelling") { rig.owner.activity[id] == nil }
    #expect(rig.world.callsWaiting == 1, "the cancelled call is still physically running")
    #expect(rig.owner.summaryPinnedOllamaModel == "mistral", "the call still runs")
    rig.world.releaseCall()
    await deletion.value
    await Self.eventually("released") { rig.owner.summaryPinnedOllamaModel == nil }
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

  @Test("#4148: known empty input settles as nothing to summarize; unavailable input still cancels")
  func emptyInputOutcome() async throws {
    for noWords in [true, false] {
      let rig = try Rig()
      let id = try rig.readyMeeting()
      rig.world.noWords = noWords
      rig.world.visible = noWords
      #expect(await Self.schedule(rig, id) == .scheduled)
      await Self.eventually("settled") { rig.world.finished.count == 1 }
      #expect(
        rig.world.finished == [Self.row(noWords ? .nothingToSummarize : .cancelled, .hosted)])
      #expect(rig.world.calls.isEmpty)
      #expect(rig.summaryOnDisk(id) == nil)
      #expect(try rig.manifest(id).summaryPending == nil)
      #expect(rig.owner.activity[id] == nil)
    }
  }

  @Test("#4148: a direct Write on an empty meeting settles; later words are summarized")
  func emptyWriteRequest() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.noWords = true
    #expect(rig.owner.hasNothingToSummarize(id))
    #expect(await rig.owner.requestWrite(id) == .started)
    await Self.eventually("empty settled") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.nothingToSummarize, .hosted)])
    #expect(rig.world.calls.isEmpty)
    rig.world.noWords = false
    #expect(rig.owner.hasNothingToSummarize(id) == false)
    #expect(await rig.owner.requestWrite(id) == .started)
    await Self.eventually("written") { rig.world.finished.count == 2 }
    #expect(rig.world.finished.last == Self.row(.written, .hosted))
    rig.world.noWords = true
    #expect(rig.owner.isOutOfDate(id), "a generated summary whose words are gone is out of date")
    #expect(rig.documents.summary(id) != nil, "and stays visible")
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
    await MeetingCoordinatorTests.livePassFinished(coordinator, meetingID)
    let ended = try #require(harness.ended.last)
    #expect(ended.summaryPlan == .scheduled)
    #expect(ended.hasNotes)
    #expect(owedAtEnd == true, "owed on disk before the ready row")
    await Self.eventually("written") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.written, .hosted)])
    #expect(rig.world.calls.first?.contains("Ask Priya") == true, "the saved notes reach the call")
  }

  /// #3973 C2 (plan §3 item 6): a summary still being written over the earlier transcript
  /// settles before the replacement commits, and the replacement schedules no new summary: the
  /// existing one (if any) stays, out of date, until Write again.
  @Test("Transcribe again: a running summary settles first, and the replacement writes no new summary")
  func retryKeepsTheNewMark() async throws {
    let harness = try MeetingCoordinatorTests.Harness()
    let rig = try Rig()
    let coordinator = harness.coordinator
    coordinator.summaries = rig.makeOwner(documents: coordinator.documents)
    rig.world.holdCalls = true
    await coordinator.start(from: .history)
    let meetingID = try #require(coordinator.meetings.first?.id)
    await coordinator.stop()
    await Self.eventually("old call") { rig.world.callsWaiting == 1 }
    let previous: UUID
    do {
      previous = try #require(coordinator.record(id: meetingID)?.committedTranscriptGeneration)
    } catch {
      rig.world.releaseCall()
      throw error
    }

    await MeetingCoordinatorTests.transcribeAgainOnceOffered(coordinator, meetingID: meetingID)
    await Self.eventually("retry pass running") { coordinator.processing?.meetingID == meetingID }
    // The new transcript waits for the old summary: it is not committed while that call runs.
    // settle: bounded negative window; it cannot prove "never", only expose an early start
    try await Task.sleep(for: .milliseconds(200))
    #expect(coordinator.record(id: meetingID)?.state == .processing)
    #expect(rig.world.finished.isEmpty)

    rig.world.releaseCall()
    await Self.eventually("old settled") { rig.world.finished.count == 1 }
    #expect(rig.world.finished == [Self.row(.cancelled, .hosted)])
    await MeetingCoordinatorTests.livePassFinished(coordinator, meetingID, replacing: previous)
    #expect(harness.ended.last?.summaryPlan == .notApplicable)
    #expect(
      try harness.store.loadDocuments(meeting: meetingID).manifest.summaryPending != true,
      "nothing is owed")
    // settle: bounded negative window; it cannot prove "never", only expose an early start
    try await Task.sleep(for: .milliseconds(200))
    #expect(rig.world.callsWaiting == 0)
    #expect(rig.world.finished.count == 1)
  }

  /// #3973 C2 (chunk review 2): a first transcript is committed before its History row is
  /// written. When the row cannot be written, the scheduled summary stays owed (never started
  /// against a missing transcript, never dropped) until a launch publishes the row.
  @Test("an unpublished first transcript keeps its summary owed until a launch publishes it")
  func unpublishedFirstTranscriptKeepsItsSummaryOwed() async throws {
    let harness = try MeetingCoordinatorTests.Harness()
    harness.saveError = CocoaError(.fileWriteOutOfSpace)
    let rig = try Rig()
    let coordinator = harness.coordinator
    coordinator.summaries = rig.makeOwner(documents: coordinator.documents)
    await coordinator.start(from: .history)
    let meetingID = try #require(coordinator.meetings.first?.id)
    await coordinator.stop()
    await MeetingCoordinatorTests.livePassFinished(coordinator, meetingID)
    #expect(rig.world.finished.isEmpty, "no summary without a published row")
    #expect(try harness.store.loadDocuments(meeting: meetingID).manifest.summaryPending == true)

    // A launch that still cannot publish leaves it owed.
    let stuck = try MeetingCoordinatorTests.Harness(copying: harness.root)
    stuck.saveError = CocoaError(.fileWriteOutOfSpace)
    let stuckRig = try Rig()
    stuck.coordinator.summaries = stuckRig.makeOwner(documents: stuck.coordinator.documents)
    stuck.coordinator.launch()
    // #4218: the receipt is pending from reconciliation, before launch tries to publish; wait
    // for the publication attempt itself (recorded before it fails).
    await Self.eventually("publication tried") {
      stuck.coordinator.isCommitReceiptPending(meetingID) && stuck.saveRequests.count == 1
    }
    // settle: bounded negative window; it cannot prove "never", only expose an early start
    try await Task.sleep(for: .milliseconds(300))
    #expect(stuckRig.world.finished.isEmpty)
    #expect(stuckRig.world.callsWaiting == 0)
    #expect(try stuck.store.loadDocuments(meeting: meetingID).manifest.summaryPending == true)

    // A launch that publishes the row then resumes the owed summary.
    let healed = try MeetingCoordinatorTests.Harness(copying: stuck.root)
    let healedRig = try Rig()
    healed.coordinator.summaries = healedRig.makeOwner(documents: healed.coordinator.documents)
    healed.coordinator.launch()
    await Self.eventually("published") { healed.saved.count == 1 }
    await Self.eventually("written") { healedRig.world.finished.count == 1 }
    #expect(healedRig.world.finished == [Self.row(.written, .hosted)])
  }

  @Test("Transcribe again on a meeting whose local summary waits behind another never deadlocks")
  func retryBehindAWaitingLocalSummary() async throws {
    let harness = try MeetingCoordinatorTests.Harness()
    let rig = try Rig()
    let coordinator = harness.coordinator
    coordinator.summaries = rig.makeOwner(documents: coordinator.documents)
    rig.world.execution = .local
    // As production: a local call waits for dictation and for any final-pass work (R50).
    rig.world.localTurn = false
    rig.world.localTurnCheck = { [world = rig.world] in
      world.localTurn && !coordinator.hasFinalPassWork
    }
    await coordinator.start(from: .history)
    let first = try #require(coordinator.meetings.first?.id)
    await coordinator.stop()
    await MeetingCoordinatorTests.livePassFinished(coordinator, first)
    await coordinator.start(from: .history)
    let second = try #require(coordinator.meetings.first(where: { $0.id != first })?.id)
    await coordinator.stop()
    await MeetingCoordinatorTests.livePassFinished(coordinator, second)
    await Self.eventually("both waiting") { rig.lane.summaryWaiting == 2 }

    // Transcribe again on the second: its waiting summary is cancelled and settles at once,
    // so the final pass is not held behind the first meeting's summary.
    let previous = try #require(coordinator.record(id: second)?.committedTranscriptGeneration)
    await MeetingCoordinatorTests.transcribeAgainOnceOffered(coordinator, meetingID: second)
    await MeetingCoordinatorTests.livePassFinished(coordinator, second, replacing: previous)
    // The cancelled summary's row is sent once its task has ended, which may follow the pass.
    await Self.eventually("waiting summary cancelled") {
      rig.world.finished.contains(Self.row(.cancelled, .local))
    }

    // Dictation ends: the summaries run one local call at a time.
    var concurrent = 0
    var most = 0
    rig.world.duringCall = { [lane = rig.lane] in
      concurrent = lane.summaryCallRunning ? 1 : 0
      most = max(most, concurrent)
    }
    rig.world.localTurn = true
    // #3973 C2: the replacement schedules no new summary; the first meeting's is written.
    await Self.eventually("summary written") {
      rig.world.finished.filter { $0 == Self.row(.written, .local) }.count == 1
    }
    #expect(most == 1, "each call held the lane alone")
    // settle: bounded negative window; it cannot prove "never", only expose an early start
    try await Task.sleep(for: .milliseconds(200))
    #expect(rig.world.finished.count == 2, "one cancelled and one written, nothing else")
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
    await MeetingCoordinatorTests.livePassFinished(coordinator, meetingID)
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
    // #4198: the mark settles after the History publication that follows `.ready`.
    await MeetingCoordinatorTests.livePassFinished(coordinator, meetingID)
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

  // MARK: - The Summary tab's owners (C13b)

  @Test("an edit makes the summary the user's own, keeps its inputs, and holds a relaunch until saved")
  func summaryEdit() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    _ = await Self.schedule(rig, id)
    await Self.eventually("written") { rig.world.finished.count == 1 }
    #expect(await rig.documents.load(id))
    let generatedInputs = try rig.manifest(id).summary?.inputs
    rig.documents.setSummary(id, "## Overview\nShip Friday. Priya owns it.")
    #expect(rig.documents.hasPendingWork, "an unsaved edit holds a relaunch")
    #expect(await rig.documents.flushSummary(id))
    #expect(rig.summaryOnDisk(id) == "## Overview\nShip Friday. Priya owns it.")
    let manifest = try rig.manifest(id)
    #expect(manifest.summary?.origin == .userEdited)
    #expect(manifest.summary?.inputs == generatedInputs, "still shows out of date if the meeting changes")
  }

  @Test("a generated summary that arrives while the user types keeps the typing")
  func generatedDuringTyping() async throws {
    let base = try Rig()
    // The edit's own debounced save never runs here: only the owner can save the typing.
    let gate = MeetingDocumentsOwnerTests.DebounceGate()
    defer { gate.open() }
    let documents = Rig.documents(base.store, debounce: { await gate.wait() })
    let rig = try Rig(sharing: base, documents: documents)
    let id = try rig.readyMeeting()
    _ = await Self.schedule(rig, id)
    await Self.eventually("first") { rig.world.finished.count == 1 }
    #expect(await rig.documents.load(id))
    rig.world.holdCalls = true
    rig.owner.writeAgain(id, replacing: nil)
    await Self.eventually("calling") { rig.world.callsWaiting == 1 }
    // Typed, not yet saved (the debounce has not run), when the answer arrives.
    rig.documents.setSummary(id, "My own words")
    rig.world.releaseCall()
    await Self.eventually("second") { rig.world.finished.count == 2 }
    #expect(rig.world.finished.last == Self.row(.stale, .hosted))
    #expect(rig.summaryOnDisk(id) == "My own words")
    #expect(rig.documents.summary(id) == "My own words")
  }

  @Test("out of date exactly when the recorded inputs differ; a summary with no inputs never is")
  func outOfDate() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    #expect(rig.owner.isOutOfDate(id) == false, "no summary")
    _ = await Self.schedule(rig, id)
    await Self.eventually("written") { rig.world.finished.count == 1 }
    #expect(await rig.documents.load(id))
    #expect(rig.owner.isOutOfDate(id) == false)
    rig.world.speakerNames = ["mic:you": "Priya"]
    #expect(rig.owner.isOutOfDate(id), "a rename")
    rig.world.speakerNames = ["mic:you": "You"]
    rig.world.model = "gpt-4.1"
    #expect(rig.owner.isOutOfDate(id), "another model")

    let other = try Rig()
    let written = try other.readyMeeting()
    _ = try other.store.saveSummary("Mine", origin: .userEdited, inputs: nil, meeting: written)
    #expect(await other.documents.load(written))
    other.world.speakerNames = ["mic:you": "Priya"]
    #expect(other.owner.isOutOfDate(written) == false, "the user's own summary records no inputs")
  }

  /// #3973 C2 (plan §3 item 6): a Transcribe again commits a new transcript generation, so a
  /// generated summary is out of date even when the new words are byte for byte the same.
  @Test("a new transcript attempt makes a generated summary out of date, even with identical words")
  func newAttemptMakesTheSummaryOutOfDate() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    rig.world.transcriptAttemptID = UUID()
    _ = await Self.schedule(rig, id)
    await Self.eventually("written") { rig.world.finished.count == 1 }
    #expect(await rig.documents.load(id))
    #expect(rig.owner.isOutOfDate(id) == false, "control: the same attempt is current")
    rig.world.transcriptAttemptID = UUID()
    #expect(rig.owner.isOutOfDate(id), "same words, a new attempt")
  }

  @Test("a final pass's wait names its real reason: dictation, or a meeting summary on this Mac")
  func waitReasons() {
    var processing = MeetingCoordinator.Processing(meetingID: UUID(), stage: nil)
    processing.waitingForDictation = true
    #expect(MeetingsPresentation.stage(processing, waitingOnSummary: false) == "Paused while you dictate")
    #expect(
      MeetingsPresentation.stage(processing, waitingOnSummary: true)
        == "Paused while a meeting summary is written")
  }

  @Test("every summary problem has its own message, and the engine ones open Summaries settings")
  func problemCopy() {
    let problems: [MeetingSummaryOwner.Problem] = [
      .noProvider, .notForSummaries, .notReady, .ollamaTooOld, .tooLong, .providerFailed,
      .notesUnreadable, .storageFailed,
    ]
    let messages = problems.map(MeetingSummaryView.message)
    #expect(Set(messages).count == problems.count)
    #expect(messages.allSatisfy { !$0.isEmpty })
    #expect(
      problems.filter(MeetingSummaryView.opensSummarySettings)
        == [.noProvider, .notForSummaries, .notReady, .ollamaTooOld])
  }

  // MARK: - Summary tab review fixes (Codex C13b-1 r1)

  @Test("typing during a held generated save stays on screen and ends on disk as the user's")
  func typingDuringGeneratedSave() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    _ = await Self.schedule(rig, id)
    await Self.eventually("first") { rig.world.finished.count == 1 }
    #expect(await rig.documents.load(id))
    var release: DispatchSemaphore?
    rig.world.duringCall = { release = MeetingDocumentsOwnerTests.holdFileQueue() }
    rig.owner.writeAgain(id, replacing: nil)
    await MeetingWorkAdmission.waitUntil {
      rig.world.calls.count == 2 && rig.documents.hasPendingWork
    }
    // The generated save is parked; the user types now.
    rig.documents.setSummary(id, "Typed while it saved")
    try #require(release).signal()
    await Self.eventually("second") { rig.world.finished.count == 2 }
    #expect(rig.documents.summary(id) == "Typed while it saved", "the typing stays on screen")
    #expect(await rig.documents.flushSummary(id))
    #expect(rig.summaryOnDisk(id) == "Typed while it saved")
    #expect(try rig.manifest(id).summary?.origin == .userEdited)
  }

  @Test("unsaved notes and unreadable meeting facts both show a summary as out of date")
  func outOfDateWhileUnsure() async throws {
    let base = try Rig()
    let gate = MeetingDocumentsOwnerTests.DebounceGate()
    defer { gate.open() }
    let rig = try Rig(sharing: base, documents: Rig.documents(base.store, debounce: { await gate.wait() }))
    let id = try rig.readyMeeting()
    _ = await Self.schedule(rig, id)
    await Self.eventually("written") { rig.world.finished.count == 1 }
    #expect(await rig.documents.load(id))
    #expect(rig.owner.isOutOfDate(id) == false)
    rig.documents.setNotes(id, "A new note")
    #expect(rig.owner.isOutOfDate(id), "notes typed and not yet saved")
    gate.open()
    #expect(await rig.documents.flush(id))
    #expect(rig.owner.isOutOfDate(id), "saved notes: a newer revision")

    let other = try Rig()
    let meeting = try other.readyMeeting()
    _ = await Self.schedule(other, meeting)
    await Self.eventually("written") { other.world.finished.count == 1 }
    #expect(await other.documents.load(meeting))
    other.world.visible = false
    #expect(other.owner.isOutOfDate(meeting), "facts that cannot be read are never current")
  }

  @Test("two presses during a held save start one attempt; a failed save starts none")
  func writeRequests() async throws {
    let base = try Rig()
    // The edit's own debounced save is held, so only the press's flush saves it.
    let gate = MeetingDocumentsOwnerTests.DebounceGate()
    defer { gate.open() }
    let rig = try Rig(sharing: base, documents: Rig.documents(base.store, debounce: { await gate.wait() }))
    let id = try rig.readyMeeting()
    _ = await Self.schedule(rig, id)
    await Self.eventually("first") { rig.world.finished.count == 1 }
    #expect(await rig.documents.load(id))
    rig.documents.setSummary(id, "Edited")
    let hold = MeetingDocumentsOwnerTests.holdFileQueue()
    let first = Task { await rig.owner.requestWrite(id) }
    await MeetingWorkAdmission.waitUntil { rig.owner.requesting.contains(id) }
    #expect(await rig.owner.requestWrite(id) == .refused, "a second press does nothing")
    hold.signal()
    let answer = await first.value
    #expect(answer == .needsConfirmation(MeetingDocumentHash.sha256("Edited")))
    #expect(rig.world.calls.count == 1, "nothing starts before the confirmation")

    let broken = try Rig()
    let meeting = try broken.readyMeeting()
    #expect(await broken.documents.load(meeting))
    // A summary must exist to be edited; then every save of it fails (documents.json).
    _ = try broken.store.saveSummary("Generated", origin: .generated, inputs: nil, meeting: meeting)
    _ = await broken.documents.load(meeting)
    let freshDocuments = Rig.documents(broken.store)
    let brokenRig = try Rig(sharing: broken, documents: freshDocuments)
    #expect(await freshDocuments.load(meeting))
    let undo = try Self.breakManifest(brokenRig, meeting)
    defer { try? undo() }
    freshDocuments.setSummary(meeting, "Mine")
    _ = await freshDocuments.flushSummary(meeting)
    #expect(await brokenRig.owner.requestWrite(meeting) == .refused)
    #expect(brokenRig.owner.activity[meeting] == .failed(.storageFailed))
    #expect(brokenRig.world.calls.isEmpty)
    #expect(freshDocuments.summary(meeting) == "Mine", "the typing is kept")
  }

  @Test("the Summary tab's guidance follows the current setting, whatever any attempt did")
  func configurationGuidance() throws {
    let rig = try Rig()
    rig.world.provider = .none
    #expect(rig.owner.configurationProblem() == .noProvider)
    rig.world.provider = .egOne
    #expect(rig.owner.configurationProblem() == .notForSummaries)
    rig.world.provider = .ollama
    rig.world.model = "eg-1:q4"
    #expect(rig.owner.configurationProblem() == .notForSummaries)
    rig.world.provider = .openAI
    rig.world.model = "gpt-4o-mini"
    #expect(rig.owner.configurationProblem() == nil)
  }

  @Test("an older result held while newer typing is fully saved never replaces it")
  func olderResultAfterSavedEdit() async throws {
    let rig = try Rig()
    let id = try rig.readyMeeting()
    _ = await Self.schedule(rig, id)
    await Self.eventually("first") { rig.world.finished.count == 1 }
    #expect(await rig.documents.load(id))
    rig.world.holdCalls = true
    rig.owner.writeAgain(id, replacing: nil)
    await Self.eventually("held") { rig.world.callsWaiting == 1 }
    rig.documents.setSummary(id, "Newer, saved")
    #expect(await rig.documents.flushSummary(id))
    rig.world.releaseCall()
    await Self.eventually("second") { rig.world.finished.count == 2 }
    #expect(rig.documents.summary(id) == "Newer, saved")
    #expect(rig.summaryOnDisk(id) == "Newer, saved")
    let manifest = try rig.manifest(id)
    #expect(manifest.summary?.origin == .userEdited)
    #expect(manifest.summary?.sha256 == MeetingDocumentHash.sha256("Newer, saved"))
    #expect(rig.documents.manifest(id)?.summary?.sha256 == MeetingDocumentHash.sha256("Newer, saved"))
  }

  @Test("the current setting's problem is shown ahead of an older failure")
  func currentProblemFirst() {
    #expect(
      MeetingSummaryView.shownProblem(activity: .failed(.providerFailed), configuration: .noProvider)
        == .noProvider)
    #expect(
      MeetingSummaryView.shownProblem(
        activity: .failed(.providerFailed), configuration: .notForSummaries) == .notForSummaries)
    #expect(
      MeetingSummaryView.shownProblem(activity: .failed(.providerFailed), configuration: nil)
        == .providerFailed)
    #expect(MeetingSummaryView.shownProblem(activity: nil, configuration: .noProvider) == .noProvider)
    #expect(MeetingSummaryView.shownProblem(activity: nil, configuration: nil) == nil)
  }

  @Test("a result applied after a newer edit's save keeps the user's text, hash and origin")
  func resultAppliedAfterNewerSave() async throws {
    let base = try Rig()
    // Parks each generated result after its store write, before it is applied here.
    let gate = MeetingDocumentsOwnerTests.DebounceGate()
    defer { gate.open() }
    let documents = Rig.documents(base.store, afterGeneratedWrite: { await gate.wait() })
    let rig = try Rig(sharing: base, documents: documents)
    let id = try rig.readyMeeting()
    _ = await Self.schedule(rig, id)
    await Self.eventually("first written to disk") { gate.waiting == 1 }
    gate.open()
    await Self.eventually("first") { rig.world.finished.count == 1 }
    #expect(await documents.load(id))

    let second = MeetingDocumentsOwnerTests.DebounceGate()
    defer { second.open() }
    let late = Rig.documents(base.store, afterGeneratedWrite: { await second.wait() })
    let lateRig = try Rig(sharing: base, documents: late)
    #expect(await late.load(id))
    lateRig.owner.writeAgain(id, replacing: nil)
    // The generated write has landed on disk; its result waits to be applied.
    await Self.eventually("parked after the write") { second.waiting == 1 }
    late.setSummary(id, "Newer, saved after the write")
    #expect(await late.flushSummary(id))
    second.open()
    await Self.eventually("applied") { lateRig.world.finished.count == 1 }
    let user = MeetingDocumentHash.sha256("Newer, saved after the write")
    #expect(late.summary(id) == "Newer, saved after the write")
    #expect(late.manifest(id)?.summary?.sha256 == user)
    #expect(late.manifest(id)?.summary?.origin == .userEdited)
    #expect(lateRig.summaryOnDisk(id) == "Newer, saved after the write")
    #expect(try lateRig.manifest(id).summary?.origin == .userEdited)
  }

  // MARK: - Fingerprints (#4001 step 2b-C)

  // `fingerprintBuildsForTesting` exists in Debug builds only.
  #if DEBUG
    @Test("the transcript and name hashes are reused while the words and names are byte-identical")
    func fingerprintsReusedWhileBytesMatch() async throws {
      let rig = try Rig()
      let id = try rig.readyMeeting()
      rig.world.transcript = "You: the Caf\u{00E9} launch ships Friday"
      _ = await Self.schedule(rig, id)
      await Self.eventually("written") { rig.world.finished.count == 1 }
      #expect(await rig.documents.load(id))
      #expect(rig.owner.isOutOfDate(id) == false)
      let built = rig.owner.fingerprintBuildsForTesting
      for _ in 0..<5 { #expect(rig.owner.isOutOfDate(id) == false) }
      #expect(rig.owner.fingerprintBuildsForTesting == built, "summary keystrokes reuse the hashes")
      rig.world.model = "gpt-4.1"
      #expect(rig.owner.isOutOfDate(id), "another model is still noticed")
      #expect(rig.owner.fingerprintBuildsForTesting == built, "without hashing the words again")
      rig.world.model = "gpt-4o-mini"
      // The same words in a different Unicode form: equal to Swift's ==, different bytes, so a
      // different hash than the one the summary was written from.
      rig.world.transcript = "You: the Cafe\u{0301} launch ships Friday"
      #expect(rig.world.transcript == "You: the Caf\u{00E9} launch ships Friday")
      #expect(rig.owner.isOutOfDate(id), "different bytes are a different transcript")
      #expect(rig.owner.fingerprintBuildsForTesting == built + 1)
      rig.world.transcript = "You: the Caf\u{00E9} launch ships Friday"
      rig.world.speakerNames = ["mic:you": "Ren\u{00E9}e"]
      #expect(rig.owner.isOutOfDate(id), "a rename")
      #expect(rig.owner.fingerprintBuildsForTesting == built + 2)
      rig.world.speakerNames = ["mic:you": "You"]
      #expect(rig.owner.isOutOfDate(id) == false, "back to the words it was written from")
    }

    @Test("a meeting's hashes are dropped when its facts go away and after its attempts drain")
    func fingerprintsDroppedWithTheMeeting() async throws {
      let rig = try Rig()
      let id = try rig.readyMeeting()
      _ = await Self.schedule(rig, id)
      await Self.eventually("written") { rig.world.finished.count == 1 }
      #expect(await rig.documents.load(id))
      _ = rig.owner.isOutOfDate(id)
      var built = rig.owner.fingerprintBuildsForTesting
      rig.world.visible = false
      #expect(rig.owner.isOutOfDate(id), "facts that cannot be read are never current")
      rig.world.visible = true
      #expect(rig.owner.isOutOfDate(id) == false)
      #expect(rig.owner.fingerprintBuildsForTesting == built + 1, "hashed again after the gap")
      built = rig.owner.fingerprintBuildsForTesting
      await rig.owner.cancelAndWait(id)
      _ = rig.owner.isOutOfDate(id)
      #expect(rig.owner.fingerprintBuildsForTesting == built + 1, "dropped after the drain")
    }
  #endif

  // MARK: - Written in parts (#4044)

  @Test("the owner saves the generator's parts flag with the title-free text")
  func savesWrittenPartsFlag() async throws {
    for inParts in [false, true] {
      let rig = try Rig()
      let id = try rig.readyMeeting()
      let world = rig.world
      let owner = MeetingSummaryOwner(
        dependencies: .init(
          isEnabled: { true },
          selection: { (.appleIntelligence, "apple") },
          prepare: { _, _ in
            .success(
              MeetingSummaryProviders.Prepared(
                execution: .local, window: world.window,
                complete: { _, _ in "Unused" }))
          },
          visibleTranscript: { _ in
            .init(text: world.transcript, speakerNames: world.speakerNames)
          },
          hasNoWords: { _ in false },
          isLocalTurn: { true },
          wakes: nil,
          emitFinished: { world.finished.append($0) },
          log: { _ in },
          write: { _, _, _, _, _, _, _ in
            MeetingSummary.Written(
              text: "Title: Launch\n## Overview\nShip Friday.", inParts: inParts)
          }),
        documents: rig.documents, lane: rig.lane)

      #expect(await rig.documents.setSummaryPending(id, true))
      owner.startOwed(id)
      await Self.eventually("summary settled") { world.finished.count == 1 }
      let summary = try #require(try rig.manifest(id).summary)
      #expect(summary.writtenInParts == inParts)
      #expect(rig.summaryOnDisk(id) == "## Overview\nShip Friday.")
      #expect(await rig.documents.load(id))

      rig.documents.setSummary(id, "Edited")
      #expect(await rig.documents.flushSummary(id))
      #expect(try rig.manifest(id).summary?.writtenInParts == inParts)

      // Hold the debounce so the quit path is the writer being tested.
      let gate = MeetingDocumentsOwnerTests.DebounceGate()
      defer { gate.open() }
      let quitting = Rig.documents(rig.store, debounce: { await gate.wait() })
      #expect(await quitting.load(id))
      quitting.setSummary(id, "Edited at quit")
      quitting.flushForQuit(deadline: .now() + .seconds(5))
      #expect(rig.summaryOnDisk(id) == "Edited at quit")
      #expect(try rig.manifest(id).summary?.writtenInParts == inParts)
    }
  }
}
