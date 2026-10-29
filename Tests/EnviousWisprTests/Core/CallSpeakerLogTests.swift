import Foundation
import Testing

@testable import EnviousWisprCore

/// #4013: when these fail, a meeting's saved call-speaker evidence is lost, misread after an
/// upgrade, or read as a confident guess, and real names land on the wrong lines.
@Suite("CallSpeakerLog", .tags(.productOutcome))
struct CallSpeakerLogTests {

  /// A format-1 log, read back from literal JSON so the stored shape is pinned: one `legacy`
  /// segment from 0 with no end, every field kept, and saved again as format 2.
  @Test("a format-1 log reads back as one legacy segment with every field")
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

    #expect(log.onlySegment.startMs == 0)
    #expect(log.onlySegment.endMs == nil)
    #expect(log.onlySegment.endReason == .legacy)

    let reencoded = try JSONDecoder().decode(
      CallSpeakerLog.self, from: try JSONEncoder().encode(log))
    #expect(reencoded.formatVersion == 2)
    #expect(reencoded.segments == log.segments)
    #expect(reencoded.rules == log.rules)
  }

  /// Format 2 as this build writes it, pinned from literal JSON.
  @Test("a format-2 log reads back from its stored JSON with every segment")
  func readsSegments() throws {
    let json = """
      {"formatVersion":2,"rules":{"version":3,"payload":"{}"},
       "segments":[
        {"startMs":0,"endMs":4000,"endReason":"source_changed","surface":"zoom_app","source":"app",
         "status":"observed","lag":{"milliseconds":300},
         "roster":{"names":["Alex Rivera"],"selfNames":[]},"rosterFromParticipantList":true,
         "observations":[{"observationMs":1500,"speaking":["Alex Rivera"]}]},
        {"startMs":6000,"surface":"meet","source":"rules","status":"no_permission",
         "roster":{"names":[],"selfNames":[]},"observations":[]}]}
      """
    let log = try JSONDecoder().decode(CallSpeakerLog.self, from: Data(json.utf8))
    #expect(log.segments.count == 2)
    #expect(log.segments[0].endReason == .sourceChanged)
    #expect(log.segments[0].lag == CallSpeakerLag(milliseconds: 300))
    #expect(log.segments[1].startMs == 6_000)
    #expect(log.segments[1].endMs == nil)
    #expect(log.segments[1].status == .noPermission)
    #expect(log.singleSurface == nil, "a mixed recording reports no one surface")
    let back = try JSONDecoder().decode(CallSpeakerLog.self, from: JSONEncoder().encode(log))
    #expect(back == log)
  }

  @Test(
    "segments that overlap, an open segment before another, or observations outside a segment are refused",
    arguments: [
      #"{"formatVersion":2,"segments":[{"startMs":0,"endMs":5000},{"startMs":4000}]}"#,
      #"{"formatVersion":2,"segments":[{"startMs":0},{"startMs":4000}]}"#,
      #"{"formatVersion":2,"segments":[{"startMs":5000,"endMs":4000}]}"#,
      #"{"formatVersion":2,"segments":[{"startMs":1000,"observations":[{"observationMs":500,"speaking":[]}]}]}"#,
      #"{"formatVersion":2,"segments":[{"startMs":0,"endMs":1000,"observations":[{"observationMs":1500,"speaking":[]}]}]}"#,
    ])
  func segmentRefusals(json: String) {
    #expect(throws: CallSpeakerLog.DecodeError.self) {
      try JSONDecoder().decode(CallSpeakerLog.self, from: Data(json.utf8))
    }
  }

  @Test("presence and health round-trip; presence outside its segment is refused")
  func presenceShape() throws {
    var health = CallCaptureHealth()
    health.captureAttempts = 3
    health.withheldByReason = ["unnamedTalker": 1]
    let inside = CallNamePresence(
      name: "Alex Rivera",
      sightings: [.init(firstSeenMs: 1_000, lastSeenMs: 2_000, absenceConfirmed: true)],
      absences: [.init(firstMissingMs: 2_500, confirmedAtMs: 3_500)])
    func log(_ presence: CallNamePresence) -> CallSpeakerLog {
      CallSpeakerLog(
        rules: nil, presencePolicy: .current,
        segments: [
          CallSpeakerSegment(
            startMs: 500, endMs: 4_000, endReason: .recordingEnded, surface: .teamsApp,
            source: .app, status: .observed, lag: nil, roster: .empty,
            rosterFromParticipantList: true, observations: [], presence: [presence],
            health: health)
        ], sessionHealth: CallSessionHealth())
    }
    let good = log(inside)
    #expect(good.shapeProblem == nil)
    #expect(try JSONDecoder().decode(CallSpeakerLog.self, from: JSONEncoder().encode(good)) == good)
    let outside = CallNamePresence(
      name: "Alex Rivera",
      sightings: [.init(firstSeenMs: 100, lastSeenMs: 2_000, absenceConfirmed: false)],
      absences: [])
    #expect(log(outside).shapeProblem != nil)
  }

  @Test(
    "contradictory presence is refused",
    arguments: [
      // An absence with no confirmed sighting before it.
      CallNamePresence(
        name: "Alex Rivera",
        sightings: [.init(firstSeenMs: 3_000, lastSeenMs: 3_500, absenceConfirmed: false)],
        absences: [.init(firstMissingMs: 1_000, confirmedAtMs: 2_000)]),
      // An unconfirmed sighting before another.
      CallNamePresence(
        name: "Alex Rivera",
        sightings: [
          .init(firstSeenMs: 1_000, lastSeenMs: 1_500, absenceConfirmed: false),
          .init(firstSeenMs: 3_000, lastSeenMs: 3_500, absenceConfirmed: false),
        ], absences: []),
      // A confirmed sighting with no absence.
      CallNamePresence(
        name: "Alex Rivera",
        sightings: [.init(firstSeenMs: 1_000, lastSeenMs: 1_500, absenceConfirmed: true)],
        absences: []),
      // Seen again before the absence was confirmed.
      CallNamePresence(
        name: "Alex Rivera",
        sightings: [
          .init(firstSeenMs: 1_000, lastSeenMs: 1_500, absenceConfirmed: true),
          .init(firstSeenMs: 2_500, lastSeenMs: 3_500, absenceConfirmed: false),
        ], absences: [.init(firstMissingMs: 2_000, confirmedAtMs: 3_000)]),
    ])
  func contradictoryPresence(presence: CallNamePresence) {
    let segment = CallSpeakerSegment(
      startMs: 0, endMs: nil, endReason: nil, surface: .teamsApp, source: .app, status: .observed,
      lag: nil, roster: .empty, rosterFromParticipantList: true, observations: [],
      presence: [presence])
    #expect(segment.shapeProblem != nil)
  }

  @Test("one name listed twice in a segment's presence is refused")
  func duplicatePresence() {
    let entry = CallNamePresence(
      name: "Alex Rivera",
      sightings: [.init(firstSeenMs: 1_000, lastSeenMs: 1_500, absenceConfirmed: false)],
      absences: [])
    let segment = CallSpeakerSegment(
      startMs: 0, endMs: nil, endReason: nil, surface: .teamsApp, source: .app, status: .observed,
      lag: nil, roster: .empty, rosterFromParticipantList: true, observations: [],
      presence: [entry, entry])
    #expect(segment.shapeProblem == "presence names repeat")
  }

  @Test("more segments than the bound are refused")
  func segmentBound() {
    let segments = (0...CallSpeakerLog.maximumSegments).map {
      CallSpeakerSegment(
        startMs: $0 * 10, endMs: $0 * 10 + 5, endReason: .sourceLost, surface: .meet,
        source: .rules, status: .observed, lag: nil, roster: .empty,
        rosterFromParticipantList: nil, observations: [])
    }
    #expect(CallSpeakerLog(rules: nil, segments: segments).shapeProblem == "segments")
    #expect(CallSpeakerLog(rules: nil, segments: Array(segments.dropLast())).shapeProblem == nil)
  }

  @Test("the combined roster keeps one person seen in two calls once, and two sharing a name twice")
  func combinedRoster() {
    func segment(_ start: Int, _ names: [String], selfNames: [String] = []) -> CallSpeakerSegment {
      CallSpeakerSegment(
        startMs: start, endMs: start + 1_000, endReason: .sourceChanged, surface: .meet,
        source: .rules, status: .observed, lag: nil,
        roster: CallSpeakerRoster(names: names, selfNames: selfNames),
        rosterFromParticipantList: nil, observations: [])
    }
    let log = CallSpeakerLog(
      rules: nil,
      segments: [
        segment(0, ["Alex Rivera", "Sam"], selfNames: ["Sam"]),
        segment(2_000, ["Priya Shah", "Alex Rivera", "Priya Shah"]),
      ])
    #expect(log.combinedRoster.names == ["Alex Rivera", "Sam", "Priya Shah", "Priya Shah"])
    #expect(log.combinedRoster.selfNames == ["Sam"])
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
    let segment = try #require((object["segments"] as? [[String: Any]])?.first)
    #expect(segment["surface"] as? String == "discord", "re-save keeps the newer build's value")
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
    #expect(throws: CallSpeakerLog.DecodeError.unsupportedFormatVersion(3)) {
      try JSONDecoder().decode(CallSpeakerLog.self, from: Data(#"{"formatVersion":3}"#.utf8))
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
    #expect(throws: CallSpeakerLog.DecodeError.unsupportedFormatVersion(3)) {
      try JSONDecoder().decode(CallSpeakerLog.self, from: Data(#"{"formatVersion":3}"#.utf8))
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
