@testable import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #4013 r5 items 1 and 3: when these fail, a recording loses the correction it started with,
/// Transcribe again silently uses today's rules, an older log is given a correction it never had,
/// or a tile roster can no longer name anyone.
///
/// Controlled reader -> save -> reload -> name tests: the readings, observation times and
/// compositions are SYNTHETIC; the rules are the bundled file. They do not prove the production
/// observer or the processing job is wired (that integration follows the PR C rebase).
@Suite("Speaker naming correction and replay", .tags(.productOutcome))
struct SpeakerLagReplayTests {

  private static let good = CallCaptureContext(completeness: .complete, scope: .resolved)

  private func bundledData() throws -> Data {
    try Data(
      contentsOf: RepoRoot.url.appending(
        path: "Sources/EnviousWisprServices/Resources/talker-rules.json"))
  }

  private func rules(_ json: String) throws -> TalkerRules {
    try TalkerRules.decode(Data(json.utf8))
  }

  // MARK: - Recording-start resolution

  @Test("each verified surface's bundled correction is +500 ms; others have none")
  func bundledDefaults() throws {
    let bundled = try TalkerRules.decode(bundledData())
    #expect(bundled.revision == 3)
    for surface in [CallSpeakerSurface.zoomApp, .teamsApp, .zoomWeb, .meet] {
      #expect(
        TalkerRules.recordingStartLag(for: surface, selected: bundled, bundled: bundled)
          == CallSpeakerLag(milliseconds: 500), "\(surface)")
    }
    for surface in [CallSpeakerSurface.teamsWeb, .slackApp, .slackWeb, .facetime] {
      #expect(
        TalkerRules.recordingStartLag(for: surface, selected: bundled, bundled: bundled) == nil)
    }
    #expect(TalkerRules.recordingStartLag(for: nil, selected: bundled, bundled: bundled) == nil)
  }

  @Test(
    "a selected value wins, zero and negative included; a missing one falls back; none stays nil")
  func selectedOverridesAndFallback() throws {
    let bundled = try TalkerRules.decode(bundledData())
    let selected = try rules(
      #"{"schema":1,"revision":9,"lagMs":{"zoom_app":0,"meet":-250},"selectors":[]}"#)
    #expect(
      TalkerRules.recordingStartLag(for: .zoomApp, selected: selected, bundled: bundled)?
        .milliseconds == 0)
    #expect(
      TalkerRules.recordingStartLag(for: .meet, selected: selected, bundled: bundled)?.milliseconds
        == -250)
    #expect(
      TalkerRules.recordingStartLag(for: .teamsApp, selected: selected, bundled: bundled)?
        .milliseconds == 500)
    let empty = try rules(#"{"schema":1,"revision":0,"lagMs":{},"selectors":[]}"#)
    #expect(TalkerRules.recordingStartLag(for: .teamsApp, selected: empty, bundled: empty) == nil)
  }

  @Test("the frozen selected document keeps its exact text; the fallback lives only in log.lag")
  func frozenPayloadExact() throws {
    let text = #"{"schema":1,"revision":9,"lagMs":{},"selectors":[]}"#
    let snapshot = try TalkerRulesSnapshot(validating: Data(text.utf8), origin: .downloaded)
    #expect(snapshot.frozen.payload == text)
    let bundled = try TalkerRules.decode(bundledData())
    let lag = TalkerRules.recordingStartLag(for: .meet, selected: snapshot.rules, bundled: bundled)
    #expect(lag?.milliseconds == 500)
    #expect(snapshot.frozen.payload == text, "resolving the fallback never touches the document")
  }

  // MARK: - Reader -> save -> reload -> name

  private func turn(_ speaker: String, _ start: Int, _ end: Int) -> Turn {
    Turn(
      id: "\(speaker)-\(start)", speakerId: speaker, startMs: start, endMs: end,
      originalTextRange: 0..<1, wasPolished: true, granularity: .word)
  }

  private func composition(_ turns: [Turn]) -> MeetingComposition {
    MeetingComposition(
      text: "x", turns: turns,
      speakerNames: Dictionary(uniqueKeysWithValues: turns.map { ($0.speakerId, "Speaker 1") }),
      echoTurnIDs: [], speakerCount: Set(turns.map(\.speakerId)).count)
  }

  private func eligibility(_ ids: Set<String>) -> MeetingNamingEligibility {
    MeetingNamingEligibility(
      callSpeakerIDs: ids, callSpeech: [MeetingNamingInterval(startMs: 0, endMs: 100_000)!],
      markers: [])
  }

  /// A Meet tile in the captured Chrome shape.
  private func tile(_ name: String, talking: Bool) -> CallAXNode {
    CallAXNode(
      role: "AXGroup", domClassList: ["oZRSLe"],
      children: [
        CallAXNode(role: "AXStaticText", value: name),
        CallAXNode(role: "AXGroup", domClassList: talking ? ["kssMZb", "BlxGDf"] : []),
      ])
  }

  private func reading(_ tiles: [CallAXNode], rule: SpeakerSelectorRule) throws
    -> CallSpeakerReading
  {
    try #require(
      RulesSpeakerReader.read(
        documents: [
          CallAXDocument(
            url: "https://meet.google.com/abc-defg-hij",
            root: CallAXNode(role: "AXWebArea", children: tiles))
        ], rule: rule))
  }

  /// Builds the saved log the way the observer will: admitted readings only, every 500 ms
  /// from 1000 ms, the start-of-recording correction, the frozen rules.
  private func savedLog(
    readings: [(CallSpeakerReading, CallCaptureContext)], lag: CallSpeakerLag?,
    snapshot: TalkerRulesSnapshot, fromList: Bool?
  ) throws -> CallSpeakerLog {
    var observations: [CallSpeakerObservation] = []
    var roster: [String] = []
    for (index, (reading, context)) in readings.enumerated() {
      guard let speaking = CallSpeakerAdmission.observationSpeaking(reading, context: context)
      else { continue }
      observations.append(
        CallSpeakerObservation(observationMs: 1_000 + index * 500, speaking: speaking))
      if roster.isEmpty { roster = reading.roster.names }
    }
    let log = CallSpeakerLog(
      surface: .meet, source: .rules, status: .observed, lag: lag, rules: snapshot.frozen,
      roster: CallSpeakerRoster(names: roster, selfNames: []),
      rosterFromParticipantList: fromList, observations: observations)
    // Save and reload through the log's own encoding.
    return try JSONDecoder().decode(CallSpeakerLog.self, from: JSONEncoder().encode(log))
  }

  @Test("tile-only readings name the talker after save and reload, provenance false or unknown")
  func tileRosterNames() throws {
    let snapshot = try TalkerRulesSnapshot(validating: bundledData(), origin: .bundled)
    let rule = snapshot.rules.rule(for: .meet)
    let lag = TalkerRules.recordingStartLag(
      for: .meet, selected: snapshot.rules, bundled: snapshot.rules)
    let talking = try reading(
      [tile("Alex Rivera", talking: true), tile("Priya Shah", talking: false)], rule: rule)
    for fromList in [false, nil] as [Bool?] {
      let log = try savedLog(
        readings: Array(repeating: (talking, Self.good), count: 5), lag: lag, snapshot: snapshot,
        fromList: fromList)
      #expect(log.lag?.milliseconds == 500)
      let result = MeetingSpeakerNamer.propose(
        composition: composition([turn("sys:S1", 0, 10_000)]),
        eligibility: eligibility(["sys:S1"]), log: log)
      #expect(result.proposals == ["sys:S1": "Alex Rivera"], "\(String(describing: fromList))")
    }
  }

  @Test("withheld readings never become observations; a shared name stays ineligible")
  func withheldAndShared() throws {
    let snapshot = try TalkerRulesSnapshot(validating: bundledData(), origin: .bundled)
    let rule = snapshot.rules.rule(for: .meet)
    let lag = CallSpeakerLag(milliseconds: 500)
    let ambiguous = try reading(
      [tile("Alex Rivera", talking: true), tile("Alex Rivera", talking: false)], rule: rule)
    let cut = try reading([tile("Priya Shah", talking: true)], rule: rule)
    let log = try savedLog(
      readings: [
        (ambiguous, Self.good), (ambiguous, Self.good),
        (cut, CallCaptureContext(completeness: .truncated, scope: .resolved)),
      ], lag: lag, snapshot: snapshot, fromList: false)
    #expect(log.observations.isEmpty, "withheld readings are left out, not saved as quiet")

    // An unrelated duplicated name does not block a unique talker.
    let unique = try reading(
      [
        tile("Alex Rivera", talking: false), tile("Alex Rivera", talking: false),
        tile("Priya Shah", talking: true),
      ],
      rule: rule)
    let named = try savedLog(
      readings: Array(repeating: (unique, Self.good), count: 5), lag: lag, snapshot: snapshot,
      fromList: false)
    #expect(named.roster.names == ["Alex Rivera", "Alex Rivera", "Priya Shah"])
    let result = MeetingSpeakerNamer.propose(
      composition: composition([turn("sys:S1", 0, 10_000)]), eligibility: eligibility(["sys:S1"]),
      log: named)
    #expect(result.proposals == ["sys:S1": "Priya Shah"])
  }

  @Test("Transcribe again uses the saved correction even after the rules change")
  func replayUsesSavedLag() throws {
    let snapshot = try TalkerRulesSnapshot(validating: bundledData(), origin: .bundled)
    let rule = snapshot.rules.rule(for: .meet)
    // Alex talks at 1000-3000 ms of indicator time; the saved +500 ms puts the votes at
    // 500-2500 ms of audio, inside S1's turn and outside S2's.
    let talking = try reading(
      [tile("Alex Rivera", talking: true), tile("Priya Shah", talking: false)], rule: rule)
    let log = try savedLog(
      readings: Array(repeating: (talking, Self.good), count: 5),
      lag: TalkerRules.recordingStartLag(
        for: .meet, selected: snapshot.rules, bundled: snapshot.rules),
      snapshot: snapshot, fromList: false)
    let turns = [turn("sys:S1", 0, 2_600), turn("sys:S2", 2_600, 10_000)]
    let first = MeetingSpeakerNamer.propose(
      composition: composition(turns), eligibility: eligibility(["sys:S1", "sys:S2"]), log: log)
    // Today's rules would say -4000 ms; the namer never reads them, only log.lag.
    let changed = try rules(#"{"schema":1,"revision":99,"lagMs":{"meet":-4000},"selectors":[]}"#)
    #expect(changed.lag(for: .meet)?.milliseconds == -4000)
    let again = MeetingSpeakerNamer.propose(
      composition: composition(turns), eligibility: eligibility(["sys:S1", "sys:S2"]), log: log)
    #expect(first == again)
    #expect(again.proposals == ["sys:S1": "Alex Rivera"])
  }

  @Test("an older log without a correction stays without one and abstains despite the defaults")
  func legacyLogAbstains() throws {
    let snapshot = try TalkerRulesSnapshot(validating: bundledData(), origin: .bundled)
    let rule = snapshot.rules.rule(for: .meet)
    let talking = try reading([tile("Alex Rivera", talking: true)], rule: rule)
    let log = try savedLog(
      readings: Array(repeating: (talking, Self.good), count: 5), lag: nil, snapshot: snapshot,
      fromList: nil)
    #expect(log.lag == nil)
    let result = MeetingSpeakerNamer.propose(
      composition: composition([turn("sys:S1", 0, 10_000)]), eligibility: eligibility(["sys:S1"]),
      log: log)
    #expect(result.outcome == .lagUnmeasured)
    #expect(result.proposals.isEmpty)
  }
}
