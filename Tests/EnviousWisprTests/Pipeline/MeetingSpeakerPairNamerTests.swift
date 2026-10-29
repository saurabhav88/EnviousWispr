import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #4013 chunk 14: when these fail, a one-on-one call leaves the other person as "Speaker 1"
/// although the call app proved who they were, or worse, names the wrong voice: the user's own
/// name on the other person, a second person sharing the laptop, or a name votes contradicted.
///
/// Synthetic fixtures: the saved stretches and speech are written here by hand. They prove the
/// naming policy, not how a reader builds the stretches (`CallSpeakerCaptureTests` does that).
@Suite("Meeting speaker namer, one-on-one rule", .tags(.productOutcome))
struct MeetingSpeakerPairNamerTests {
  private static let user = "Saurabh Vaish"
  private static let alex = "Alex Rivera"
  private static let priya = "Priya Shah"
  private static let a = "sys:S1"
  private static let b = "sys:S2"

  private static func turn(_ speaker: String, _ start: Int, _ end: Int) -> Turn {
    Turn(
      id: "\(speaker)-\(start)", speakerId: speaker, startMs: start, endMs: end,
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

  private static func stretch(
    _ first: Int, _ last: Int, remote: String = alex, marked: [String] = [user],
    account: [String] = []
  ) -> CallPairStretch {
    CallPairStretch(
      names: [user, remote], selfNames: marked, accountNames: account, firstMs: first,
      lastMs: last)
  }

  private static func segment(
    pairs: [CallPairStretch]?, roster: [String] = [user, alex], selfNames: [String] = [],
    samples: [(Int, [String])] = []
  ) -> CallSpeakerSegment {
    CallSpeakerSegment(
      startMs: 0, endMs: 600_000, endReason: .recordingEnded, surface: .zoomApp, source: .app,
      status: .observed, lag: CallSpeakerLag(milliseconds: 0),
      roster: CallSpeakerRoster(names: roster, selfNames: selfNames),
      rosterFromParticipantList: true,
      observations: samples.map { CallSpeakerObservation(observationMs: $0.0, speaking: $0.1) },
      pairs: pairs)
  }

  private func propose(_ turns: [Turn], _ segments: [CallSpeakerSegment]) -> MeetingNamingResult {
    let ids = Set(turns.map(\.speakerId))
    return MeetingSpeakerNamer.propose(
      composition: Self.composition(turns),
      eligibility: MeetingNamingEligibility(
        callSpeakerIDs: ids, callSpeech: [MeetingNamingInterval(startMs: 0, endMs: 600_000)!],
        markers: []),
      log: CallSpeakerLog(rules: nil, segments: segments))
  }

  @Test("a one-on-one with no talking mark names the only call voice, and says the rule did it")
  func namesTheOtherPerson() {
    let result = propose(
      [Self.turn(Self.a, 1_000, 40_000)], [Self.segment(pairs: [Self.stretch(0, 30_000)])])
    #expect(result.proposals == [Self.a: Self.alex])
    #expect(result.outcome == .named)
    #expect(result.pairProposals == 1)
  }

  @Test("without the app marking the user, neither of the two names is given")
  func unknownUserAbstains() {
    let result = propose(
      [Self.turn(Self.a, 1_000, 40_000)],
      [Self.segment(pairs: [Self.stretch(0, 30_000, marked: [])])])
    #expect(result.proposals.isEmpty)
    #expect(result.outcome == .noSignal, "the vote outcome stands when the rule adds nothing")
  }

  @Test("a mark from elsewhere in the segment only confirms who the user is, never decides it")
  func segmentMarkOnlyConfirms() {
    let turns = [Self.turn(Self.a, 1_000, 40_000)]
    // The mark may be from earlier in the call; on its own it names nobody.
    #expect(
      propose(
        turns,
        [Self.segment(pairs: [Self.stretch(0, 30_000, marked: [])], selfNames: [Self.user])]
      ).proposals.isEmpty)
    // With the account name read alongside the stretch, it agrees, so the name stands.
    #expect(
      propose(
        turns,
        [
          Self.segment(
            pairs: [Self.stretch(0, 30_000, marked: [], account: [Self.user])],
            selfNames: [Self.user])
        ]
      ).proposals == [Self.a: Self.alex])
    // Earlier the user was marked "Priya Shah"; now the two are Priya and the user's new name,
    // and the account says the user is the new name: the old mark disagrees, so nothing.
    let renamed = CallPairStretch(
      names: [Self.priya, Self.user], selfNames: [], accountNames: [Self.user], firstMs: 0,
      lastMs: 30_000)
    #expect(
      propose(
        turns,
        [Self.segment(pairs: [renamed], roster: [Self.priya, Self.user], selfNames: [Self.priya])]
      ).proposals.isEmpty)
  }

  @Test("marks that disagree, or mark someone not on the call, give nothing")
  func conflictingMarksAbstain() {
    let turns = [Self.turn(Self.a, 1_000, 40_000)]
    // The segment marks the other person as the user.
    #expect(
      propose(turns, [Self.segment(pairs: [Self.stretch(0, 30_000)], selfNames: [Self.alex])])
        .proposals.isEmpty)
    // The stretch marks a name that is not one of its two people.
    #expect(
      propose(turns, [Self.segment(pairs: [Self.stretch(0, 30_000, marked: [Self.priya])])])
        .proposals.isEmpty)
    // Both people marked.
    #expect(
      propose(
        turns, [Self.segment(pairs: [Self.stretch(0, 30_000, marked: [Self.user, Self.alex])])]
      )
      .proposals.isEmpty)
  }

  /// The founder's D5 exception (plan r4): Zoom's signed-in account name may say who the user is
  /// when the app marked nobody.
  @Test("with no mark, the signed-in account name says which of the two is the user")
  func accountNameIdentifiesTheUser() {
    let turns = [Self.turn(Self.a, 1_000, 40_000)]
    let named = propose(
      turns, [Self.segment(pairs: [Self.stretch(0, 30_000, marked: [], account: [Self.user])])])
    #expect(named.proposals == [Self.a: Self.alex])
    // An account name that is neither person gives nothing.
    let neither = propose(
      turns, [Self.segment(pairs: [Self.stretch(0, 30_000, marked: [], account: [Self.priya])])])
    #expect(neither.proposals.isEmpty)
    // The risk the founder accepted: an account name equal to the other person's display name
    // takes that person for the user, so the voice gets the user's meeting name.
    let accepted = propose(
      turns, [Self.segment(pairs: [Self.stretch(0, 30_000, marked: [], account: [Self.alex])])])
    #expect(accepted.proposals == [Self.a: Self.user])
  }

  @Test("an app mark always wins over the account name, and a mark elsewhere blocks it")
  func marksWinOverTheAccount() {
    let turns = [Self.turn(Self.a, 1_000, 40_000)]
    // The mark says the user is Saurabh; the account says Alex: the mark decides.
    let marked = propose(
      turns, [Self.segment(pairs: [Self.stretch(0, 30_000, marked: [Self.user], account: [Self.alex])])])
    #expect(marked.proposals == [Self.a: Self.alex])
    // The segment marks someone not on this two-person call: a contradiction the account cannot
    // settle.
    let elsewhere = propose(
      turns,
      [
        Self.segment(
          pairs: [Self.stretch(0, 30_000, marked: [], account: [Self.user])],
          selfNames: [Self.priya])
      ])
    #expect(elsewhere.proposals.isEmpty)
  }

  @Test("the account name never waives the 15 s rule")
  func accountNeverWaives() {
    let result = propose(
      [Self.turn(Self.a, 1_000, 14_000)],
      [Self.segment(pairs: [Self.stretch(0, 10_000, marked: [], account: [Self.user])])])
    #expect(result.proposals.isEmpty)
  }

  @Test("a stretch must last 15 s when anyone else was on the call, but not when nobody was")
  func stability() {
    let turns = [Self.turn(Self.a, 1_000, 40_000)]
    let crowded = [Self.user, Self.alex, Self.priya]
    #expect(
      propose(turns, [Self.segment(pairs: [Self.stretch(0, 14_999)], roster: crowded)])
        .proposals.isEmpty)
    #expect(
      propose(turns, [Self.segment(pairs: [Self.stretch(0, 15_000)], roster: crowded)])
        .proposals == [Self.a: Self.alex])
    // Alex was the only other person the recording ever showed: a short stretch is still not
    // enough, because nothing proves nobody else was there while it was not read (#4206).
    #expect(propose(turns, [Self.segment(pairs: [Self.stretch(0, 5_000)])]).proposals.isEmpty)
  }

  @Test("any second call voice in the stretch gives nothing, however short")
  func oneVoiceOnly() {
    let pairs = [Self.stretch(0, 30_000)]
    let named = propose(
      [Self.turn(Self.a, 1_000, 20_000), Self.turn(Self.b, 30_000, 33_000)],
      [Self.segment(pairs: pairs)])
    #expect(named.proposals == [Self.a: Self.alex], "control: B speaks only after the stretch")
    let shortSecond = propose(
      [Self.turn(Self.a, 1_000, 20_000), Self.turn(Self.b, 27_100, 30_000)],
      [Self.segment(pairs: pairs)])
    #expect(shortSecond.proposals.isEmpty, "2.9 s of a second voice still means two voices")
  }

  @Test("the voice needs 3 s of speech inside the stretch")
  func minimumSpeech() {
    let pairs = [Self.stretch(0, 30_000)]
    #expect(
      propose([Self.turn(Self.a, 27_001, 40_000)], [Self.segment(pairs: pairs)]).proposals.isEmpty)
    #expect(
      propose([Self.turn(Self.a, 27_000, 40_000)], [Self.segment(pairs: pairs)]).proposals
        == [Self.a: Self.alex])
  }

  @Test("the stretch's end is not inside it")
  func halfOpen() {
    let pairs = [Self.stretch(10_000, 30_000)]
    // B speaks only from the stretch's last reading on: not inside.
    let result = propose(
      [Self.turn(Self.a, 10_000, 20_000), Self.turn(Self.b, 30_000, 35_000)],
      [Self.segment(pairs: pairs)])
    #expect(result.proposals == [Self.a: Self.alex])
  }

  @Test("votes come first: a voted name stays, a contradicting vote blocks, a taken name is kept")
  func votesComeFirst() {
    let crowded = [Self.user, Self.alex, Self.priya]
    let alexVotes = (0..<5).map { (2_000 + $0 * 100, [Self.alex]) }
    // A was voted Alex in the three-person part; the one-on-one stretch with Priya later holds
    // only B. Both names stand.
    let both = propose(
      [Self.turn(Self.a, 1_000, 5_000), Self.turn(Self.b, 40_000, 60_000)],
      [
        Self.segment(
          pairs: [Self.stretch(35_000, 65_000, remote: Self.priya)], roster: crowded,
          samples: alexVotes)
      ])
    #expect(both.proposals == [Self.a: Self.alex, Self.b: Self.priya])
    #expect(both.pairProposals == 1)
    // One vote for Priya inside A's speech is too few to name A, yet it contradicts "Alex".
    let contradicted = propose(
      [Self.turn(Self.a, 1_000, 40_000)],
      [
        Self.segment(
          pairs: [Self.stretch(10_000, 40_000)], roster: crowded, samples: [(2_000, [Self.priya])])
      ])
    #expect(contradicted.proposals.isEmpty)
    // Votes gave Alex to A; B alone in an Alex stretch does not get Alex a second time.
    let taken = propose(
      [Self.turn(Self.a, 1_000, 5_000), Self.turn(Self.b, 40_000, 60_000)],
      [Self.segment(pairs: [Self.stretch(35_000, 65_000)], roster: crowded, samples: alexVotes)])
    #expect(taken.proposals == [Self.a: Self.alex])
  }

  @Test("a name two people share never comes from a stretch")
  func sharedNameAbstains() {
    let result = propose(
      [Self.turn(Self.a, 1_000, 40_000)],
      [Self.segment(pairs: [Self.stretch(0, 30_000)], roster: [Self.user, Self.alex, Self.alex])])
    #expect(result.proposals.isEmpty)
  }

  @Test("with no stretches, or stretches not recorded, naming is exactly as before")
  func noPairsUnchanged() {
    let turns = [Self.turn(Self.a, 1_000, 5_000)]
    let samples = (0..<5).map { (2_000 + $0 * 100, [Self.alex]) }
    let recorded = propose(turns, [Self.segment(pairs: [], samples: samples)])
    let unrecorded = propose(turns, [Self.segment(pairs: nil, samples: samples)])
    #expect(recorded == unrecorded)
    #expect(recorded.proposals == [Self.a: Self.alex])
    #expect(recorded.pairProposals == 0)
  }
}
