import Foundation
import Testing

@testable import EnviousWisprCore

/// #4013: when these fail, a meeting's saved call-speaker evidence is lost, misread after an
/// upgrade, or read as a confident guess, and real names land on the wrong lines.
@Suite("CallSpeakerLog", .tags(.productOutcome))
struct CallSpeakerLogTests {

  /// A log as this build writes it, read back from literal JSON so the stored shape is pinned.
  @Test("a saved log reads back from its stored JSON with every field")
  func readsStoredShape() throws {
    let json = """
      {"formatVersion":1,"surface":"teams_app","source":"app","status":"observed",
       "lag":{"milliseconds":-350},
       "rules":{"version":3,"payload":"{\\"meet\\":[\\"kssMZb\\"]}"},
       "roster":{"names":["Alex Rivera","Priya Shah","Alex Rivera"],"selfNames":["Saurabh Vaish"]},
       "observations":[{"observationMs":1500,"speaking":["Alex Rivera"]},
                       {"observationMs":2000,"speaking":[]}]}
      """
    let log = try JSONDecoder().decode(CallSpeakerLog.self, from: Data(json.utf8))
    #expect(log.surface == .teamsApp)
    #expect(log.source == .app)
    #expect(log.status == .observed)
    #expect(log.lag == CallSpeakerLag(milliseconds: -350))
    #expect(log.rules == FrozenTalkerRules(version: 3, payload: #"{"meet":["kssMZb"]}"#))
    #expect(log.roster.names == ["Alex Rivera", "Priya Shah", "Alex Rivera"], "duplicates kept")
    #expect(log.roster.selfNames == ["Saurabh Vaish"])
    #expect(
      log.observations == [
        CallSpeakerObservation(observationMs: 1500, speaking: ["Alex Rivera"]),
        CallSpeakerObservation(observationMs: 2000, speaking: []),
      ])

    let reencoded = try JSONDecoder().decode(
      CallSpeakerLog.self, from: try JSONEncoder().encode(log))
    #expect(reencoded == log)
  }

  /// A newer build may add a surface, source or status; this build must read it as unknown,
  /// not fail and not map it to something it knows.
  @Test("an unknown surface, source or status reads as unknown and survives a re-save")
  func unknownValuesStayUnknown() throws {
    let json = """
      {"formatVersion":1,"surface":"discord","source":"vision","status":"paused",
       "roster":{"names":[],"selfNames":[]},"observations":[]}
      """
    let log = try JSONDecoder().decode(CallSpeakerLog.self, from: Data(json.utf8))
    #expect(log.surface == nil)
    #expect(log.source == nil)
    #expect(log.status == nil)
    let object = try #require(
      try JSONSerialization.jsonObject(with: try JSONEncoder().encode(log)) as? [String: Any])
    #expect(object["surface"] as? String == "discord", "re-save keeps the newer build's value")
  }

  /// Missing metadata is unknown, never filled in: no lag means no lag was measured.
  @Test("a log with only the format version reads with no lag, rules, roster or samples")
  func minimalLog() throws {
    let log = try JSONDecoder().decode(
      CallSpeakerLog.self, from: Data(#"{"formatVersion":1}"#.utf8))
    #expect(log.surface == nil)
    #expect(log.lag == nil)
    #expect(log.rules == nil)
    #expect(log.roster == .empty)
    #expect(log.observations.isEmpty)
  }

  @Test("a log from a newer format fails to decode instead of being misread")
  func newerFormatRefused() {
    #expect(throws: CallSpeakerLog.DecodeError.unsupportedFormatVersion(2)) {
      try JSONDecoder().decode(CallSpeakerLog.self, from: Data(#"{"formatVersion":2}"#.utf8))
    }
  }

  /// r2 item 2: lag is indicator time minus voice onset, so a positive lag moves the voice
  /// earlier and a negative lag moves it later.
  @Test("lag of either sign moves an observation onto the voice it points to")
  func signedLag() {
    #expect(CallSpeakerLag(milliseconds: 500).audioAlignedMs(10_000) == 9_500)
    #expect(CallSpeakerLag(milliseconds: -250).audioAlignedMs(10_000) == 10_250)
    #expect(CallSpeakerLag(milliseconds: 0).audioAlignedMs(42) == 42)
  }

  @Test("a version below 1 is invalid, while a newer version stays its own answer")
  func unsupportedOlderVersions() {
    for version in [0, -1] {
      #expect(throws: CallSpeakerLog.DecodeError.invalid("formatVersion")) {
        try JSONDecoder().decode(
          CallSpeakerLog.self, from: Data(#"{"formatVersion":\#(version)}"#.utf8))
      }
    }
    #expect(throws: CallSpeakerLog.DecodeError.unsupportedFormatVersion(2)) {
      try JSONDecoder().decode(CallSpeakerLog.self, from: Data(#"{"formatVersion":2}"#.utf8))
    }
  }

  @Test("roster source reads back as saved, and a log without it reads as unknown")
  func rosterSource() throws {
    for value in [true, false] {
      let log = CallSpeakerLog(
        surface: .meet, source: .rules, status: .observed, lag: nil, rules: nil,
        roster: CallSpeakerRoster(names: ["Alex Rivera", "Alex Rivera"], selfNames: []),
        rosterFromParticipantList: value, observations: [])
      let back = try JSONDecoder().decode(CallSpeakerLog.self, from: JSONEncoder().encode(log))
      #expect(back.rosterFromParticipantList == value)
    }
    let legacy = try JSONDecoder().decode(
      CallSpeakerLog.self, from: Data(#"{"formatVersion":1}"#.utf8))
    #expect(legacy.rosterFromParticipantList == nil)
  }

  @Test(
    "a log with a bad lag, time, order, name or frozen rules is refused whole",
    arguments: [
      #"{"formatVersion":1,"lag":{"milliseconds":-9223372036854775808}}"#,
      #"{"formatVersion":1,"lag":{"milliseconds":60001}}"#,
      #"{"formatVersion":1,"observations":[{"observationMs":-1,"speaking":[]}]}"#,
      #"{"formatVersion":1,"observations":[{"observationMs":172800001,"speaking":[]}]}"#,
      #"{"formatVersion":1,"observations":[{"observationMs":5,"speaking":[]},{"observationMs":4,"speaking":[]}]}"#,
      #"{"formatVersion":1,"observations":[{"observationMs":5,"speaking":[""]}]}"#,
      #"{"formatVersion":1,"roster":{"names":[""],"selfNames":[]}}"#,
      #"{"formatVersion":1,"rules":{"version":0,"payload":"{}"}}"#,
      #"{"formatVersion":1,"rules":{"version":1,"payload":""}}"#,
    ])
  func shapeRefusals(json: String) {
    #expect(throws: CallSpeakerLog.DecodeError.self) {
      try JSONDecoder().decode(CallSpeakerLog.self, from: Data(json.utf8))
    }
  }

  @Test("the bounds themselves are admitted: lag of a minute, two days of clock, equal times")
  func shapeBounds() throws {
    let json = """
      {"formatVersion":1,"lag":{"milliseconds":-60000},
       "observations":[{"observationMs":0,"speaking":[]},{"observationMs":0,"speaking":["A"]},
                       {"observationMs":172800000,"speaking":[]}]}
      """
    let log = try JSONDecoder().decode(CallSpeakerLog.self, from: Data(json.utf8))
    #expect(log.observations.count == 3)
    let payload = String(repeating: "x", count: FrozenTalkerRules.maximumPayloadBytes)
    let big = CallSpeakerLog(
      surface: nil, source: nil, status: nil, lag: nil,
      rules: FrozenTalkerRules(version: 1, payload: payload), roster: .empty,
      rosterFromParticipantList: nil, observations: [])
    #expect(big.shapeProblem == nil)
    let tooBig = CallSpeakerLog(
      surface: nil, source: nil, status: nil, lag: nil,
      rules: FrozenTalkerRules(version: 1, payload: payload + "x"), roster: .empty,
      rosterFromParticipantList: nil, observations: [])
    #expect(tooBig.shapeProblem == "rules.payload")
  }
}
