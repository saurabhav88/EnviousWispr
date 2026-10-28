import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #4013 r2 items 7-8, r3 F1: when these fail, a meeting names the wrong person, names someone
/// on thin or tied evidence, names the user's own voice, or names a stretch that was a
/// "could not transcribe" marker rather than speech.
///
/// Every fixture is synthetic: the composition, eligibility and saved log are written here by
/// hand. They prove the naming policy; they do not prove how the processing pass will build
/// eligibility from real tracks (that integration lands after #3973 PR C).
@Suite("Meeting speaker namer", .tags(.productOutcome))
struct MeetingSpeakerNamerTests {

  // MARK: - Fixtures

  private static func turn(_ speaker: String, _ start: Int?, _ end: Int?, id: String? = nil) -> Turn
  {
    Turn(
      id: id ?? "\(speaker)-\(start ?? -1)", speakerId: speaker, startMs: start, endMs: end,
      originalTextRange: 0..<1, wasPolished: true, granularity: .word)
  }

  private static func composition(_ turns: [Turn]) -> MeetingComposition {
    MeetingComposition(
      text: "x", turns: turns,
      speakerNames: Dictionary(
        uniqueKeysWithValues: Set(turns.map(\.speakerId)).sorted().enumerated().map {
          ($0.element, "Speaker \($0.offset + 1)")
        }), echoTurnIDs: [], speakerCount: Set(turns.map(\.speakerId)).count)
  }

  private static func interval(_ start: Int, _ end: Int) -> MeetingNamingInterval {
    MeetingNamingInterval(startMs: start, endMs: end)!
  }

  private static func eligibility(
    _ ids: Set<String>, speech: [(Int, Int)] = [(0, 100_000)], markers: [MeetingNamingMarker] = []
  ) -> MeetingNamingEligibility {
    MeetingNamingEligibility(
      callSpeakerIDs: ids, callSpeech: speech.map { interval($0.0, $0.1) }, markers: markers)
  }

  private static func log(
    _ samples: [(Int, [String])], roster: [String] = ["Alex Rivera", "Priya Shah", "Dana Lee"],
    selfNames: [String] = ["Saurabh Vaish"], lag: Int? = 0, fromList: Bool? = true,
    status: CallSpeakerObservationStatus? = .observed, surface: CallSpeakerSurface? = .teamsApp,
    source: CallSpeakerSource? = .app, rules: FrozenTalkerRules? = nil
  ) -> CallSpeakerLog {
    CallSpeakerLog(
      surface: surface, source: source, status: status,
      lag: lag.map { CallSpeakerLag(milliseconds: $0) }, rules: rules,
      roster: CallSpeakerRoster(names: roster + selfNames, selfNames: selfNames),
      rosterFromParticipantList: fromList,
      observations: samples.map { CallSpeakerObservation(observationMs: $0.0, speaking: $0.1) })
  }

  /// `count` observations of `name`, one every 100 ms from `start`.
  private static func votes(_ name: String, from start: Int, count: Int) -> [(Int, [String])] {
    (0..<count).map { (start + $0 * 100, [name]) }
  }

  private static let a = "sys:S1"
  private static let b = "sys:S2"

  private func propose(
    _ turns: [Turn], _ eligibility: MeetingNamingEligibility?, _ log: CallSpeakerLog?
  ) -> MeetingNamingResult {
    MeetingSpeakerNamer.propose(
      composition: Self.composition(turns), eligibility: eligibility, log: log)
  }

  // MARK: - Thresholds

  @Test("three votes name a speaker; two do not")
  func voteThreshold() {
    let turns = [Self.turn(Self.a, 0, 10_000)]
    let three = propose(
      turns, Self.eligibility([Self.a]), Self.log(Self.votes("Alex Rivera", from: 0, count: 3)))
    #expect(three.proposals == [Self.a: "Alex Rivera"])
    #expect(three.outcome == .named)
    let two = propose(
      turns, Self.eligibility([Self.a]), Self.log(Self.votes("Alex Rivera", from: 0, count: 2)))
    #expect(two.proposals.isEmpty)
    #expect(two.outcome == .ambiguous)
  }

  @Test(
    "the share counts every vote for the speaker, competing names included: 7 of 10 names, 6 of 9 does not"
  )
  func shareThreshold() {
    let turns = [Self.turn(Self.a, 0, 10_000)]
    let seventy =
      Self.votes("Alex Rivera", from: 0, count: 7) + Self.votes("Priya Shah", from: 2_000, count: 3)
    #expect(
      propose(turns, Self.eligibility([Self.a]), Self.log(seventy)).proposals == [
        Self.a: "Alex Rivera"
      ])
    let below =
      Self.votes("Alex Rivera", from: 0, count: 6) + Self.votes("Priya Shah", from: 2_000, count: 3)
    #expect(propose(turns, Self.eligibility([Self.a]), Self.log(below)).proposals.isEmpty)
  }

  @Test("two names with equal top votes on one speaker name neither")
  func competingNameTie() {
    let turns = [Self.turn(Self.a, 0, 10_000)]
    let tied =
      Self.votes("Alex Rivera", from: 0, count: 4) + Self.votes("Priya Shah", from: 2_000, count: 4)
    let result = propose(turns, Self.eligibility([Self.a]), Self.log(tied))
    #expect(result.proposals.isEmpty)
    #expect(result.outcome == .ambiguous)
  }

  @Test("a name claimed by two speakers goes to the stronger one; an equal claim goes to neither")
  func claimants() {
    let turns = [Self.turn(Self.a, 0, 5_000), Self.turn(Self.b, 5_000, 10_000)]
    let stronger =
      Self.votes("Alex Rivera", from: 0, count: 5)
      + Self.votes("Alex Rivera", from: 5_000, count: 4)
    #expect(
      propose(turns, Self.eligibility([Self.a, Self.b]), Self.log(stronger)).proposals
        == [Self.a: "Alex Rivera"])
    let equal =
      Self.votes("Alex Rivera", from: 0, count: 4)
      + Self.votes("Alex Rivera", from: 5_000, count: 4)
    let result = propose(turns, Self.eligibility([Self.a, Self.b]), Self.log(equal))
    #expect(result.proposals.isEmpty, "no tie-break guess gives the name to either")
  }

  // MARK: - Time

  @Test("lag of either sign moves each observation onto the voice before voting")
  func lagSigns() {
    let turns = [Self.turn(Self.a, 1_000, 2_000), Self.turn(Self.b, 3_000, 4_000)]
    // Indicator 500 ms after the voice: observations at 1_500..1_700 point to 1_000..1_200 (a).
    let late = propose(
      turns, Self.eligibility([Self.a, Self.b]),
      Self.log(Self.votes("Alex Rivera", from: 1_500, count: 3), lag: 500))
    #expect(late.proposals == [Self.a: "Alex Rivera"])
    // Indicator 1_500 ms before the voice: observations at 1_500..1_700 point to 3_000..3_200 (b).
    let early = propose(
      turns, Self.eligibility([Self.a, Self.b]),
      Self.log(Self.votes("Alex Rivera", from: 1_500, count: 3), lag: -1_500))
    #expect(early.proposals == [Self.b: "Alex Rivera"])
  }

  @Test("intervals are half-open: a vote at a turn's start counts, one at its end does not")
  func halfOpen() {
    let turns = [Self.turn(Self.a, 1_000, 2_000)]
    let atStart = [(1_000, ["Alex Rivera"]), (1_000, ["Alex Rivera"]), (1_999, ["Alex Rivera"])]
    #expect(
      propose(turns, Self.eligibility([Self.a]), Self.log(atStart)).proposals == [
        Self.a: "Alex Rivera"
      ])
    let atEnd = [(1_000, ["Alex Rivera"]), (1_500, ["Alex Rivera"]), (2_000, ["Alex Rivera"])]
    #expect(propose(turns, Self.eligibility([Self.a]), Self.log(atEnd)).proposals.isEmpty)
  }

  @Test("overlapping turns of one speaker count each observation once")
  func overlappingTurns() {
    let turns = [
      Self.turn(Self.a, 0, 2_000, id: "t1"), Self.turn(Self.a, 1_000, 3_000, id: "t2"),
      Self.turn(Self.a, 1_500, 2_500, id: "t3"),
    ]
    // Two observations, both inside all three turns: two votes, not six.
    let result = propose(
      turns, Self.eligibility([Self.a]), Self.log(Self.votes("Alex Rivera", from: 1_600, count: 2)))
    #expect(result.proposals.isEmpty)
  }

  @Test("a turn with no time gives no eligible speech")
  func untimedTurn() {
    let result = propose(
      [Self.turn(Self.a, nil, nil)], Self.eligibility([Self.a]),
      Self.log(Self.votes("Alex Rivera", from: 0, count: 5)))
    #expect(result.outcome == .noEligibleSpeakers)
  }

  // MARK: - Who may be named

  @Test("microphone speakers, the call fallback, Both and Unknown are never named")
  func ineligibleSpeakers() {
    let ids = ["mic:you", "mic:S1", "sys:call", "both", "unknown", "sys:"]
    let turns = ids.enumerated().map { Self.turn($0.element, 0, 10_000, id: "t\($0.offset)") }
    let result = propose(
      turns, Self.eligibility(Set(ids)), Self.log(Self.votes("Alex Rivera", from: 0, count: 9)))
    #expect(result.proposals.isEmpty)
    #expect(result.outcome == .noEligibleSpeakers)
  }

  @Test("only call-sound speakers the pass marks genuine are named, even when others overlap")
  func onlySuppliedIdentities() {
    let turns = [Self.turn(Self.a, 0, 10_000), Self.turn(Self.b, 0, 10_000, id: "b")]
    let result = propose(
      turns, Self.eligibility([Self.a]), Self.log(Self.votes("Alex Rivera", from: 0, count: 5)))
    #expect(result.proposals == [Self.a: "Alex Rivera"])
  }

  @Test("the user's own name, a duplicated name and a name off the roster never win")
  func nameEligibility() {
    let turns = [Self.turn(Self.a, 0, 10_000)]
    let selfOnly = propose(
      turns, Self.eligibility([Self.a]), Self.log(Self.votes("Saurabh Vaish", from: 0, count: 5)))
    #expect(selfOnly.outcome == .noSignal)
    let duplicated = propose(
      turns, Self.eligibility([Self.a]),
      Self.log(
        Self.votes("Alex Rivera", from: 0, count: 5), roster: ["Alex Rivera", "Alex Rivera"]))
    #expect(duplicated.outcome == .noSignal)
    let offRoster = propose(
      turns, Self.eligibility([Self.a]), Self.log(Self.votes("Morgan Hale", from: 0, count: 5)))
    #expect(offRoster.outcome == .noSignal)
  }

  @Test("self talking alongside one other person still counts for the other; two others do not")
  func ambiguityIsNotConfidence() {
    let turns = [Self.turn(Self.a, 0, 10_000)]
    let withSelf = (0..<3).map { (100 * $0, ["Saurabh Vaish", "Alex Rivera"]) }
    #expect(
      propose(turns, Self.eligibility([Self.a]), Self.log(withSelf)).proposals == [
        Self.a: "Alex Rivera"
      ])
    let twoOthers = (0..<5).map { (100 * $0, ["Alex Rivera", "Priya Shah"]) }
    #expect(propose(turns, Self.eligibility([Self.a]), Self.log(twoOthers)).outcome == .noSignal)
    let twoTiles = (0..<5).map { (100 * $0, ["Alex Rivera", "Alex Rivera"]) }
    #expect(propose(turns, Self.eligibility([Self.a]), Self.log(twoTiles)).outcome == .noSignal)
  }

  // MARK: - Markers and speech

  @Test("speech outside the call's transcribed speech is not eligible")
  func callSpeechOnly() {
    let turns = [Self.turn(Self.a, 0, 10_000)]
    let result = propose(
      turns, Self.eligibility([Self.a], speech: [(5_000, 6_000)]),
      Self.log(Self.votes("Alex Rivera", from: 0, count: 5)))
    #expect(result.outcome == .noSignal, "votes at 0..400 fall outside 5000..6000")
  }

  @Test(
    "a failed-piece marker inside a genuine speaker's turn removes its stretch, even beside speech")
  func boundedMarker() {
    let turns = [Self.turn(Self.a, 0, 10_000)]
    let marker = MeetingNamingMarker(track: .callSound, startMs: 1_000, endMs: 2_000)
    let inside = propose(
      turns, Self.eligibility([Self.a], markers: [marker]),
      Self.log(Self.votes("Alex Rivera", from: 1_000, count: 5)))
    #expect(inside.outcome == .noSignal)
    // Speech in the same turn right after the marker still counts.
    let after = propose(
      turns, Self.eligibility([Self.a], markers: [marker]),
      Self.log(Self.votes("Alex Rivera", from: 2_000, count: 3)))
    #expect(after.proposals == [Self.a: "Alex Rivera"])
  }

  @Test("an open-ended damaged-audio marker removes everything from its start, with no guessed end")
  func openEndedMarker() {
    let turns = [Self.turn(Self.a, 0, 100_000)]
    let marker = MeetingNamingMarker(track: .callSound, startMs: 5_000, endMs: nil)
    let late = propose(
      turns, Self.eligibility([Self.a], markers: [marker]),
      Self.log(Self.votes("Alex Rivera", from: 90_000, count: 5)))
    #expect(late.outcome == .noSignal)
    let early = propose(
      turns, Self.eligibility([Self.a], markers: [marker]),
      Self.log(Self.votes("Alex Rivera", from: 4_000, count: 3)))
    #expect(early.proposals == [Self.a: "Alex Rivera"])
  }

  @Test("a speaker whose only time is a marker has no eligible speech")
  func markerOnlySpeaker() {
    let result = propose(
      [Self.turn(Self.a, 1_000, 2_000)],
      Self.eligibility([Self.a], markers: [MeetingNamingMarker(track: .callSound, startMs: 1_000, endMs: 2_000)]),
      Self.log(Self.votes("Alex Rivera", from: 1_000, count: 5)))
    #expect(result.outcome == .noEligibleSpeakers)
  }

  @Test("a microphone marker, bounded or open-ended, never removes call-sound evidence")
  func microphoneMarkers() {
    let turns = [Self.turn(Self.a, 0, 10_000)]
    for marker in [
      MeetingNamingMarker(track: .microphone, startMs: 0, endMs: 10_000),
      MeetingNamingMarker(track: .microphone, startMs: 0, endMs: nil),
    ] {
      let result = propose(
        turns, Self.eligibility([Self.a], markers: [marker]),
        Self.log(Self.votes("Alex Rivera", from: 1_000, count: 3)))
      #expect(result.proposals == [Self.a: "Alex Rivera"], "marker: \(marker)")
    }
  }

  // MARK: - Saved evidence

  private static func frozen(_ selectors: String) -> FrozenTalkerRules {
    FrozenTalkerRules(
      version: 1,
      payload: #"{"schema":1,"revision":1,"lagMs":{},"selectors":[\#(selectors)]}"#)
  }

  private static let verifiedMeet = frozen(
    #"{"surface":"meet","tileClass":"dkjMxf","nameSource":"firstStaticText","talkingClasses":["kssMZb"],"verification":"verified"}"#
  )

  @Test("a rules-driven log names only under frozen rules that decode and could report a talker")
  func rulesDrivenEvidence() {
    let turns = [Self.turn(Self.a, 0, 10_000)]
    let samples = Self.votes("Alex Rivera", from: 0, count: 3)
    let eligible = Self.eligibility([Self.a])
    func run(_ rules: FrozenTalkerRules?, source: CallSpeakerSource = .rules) -> MeetingNamingResult {
      propose(turns, eligible, Self.log(samples, surface: .meet, source: source, rules: rules))
    }
    #expect(run(Self.verifiedMeet).proposals == [Self.a: "Alex Rivera"])
    #expect(run(nil).outcome == .rulesUnusable)
    #expect(run(FrozenTalkerRules(version: 1, payload: "{not json")).outcome == .rulesUnusable)
    #expect(run(FrozenTalkerRules(version: 2, payload: Self.verifiedMeet.payload)).outcome == .rulesUnusable)
    #expect(run(Self.frozen("")).outcome == .rulesUnusable, "no Meet entry: unconfigured")
    let unverified = Self.frozen(
      #"{"surface":"meet","tileClass":"dkjMxf","nameSource":"firstStaticText","talkingClasses":["kssMZb"],"verification":"unverified"}"#
    )
    #expect(run(unverified).outcome == .rulesUnusable)
    #expect(run(Self.verifiedMeet, source: .app).outcome == .unsupported)
  }

  @Test("an unknown, roster-only or mismatched surface never names")
  func unsupportedSurfaces() {
    let turns = [Self.turn(Self.a, 0, 10_000)]
    let samples = Self.votes("Alex Rivera", from: 0, count: 3)
    let eligible = Self.eligibility([Self.a])
    #expect(propose(turns, eligible, Self.log(samples, surface: nil)).outcome == .unsupported)
    for surface in [CallSpeakerSurface.facetime, .webex, .jitsi] {
      #expect(propose(turns, eligible, Self.log(samples, surface: surface)).outcome == .unsupported)
    }
    #expect(propose(turns, eligible, Self.log(samples, source: .rules)).outcome == .unsupported)
    #expect(propose(turns, eligible, Self.log(samples, source: nil)).outcome == .unsupported)
    #expect(
      propose(turns, eligible, Self.log(samples, surface: .zoomWeb)).proposals == [Self.a: "Alex Rivera"])
  }

  @Test("missing, unread or uncertain evidence keeps the fallback labels, each with its reason")
  func abstentions() {
    let turns = [Self.turn(Self.a, 0, 10_000)]
    let samples = Self.votes("Alex Rivera", from: 0, count: 5)
    let eligible = Self.eligibility([Self.a])
    #expect(propose(turns, eligible, nil).outcome == .noLog)
    #expect(
      propose(turns, eligible, Self.log(samples, status: .noPermission)).outcome == .noPermission)
    #expect(propose(turns, eligible, Self.log(samples, status: .unreadable)).outcome == .unreadable)
    #expect(
      propose(turns, eligible, Self.log(samples, status: .unsupported)).outcome == .unsupported)
    #expect(propose(turns, eligible, Self.log(samples, status: nil)).outcome == .statusUnknown)
    #expect(propose(turns, eligible, Self.log(samples, lag: nil)).outcome == .lagUnmeasured)
    #expect(
      propose(turns, eligible, Self.log(samples, fromList: false)).outcome == .rosterUncertain)
    #expect(propose(turns, eligible, Self.log(samples, fromList: nil)).outcome == .rosterUncertain)
    #expect(propose(turns, nil, Self.log(samples)).outcome == .noEligibleSpeakers)
    for outcome in [
      propose(turns, eligible, nil), propose(turns, eligible, Self.log(samples, lag: nil)),
    ] {
      #expect(outcome.proposals.isEmpty)
    }
  }

  @Test("an observation whose aligned time would overflow is skipped, not wrapped")
  func overflowSafe() {
    let result = propose(
      [Self.turn(Self.a, 0, 10_000)], Self.eligibility([Self.a]),
      Self.log(
        [(Int.min, ["Alex Rivera"]), (Int.min, ["Alex Rivera"]), (Int.min, ["Alex Rivera"])], lag: 1
      ))
    #expect(result.outcome == .noSignal)
  }

  // MARK: - Purity

  @Test("equal evidence gives equal proposals, as on a fresh pass and a checkpoint-reused one")
  func deterministic() {
    let turns = [Self.turn(Self.a, 0, 5_000), Self.turn(Self.b, 5_000, 10_000)]
    let samples =
      Self.votes("Alex Rivera", from: 0, count: 4) + Self.votes("Priya Shah", from: 5_000, count: 4)
    let fresh = propose(turns, Self.eligibility([Self.a, Self.b]), Self.log(samples))
    let reused = propose(
      turns, Self.eligibility([Self.b, Self.a], speech: [(5_000, 100_000), (0, 5_000)]),
      Self.log(samples))
    #expect(fresh == reused)
    #expect(fresh.proposals == [Self.a: "Alex Rivera", Self.b: "Priya Shah"])
  }

  @Test("naming never changes the composition it reads")
  func compositionUntouched() {
    let composition = Self.composition([Self.turn(Self.a, 0, 10_000)])
    let before = composition
    _ = MeetingSpeakerNamer.propose(
      composition: composition, eligibility: Self.eligibility([Self.a]),
      log: Self.log(Self.votes("Alex Rivera", from: 0, count: 5)))
    #expect(composition == before)
    #expect(composition.speakerNames == [Self.a: "Speaker 1"])
  }
}
