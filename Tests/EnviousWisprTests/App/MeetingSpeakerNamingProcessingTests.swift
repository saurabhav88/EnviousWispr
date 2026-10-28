import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// #4013 chunk 12A: when these fail, a meeting's call speakers stay "Speaker N" although the
/// call app showed who talked, a damaged evidence file fails a meeting's transcript, a pass
/// names from evidence that changed while it ran, or a crash publishes a transcript without the
/// names its pass chose.
///
/// The stand-in pass runs the real namer on the evidence the coordinator handed it, over a
/// SYNTHETIC composition (one call speaker, one microphone turn). The evidence files are
/// SYNTHETIC logs (`CallSpeakerTestLog`) saved and read through the real meeting store.
@MainActor
@Suite("Meeting processing names call speakers", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingSpeakerNamingProcessingTests {
  typealias Harness = MeetingCoordinatorTests.Harness

  private func eventually(_ label: String, _ condition: @escaping @MainActor () -> Bool) async {
    await MeetingCoordinatorTests.eventually(label, condition)
  }

  private static let eligibility = MeetingNamingEligibility(
    callSpeakerIDs: ["sys:1"], callSpeech: [MeetingNamingInterval(startMs: 0, endMs: 10_000)!],
    markers: [])

  private static func composition() -> MeetingComposition {
    MeetingComposition(
      text: "hi there",
      turns: [
        Turn(
          id: "call-0", speakerId: "sys:1", startMs: 0, endMs: 10_000, originalTextRange: 0..<2,
          wasPolished: true, granularity: .word),
        Turn(
          id: "mic-3", speakerId: "mic:you", startMs: 10_000, endMs: 12_000,
          originalTextRange: 3..<8, wasPolished: true, granularity: .word),
      ],
      speakerNames: ["sys:1": "Speaker 1", "mic:you": "You"], echoTurnIDs: [], speakerCount: 2)
  }

  /// A pass that names from the evidence the coordinator handed the stand-in job, like the
  /// real job does after composition. `gate` holds the pass before it names.
  static func namingPass(_ harness: Harness, gate: MeetingCoordinatorTests.Gate? = nil)
    -> @MainActor (MeetingTranscriptionJob.CheckpointAccess?) async throws ->
    MeetingTranscriptionJob.Result
  {
    { [weak harness] _ in
      let evidence = harness?.jobs.last?.receivedCallSpeakers.last ?? .absent
      await gate?.wait()
      var result = MeetingCoordinatorTests.result()
      result = MeetingTranscriptionJob.Result(
        composition: composition(), speakerOutcomes: [.callSound: .single, .microphone: .single],
        forcedCuts: 0, failedPieces: 0, failedRanges: [:], resumedPieces: 0,
        checkpointSaveFailures: 0, yieldCount: 0, processingSeconds: 1, audioSeconds: 1,
        resolved: result.resolved)
      result.naming = MeetingNamingOutput(
        evidence: evidence, eligibility: eligibility,
        result: MeetingSpeakerNamer.propose(
          composition: result.composition, eligibility: eligibility, log: evidence.log))
      return result
    }
  }

  /// Starts a meeting, lets `beforeStop` place its evidence, stops it and waits until ready.
  private func finishedMeeting(_ harness: Harness, beforeStop: (UUID) throws -> Void)
    async throws -> UUID
  {
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    try beforeStop(meetingID)
    await coordinator.stop()
    await eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    return meetingID
  }

  @Test("saved evidence names the call speaker in the saved transcript, marked automatic")
  func usableEvidenceNames() async throws {
    let harness = try Harness()
    harness.jobBehavior = Self.namingPass(harness)
    let log = try CallSpeakerTestLog.meet()
    _ = try await finishedMeeting(harness) { try harness.store.saveCallSpeakers(log, meeting: $0) }

    #expect(harness.jobs.last?.receivedCallSpeakers == [.usable(log)])
    let saved = try #require(harness.saved.last)
    #expect(saved.speakerNames == ["sys:1": "Alex Rivera", "mic:you": "You"])
    #expect(saved.speakerNameSources == ["sys:1": .auto])
    #expect(saved.speakerNameSource(for: "mic:you") == nil, "the microphone keeps its label")
    #expect(saved.text == "hi there")
    #expect(saved.turns == Self.composition().turns)
  }

  @Test("missing, damaged, oversized or newer evidence: the meeting is transcribed with its labels")
  func unusableEvidenceKeepsLabels() async throws {
    let cases: [(String, MeetingCallSpeakerEvidence, (MeetingStore, UUID) throws -> Void)] = [
      ("absent", .absent, { _, _ in }),
      (
        "damaged", .unusable(.invalid),
        { store, id in try Data("{ not a log".utf8).write(to: store.callSpeakersURL(for: id)) }
      ),
      (
        "oversized", .unusable(.tooLarge),
        { store, id in
          try Data(repeating: 0x20, count: MeetingStore.maximumCallSpeakersBytes + 1)
            .write(to: store.callSpeakersURL(for: id))
        }
      ),
      (
        "newer", .unusable(.newerFormat),
        { store, id in
          try Data(#"{"formatVersion":99}"#.utf8).write(to: store.callSpeakersURL(for: id))
        }
      ),
    ]
    for (label, expected, place) in cases {
      let harness = try Harness()
      harness.jobBehavior = Self.namingPass(harness)
      _ = try await finishedMeeting(harness) { try place(harness.store, $0) }
      #expect(harness.jobs.last?.receivedCallSpeakers == [expected], "\(label)")
      let saved = try #require(harness.saved.last, "\(label)")
      #expect(saved.speakerNames == ["sys:1": "Speaker 1", "mic:you": "You"], "\(label)")
      #expect(saved.speakerNameSources == nil, "\(label)")
    }
  }

  @Test("a pass names from the evidence it started with, even if the file changes while it runs")
  func evidenceReadOncePerPass() async throws {
    let harness = try Harness()
    let gate = MeetingCoordinatorTests.Gate()
    harness.jobBehavior = Self.namingPass(harness, gate: gate)
    let coordinator = harness.coordinator
    await coordinator.start(from: .history)
    let meetingID = try #require(harness.recorders.first).configuration.meetingID
    try harness.store.saveCallSpeakers(try CallSpeakerTestLog.meet(), meeting: meetingID)
    await coordinator.stop()
    await eventually("pass parked") { gate.parked }
    try harness.store.saveCallSpeakers(
      try CallSpeakerTestLog.meet(talking: "Priya Shah"), meeting: meetingID)
    gate.open()
    await eventually("ready") {
      coordinator.record(id: meetingID)?.state == .ready && coordinator.processing == nil
    }
    #expect(harness.jobs.last?.receivedCallSpeakers.count == 1)
    #expect(harness.saved.last?.speakerNames?["sys:1"] == "Alex Rivera")
  }

  @Test("a crash after the ready barrier publishes the pass's names, whatever the file says now")
  func replayKeepsTheCandidateNames() async throws {
    let harness = try Harness()
    harness.jobBehavior = Self.namingPass(harness)
    let meetingID = try await finishedMeeting(harness) { _ in }
    // Transcribe again with evidence; the History save is held, as a crash would leave it.
    try harness.store.saveCallSpeakers(try CallSpeakerTestLog.meet(), meeting: meetingID)
    let save = MeetingCoordinatorTests.Gate()
    harness.saveGate = save
    #expect(await harness.coordinator.transcribeAgain(meetingID: meetingID, engine: .parakeet))
    await eventually("History save parked") { save.parked }
    guard case .receipt(let kept) = harness.store.loadTranscriptReplacement(meeting: meetingID)
    else {
      Issue.record("no receipt")
      save.open()
      return
    }
    #expect(kept.candidateRow.speakerNames?["sys:1"] == "Alex Rivera")
    #expect(kept.candidateRow.speakerNameSources == ["sys:1": .auto])

    // The evidence now says someone else; the next launch publishes the receipt's row as is.
    try harness.store.saveCallSpeakers(
      try CallSpeakerTestLog.meet(talking: "Priya Shah"), meeting: meetingID)
    let relaunched = try Harness(copying: harness.root)
    relaunched.coordinator.launch()
    await eventually("published") { relaunched.saved.count == 1 }
    #expect(relaunched.saved.first?.speakerNames?["sys:1"] == "Alex Rivera")
    #expect(relaunched.saved.first?.speakerNameSources == ["sys:1": .auto])
    #expect(relaunched.saved.first?.meetingTranscriptAttemptID == kept.candidate.generation)
    #expect(relaunched.jobs.isEmpty, "the launch did not run a pass or name again")
    #expect(relaunched.ended.isEmpty, "the replay sends no second meeting.ended row")
    save.open()
  }

  @Test("only a present speaker's display name changes; text, turns and attempt are the pass's")
  func proposalsChangeOnlyDisplayNames() async throws {
    let harness = try Harness()
    let meetingID = try await finishedMeeting(harness) { _ in }
    let record = try #require(harness.coordinator.record(id: meetingID))
    var result = MeetingCoordinatorTests.result()
    result = MeetingTranscriptionJob.Result(
      composition: Self.composition(), speakerOutcomes: result.speakerOutcomes, forcedCuts: 0,
      failedPieces: 0, failedRanges: [:], resumedPieces: 0, checkpointSaveFailures: 0,
      yieldCount: 0, processingSeconds: 1, audioSeconds: 1, resolved: result.resolved)
    result.naming = MeetingNamingOutput(
      evidence: .absent, eligibility: Self.eligibility,
      result: MeetingNamingResult(
        proposals: ["sys:1": "Alex Rivera", "sys:9": "Nobody Here"], outcome: .named))
    let row = MeetingCoordinator.transcript(for: record, result: result)
    #expect(row.speakerNames == ["sys:1": "Alex Rivera", "mic:you": "You"])
    #expect(row.speakerNameSources == ["sys:1": .auto])
    #expect(row.text == "hi there")
    #expect(row.turns == Self.composition().turns)
    #expect(row.meetingTranscriptAttemptID == result.resolved.attemptID)

    result.naming = nil
    let unnamed = MeetingCoordinator.transcript(for: record, result: result)
    #expect(unnamed.speakerNames == ["sys:1": "Speaker 1", "mic:you": "You"])
    #expect(unnamed.speakerNameSources == nil)
  }
}
