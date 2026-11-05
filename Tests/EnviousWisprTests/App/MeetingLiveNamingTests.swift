import EnviousWisprAppKitTestSupport
import CoreAudio
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprLivePreview
@testable import EnviousWisprPipeline

/// #4355 PR C: when this fails, a live header shows a name the call app never confirmed for that
/// voice, keeps a name after its evidence went, or names from overlapping or mistimed speech.
/// Naming policy itself is `MeetingSpeakerNamerTests`'; these cases go through the real namer.
@MainActor
@Suite("Live speaker names: adapter and lifecycle", .tags(.productOutcome))
struct MeetingLiveNamingTests {
  typealias Rig = MeetingLiveSpeakersTests.Rig

  static let recording = MeetingLiveSpeakersTests.recording
  /// One second of 16 kHz written audio.
  static let second = 16_000

  static func span(_ start: Int, _ count: Int, run: Int = 0) -> MeetingAudioSpan {
    MeetingLiveSpeakersTests.span(start, count, run: run)
  }

  static func activity(_ start: Int, _ count: Int, _ slots: [Int], epoch: Int = 0)
    -> LiveSpeakerActivity
  {
    MeetingLiveSpeakersTests.activity(start, count, slots, epoch: epoch)
  }

  /// A Zoom-app log whose observations name `name` every 100 ms from `fromMs` to `toMs`.
  static func log(_ name: String, fromMs: Int, toMs: Int, lag: Int = 0) -> CallSpeakerLog {
    let observations = stride(from: fromMs, to: toMs, by: 100).map {
      CallSpeakerObservation(observationMs: $0, speaking: [name])
    }
    return CallSpeakerLog(
      surface: .zoomApp, source: .app, status: .observed,
      lag: CallSpeakerLag(milliseconds: lag), rules: nil,
      roster: CallSpeakerRoster(names: [name, "Priya Shah"], selfNames: []),
      rosterFromParticipantList: true, observations: observations)
  }

  @Test("only stretches where the owner talked alone are naming evidence")
  func soloStretchesSkipOverlap() {
    let stretches = MeetingLiveNaming.soloStretches(
      span: Self.span(0, 16_000), slot: 0, epoch: 0,
      activities: [
        Self.activity(0, 8_000, [0]), Self.activity(8_000, 4_000, [0, 1]),
        Self.activity(12_000, 4_000, [0]),
      ])
    #expect(stretches == [0..<8_000, 12_000..<16_000])
  }

  /// The recorder anchor and a host time `ms` after it.
  static let anchor: UInt64 = 1_000_000_000_000
  static func hostTime(afterMs ms: Int) -> UInt64 {
    anchor + AudioConvertNanosToHostTime(UInt64(ms) * 1_000_000)
  }

  static func released(_ span: MeetingAudioSpan, acquiredAfterMs ms: Int) -> MeetingReleasedChunk {
    MeetingReleasedChunk(
      span: span,
      acquired: MeetingAcquisitionTime(
        recording: recording, hostTicks: hostTime(afterMs: ms), provenance: .hardware),
      afterDrop: false, sourceBreak: false)
  }

  @Test("names follow when the audio was acquired, not where the writer placed it")
  func projectionUsesAcquisition() {
    // The writer continued its cursor: audio written at 1-3 s was acquired at 1.5-3.5 s.
    let clock = [
      MeetingLiveNaming.ClockEntry(
        Self.released(Self.span(Self.second, 2 * Self.second), acquiredAfterMs: 1_500))
    ]
    let soloMs = MeetingLiveNaming.observationStretches(
      [Self.second..<(3 * Self.second)], run: 0, clock: clock, anchor: Self.anchor)
    #expect(soloMs.count == 1)
    #expect(abs((soloMs.first?.lowerBound ?? 0) - 1_500) <= 1)
    let evidence = MeetingLiveNaming.Evidence(
      speakerID: MeetingLiveNaming.speakerID(epoch: 0, slot: 0), epoch: 0, soloMs: soloMs)
    let (composition, eligibility) = MeetingLiveNaming.inputs([evidence])
    // The call app saw the name at 3.1-3.4 s: inside the acquired stretch, after the written
    // one. Reading written samples as observation time would name nobody here.
    let named = MeetingSpeakerNamer.propose(
      composition: composition, eligibility: eligibility,
      log: Self.log("Alex Rivera", fromMs: 3_100, toMs: 3_450))
    #expect(named.proposals == [evidence.speakerID: "Alex Rivera"])
    // A stretch in no released chunk cannot be placed and gives no evidence.
    #expect(
      MeetingLiveNaming.observationStretches(
        [(5 * Self.second)..<(6 * Self.second)], run: 0, clock: clock, anchor: Self.anchor
      ).isEmpty)
  }

  /// A ready meeting with one settled speaker over 1-3 s, solo or overlapped.
  func meetingWithSpeaker(overlapped: Bool = false) async throws -> (Rig, UUID) {
    let rig = Rig()
    rig.namingInterval = nil
    rig.anchor = Self.anchor
    let id = UUID()
    let feed = rig.speakers.prepareCapture(meetingID: id)
    rig.speakers.captureStarted(meetingID: id, callSound: true)
    _ = try await BoundedWait.result(of: try #require(rig.speakers.startTaskForTests))
    // The call audio for 1-3 s, released on time (acquired when written).
    let samples = [Float](repeating: 0, count: 2 * Self.second)
    samples.withUnsafeBufferPointer {
      feed($0, Self.released(Self.span(Self.second, 2 * Self.second), acquiredAfterMs: 1_000))
    }
    rig.try_publishReady()
    let piece = MeetingTimedPiece(
      text: "Hello there", span: Self.span(Self.second, 2 * Self.second))
    rig.speakers.linesChanged(
      [MeetingLiveSpeakersTests.line("c-1", .callSound, [piece])], meetingID: id)
    let evidence =
      overlapped
      ? [Self.activity(Self.second, 2 * Self.second, [0, 1])]
      : [Self.activity(Self.second, 2 * Self.second, [0])]
    if overlapped {
      // Competing overlap never settles a speaker: the piece stays "Speaker".
      try await rig.publishAndWait(
        .activity(
          evidence + [Self.activity(3 * Self.second, Self.second, [2])], unpositionedFrames: 0),
        expectLabels: false)
    } else {
      try await rig.publishAndWait(.activity(evidence, unpositionedFrames: 0))
    }
    return (rig, id)
  }

  @Test("confirmed call-app evidence names the live speaker")
  func qualifyingEvidenceNames() async throws {
    let (rig, id) = try await meetingWithSpeaker()
    rig.logs[id] = Self.log("Alex Rivera", fromMs: 1_100, toMs: 2_900)
    rig.speakers.proposeNames()
    #expect(rig.speakers.labels.names == [1: "Alex Rivera"])
    #expect(
      MeetingsPresentation.liveSpeakerHeader(.remote("1"), names: rig.speakers.labels.names)
        == "Alex Rivera")
  }

  @Test("too little evidence leaves Speaker N")
  func insufficientEvidenceKeepsNumber() async throws {
    let (rig, id) = try await meetingWithSpeaker()
    rig.logs[id] = Self.log("Alex Rivera", fromMs: 1_100, toMs: 1_300)  // two votes
    rig.speakers.proposeNames()
    #expect(rig.speakers.labels.names.isEmpty)
    #expect(MeetingsPresentation.liveSpeakerHeader(.remote("1")) == "Speaker 1")
  }

  @Test("overlapping speech gives no naming claim")
  func overlapGivesNoClaim() async throws {
    let (rig, id) = try await meetingWithSpeaker(overlapped: true)
    rig.logs[id] = Self.log("Alex Rivera", fromMs: 1_100, toMs: 2_900)
    rig.speakers.proposeNames()
    #expect(rig.speakers.labels.names.isEmpty)
  }

  @Test("a reset revokes the name; the next meeting never sees the last one's")
  func resetAndNextMeetingRevoke() async throws {
    let (rig, id) = try await meetingWithSpeaker()
    rig.logs[id] = Self.log("Alex Rivera", fromMs: 1_100, toMs: 2_900)
    rig.speakers.proposeNames()
    #expect(rig.speakers.labels.names == [1: "Alex Rivera"])
    try await rig.publishAndWait(.reset(epoch: 1))
    #expect(rig.speakers.labels.names.isEmpty, "evidence of the old epoch can no longer name")
    rig.speakers.proposeNames()
    #expect(rig.speakers.labels.names.isEmpty)
    // The next meeting: its own (empty) log, no carried name.
    rig.speakers.stop()
    rig.analyses[0].onReleased()
    let next = try await rig.startMeeting()
    try await rig.publishAndWait(.ready(epoch: 0), expectLabels: false)
    rig.speakers.proposeNames()
    #expect(rig.speakers.labels.names.isEmpty)
    #expect(rig.logReads.last == next)
  }
}
