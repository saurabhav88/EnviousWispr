import Foundation
import Testing

@testable import EnviousWisprCore

/// #4013: when these fail, a meeting's saved call-speaker evidence is lost, misread after an
/// upgrade, or read as a confident guess, and real names land on the wrong lines.
@Suite("CallSpeakerLog", .tags(.productOutcome))
struct CallSpeakerLogTests {

  /// A format-1 log, read back from literal JSON so the stored shape is pinned: one `legacy`
  /// segment from 0 with no end, every field kept, and saved again as the current format.
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
    #expect(reencoded.formatVersion == CallSpeakerLog.currentFormatVersion)
    #expect(reencoded.segments == log.segments)
    #expect(reencoded.rules == log.rules)
  }

  /// Format 2 as the earlier build wrote it, pinned from literal JSON.
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
    #expect(
      back.formatVersion == CallSpeakerLog.currentFormatVersion, "saved as the current format")
    #expect(back.segments == log.segments)
    #expect(back.rules == log.rules)
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
    #expect(throws: CallSpeakerLog.DecodeError.unsupportedFormatVersion(4)) {
      try JSONDecoder().decode(CallSpeakerLog.self, from: Data(#"{"formatVersion":4}"#.utf8))
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
    #expect(throws: CallSpeakerLog.DecodeError.unsupportedFormatVersion(4)) {
      try JSONDecoder().decode(CallSpeakerLog.self, from: Data(#"{"formatVersion":4}"#.utf8))
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

  // MARK: - Format 3 (#4013 13B.5)

  private static func segment(
    startMs: Int, endMs: Int?, observations: [CallSpeakerObservation],
    presence: [CallNamePresence]? = nil
  ) -> CallSpeakerSegment {
    CallSpeakerSegment(
      startMs: startMs, endMs: endMs, endReason: endMs == nil ? nil : .sourceChanged,
      surface: .teamsApp, source: .app, status: .observed, lag: CallSpeakerLag(milliseconds: -350),
      roster: CallSpeakerRoster(
        names: ["Alex Rivera", "Priya Shah", "Alex Rivera"], selfNames: ["Saurabh Vaish"]),
      rosterFromParticipantList: true, observations: observations, presence: presence,
      health: CallCaptureHealth())
  }

  @Test("format 3 reads back exactly the samples it was written from, in runs and a name table")
  func formatThreeRoundTrip() throws {
    func at(_ ms: Int, _ speaking: [String]) -> CallSpeakerObservation {
      CallSpeakerObservation(observationMs: ms, speaking: speaking)
    }
    let log = CallSpeakerLog(
      rules: FrozenTalkerRules(version: 3, payload: #"{"meet":["kssMZb"]}"#),
      presencePolicy: .current,
      segments: [
        Self.segment(
          startMs: 0, endMs: 10_000,
          observations: [
            // Jittered times and a busy gap inside one run; a quiet run; two talkers; a gap
            // past the run limit; equal times.
            at(1_000, ["Alex Rivera"]), at(1_520, ["Alex Rivera"]), at(2_110, ["Alex Rivera"]),
            at(3_700, ["Alex Rivera"]), at(3_900, []), at(4_400, []),
            at(4_900, ["Priya Shah", "Alex Rivera"]), at(4_900, ["Priya Shah", "Alex Rivera"]),
            at(7_000, ["Priya Shah", "Alex Rivera"]), at(7_500, ["Alex Rivera", "Priya Shah"]),
          ],
          presence: [
            CallNamePresence(
              name: "Priya Shah",
              sightings: [
                .init(firstSeenMs: 1_000, lastSeenMs: 2_000, absenceConfirmed: true),
                .init(firstSeenMs: 6_000, lastSeenMs: 9_000, absenceConfirmed: false),
              ],
              absences: [.init(firstMissingMs: 2_500, confirmedAtMs: 3_600)])
          ]),
        Self.segment(
          startMs: 10_000, endMs: nil, observations: [at(10_500, ["Dana Okafor"])]),
      ],
      sessionHealth: CallSessionHealth())
    let data = try JSONEncoder().encode(log)
    let decoded = try JSONDecoder().decode(CallSpeakerLog.self, from: data)
    #expect(decoded == log)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["formatVersion"] as? Int == 3)
    #expect(
      object["names"] as? [String]
        == ["Alex Rivera", "Priya Shah", "Saurabh Vaish", "Dana Okafor"], "each name once")
    let segments = try #require(object["segments"] as? [[String: Any]])
    let runs = try #require(segments.first?["runs"] as? [[String: Any]])
    #expect(runs.count == 6)
    #expect(runs.first?["offsets"] as? [Int] == [0, 520, 1_110], "exact times, not a count")
  }

  @Test("a format-3 log pointing outside its name table, or with a broken run, is refused")
  func formatThreeDamage() {
    let base = #"{"formatVersion":3,"names":["Alex Rivera"],"segments":[{"startMs":0,"#
    for (json, problem) in [
      (base + #""roster":{"names":[1],"selfNames":[]},"runs":[]}]}"#, "name id"),
      (
        base
          + #""roster":{"names":[],"selfNames":[]},"runs":[{"startMs":5,"speaking":[0],"offsets":[]}]}]}"#,
        "runs"
      ),
      (
        base
          + #""roster":{"names":[],"selfNames":[]},"runs":[{"startMs":5,"speaking":[0],"offsets":[3]}]}]}"#,
        "runs"
      ),
      (
        base
          + #""roster":{"names":[],"selfNames":[]},"runs":[{"startMs":5,"speaking":[0],"offsets":[0,9,4]}]}]}"#,
        "runs"
      ),
      (#"{"formatVersion":3,"names":["A","A"],"segments":[]}"#, "names"),
    ] {
      #expect(throws: CallSpeakerLog.DecodeError.invalid(problem)) {
        try JSONDecoder().decode(CallSpeakerLog.self, from: Data(json.utf8))
      }
    }
  }

  @Test("a name too long in characters or in bytes is no name")
  func nameBounds() {
    #expect(CallSpeakerLog.isName(String(repeating: "a", count: 256)))
    #expect(!CallSpeakerLog.isName(String(repeating: "a", count: 257)))
    // One character holding 600 combining marks: 1,201 bytes.
    let heavy = "a" + String(repeating: "\u{0301}", count: 600)
    #expect(heavy.count == 1)
    #expect(!CallSpeakerLog.isName(heavy))
  }

  @Test("a format-3 log past a cap is refused; an older format is read as it was written")
  func formatThreeCaps() throws {
    var limits = CallEvidenceLimits.current
    let names = (0...limits.names).map { "Person \($0)" }
    let roster = CallSpeakerRoster(names: names, selfNames: [])
    let segment = CallSpeakerSegment(
      startMs: 0, endMs: nil, endReason: nil, surface: .teamsApp, source: .app,
      status: .observed, lag: nil, roster: roster, rosterFromParticipantList: true,
      observations: [])
    let log = CallSpeakerLog(rules: nil, segments: [segment])
    #expect(log.shapeProblem == "capacity.names")
    limits.names += 1
    #expect(CallEvidenceUsage([segment]).exceeded(limits) == nil, "control: one more fits")
    let older =
      #"{"formatVersion":2,"segments":[{"startMs":0,"roster":{"names":"#
      + "[\(names.map { "\"\($0)\"" }.joined(separator: ","))],\"selfNames\":[]}}]}"
    let read = try JSONDecoder().decode(CallSpeakerLog.self, from: Data(older.utf8))
    #expect(read.formatVersion == 2)
    #expect(read.segments.first?.roster.names.count == names.count)
  }

  @Test("format 3 keeps every spelling's exact bytes, even two Swift calls equal")
  func spellingsKeepTheirBytes() throws {
    let composed = "Am\u{00E9}lie"
    let decomposed = "Ame\u{0301}lie"
    #expect(composed == decomposed, "Swift calls them equal")
    let log = CallSpeakerLog(
      rules: nil,
      segments: [
        CallSpeakerSegment(
          startMs: 0, endMs: nil, endReason: nil, surface: .meet, source: .rules,
          status: .observed, lag: nil,
          roster: CallSpeakerRoster(names: [composed], selfNames: []),
          rosterFromParticipantList: false,
          observations: [
            CallSpeakerObservation(observationMs: 1_000, speaking: [decomposed]),
            CallSpeakerObservation(observationMs: 1_500, speaking: [composed]),
          ])
      ])
    let back = try JSONDecoder().decode(CallSpeakerLog.self, from: JSONEncoder().encode(log))
    let segment = try #require(back.segments.first)
    func bytes(_ names: [String]) -> [[UInt8]] { names.map { Array($0.utf8) } }
    #expect(bytes(segment.roster.names) == bytes([composed]))
    #expect(bytes(segment.observations.flatMap(\.speaking)) == bytes([decomposed, composed]))
  }

  @Test("a format-2 log keeps its own name rule; the current format refuses what it cannot hold")
  func legacyNamesReadAsWritten() throws {
    // One character holding 600 combining marks: a name format 2 allowed.
    let heavy = "a" + String(repeating: "\u{0301}", count: 600)
    let json =
      #"{"formatVersion":2,"segments":[{"startMs":0,"roster":{"names":[""#
      + heavy + #""],"selfNames":[]}}]}"#
    let log = try JSONDecoder().decode(CallSpeakerLog.self, from: Data(json.utf8))
    #expect(log.shapeProblem == nil)
    #expect(log.currentFormatProblem == "names")
    #expect(throws: EncodingError.self) { try JSONEncoder().encode(log) }
  }

  @Test("a small format-3 file that would unfold past a cap is refused before it unfolds")
  func compactOverCapRefused() {
    let samples = CallEvidenceLimits.current.samples + 1
    let oneRun =
      #"{"formatVersion":3,"names":[],"segments":[{"startMs":0,"roster":{"names":[],"selfNames":[]},"runs":[{"startMs":0,"speaking":[],"offsets":["#
      + Array(repeating: "0", count: samples).joined(separator: ",") + "]}]}]}"
    let runs = CallEvidenceLimits.current.runs + 1
    let manyRuns =
      #"{"formatVersion":3,"names":[],"segments":[{"startMs":0,"roster":{"names":[],"selfNames":[]},"runs":["#
      + Array(repeating: #"{"startMs":0,"speaking":[],"offsets":[0]}"#, count: runs)
      .joined(separator: ",") + "]}]}"
    for (json, cap) in [(oneRun, "samples"), (manyRuns, "runs")] {
      #expect(throws: CallSpeakerLog.DecodeError.invalid("capacity.\(cap)")) {
        try JSONDecoder().decode(CallSpeakerLog.self, from: Data(json.utf8))
      }
    }
  }

  @Test("a format-3 log with an overlong label or too many health keys is refused")
  func labelBounds() {
    let long = String(repeating: "x", count: CallSpeakerLog.maximumLabelBytes + 1)
    let json =
      #"{"formatVersion":3,"names":[],"segments":[{"startMs":0,"roster":{"names":[],"selfNames":[]},"runs":[],"surface":""#
      + long + #""}]}"#
    #expect(throws: CallSpeakerLog.DecodeError.invalid("segments[0].labels")) {
      try JSONDecoder().decode(CallSpeakerLog.self, from: Data(json.utf8))
    }
    var health = CallCaptureHealth()
    for n in 0...CallSpeakerLog.maximumHealthKeys { health.withheldByReason["k\(n)"] = 1 }
    let log = CallSpeakerLog(
      rules: nil,
      segments: [
        CallSpeakerSegment(
          startMs: 0, endMs: nil, endReason: nil, surface: .meet, source: .rules,
          status: .observed, lag: nil, roster: .empty, rosterFromParticipantList: nil,
          observations: [], health: health)
      ])
    #expect(log.shapeProblem == "segments[0].health")
    #expect(CallSpeakerLog.isLabel("capacity_reached"))
    #expect(!CallSpeakerLog.isLabel("tab\there"), "text that grows when written is no label")
    #expect(!CallSpeakerLog.isLabel("caf\u{00E9}"))
  }

  // MARK: - Two-person stretches (#4013 chunk 14)

  private static func withPairs(_ pairs: [CallPairStretch]?, endMs: Int? = 60_000)
    -> CallSpeakerLog
  {
    CallSpeakerLog(
      rules: nil,
      segments: [
        CallSpeakerSegment(
          startMs: 1_000, endMs: endMs, endReason: endMs == nil ? nil : .recordingEnded,
          surface: .zoomApp, source: .app, status: .observed,
          lag: CallSpeakerLag(milliseconds: 500), roster: .empty, rosterFromParticipantList: true,
          observations: [], pairs: pairs)
      ])
  }

  @Test("two-person stretches round-trip through the name table; a log without them reads as unknown")
  func pairsRoundTrip() throws {
    let log = Self.withPairs([
      CallPairStretch(
        names: ["Saurabh Vaish", "Alex Rivera"], selfNames: ["Saurabh Vaish"], firstMs: 2_000,
        lastMs: 20_000),
      CallPairStretch(
        names: ["Saurabh Vaish", "Priya Shah"], selfNames: [], firstMs: 30_000, lastMs: 30_000),
    ])
    let data = try JSONEncoder().encode(log)
    #expect(try JSONDecoder().decode(CallSpeakerLog.self, from: data) == log)
    let none = try JSONDecoder().decode(
      CallSpeakerLog.self, from: JSONEncoder().encode(Self.withPairs(nil)))
    #expect(none.segments[0].pairs == nil)
    #expect(
      try JSONDecoder().decode(CallSpeakerLog.self, from: JSONEncoder().encode(Self.withPairs([])))
        .segments[0].pairs == [])
  }

  @Test("a stretch with the wrong names, out of order, or outside its segment is refused")
  func pairShapes() {
    func stretch(_ names: [String], _ first: Int, _ last: Int, marked: [String] = [])
      -> CallPairStretch
    {
      CallPairStretch(names: names, selfNames: marked, firstMs: first, lastMs: last)
    }
    let two = ["Saurabh Vaish", "Alex Rivera"]
    #expect(Self.withPairs([stretch(two, 1_000, 60_000)]).shapeProblem == nil, "the bounds hold")
    for (pairs, why) in [
      ([stretch(["Alex Rivera"], 2_000, 3_000)], "one name"),
      ([stretch(["Alex Rivera", "Alex Rivera"], 2_000, 3_000)], "the same name twice"),
      ([stretch(two + ["Priya Shah"], 2_000, 3_000)], "three names"),
      ([stretch(two, 2_000, 3_000, marked: two + ["Priya Shah"])], "three marks"),
      ([stretch(two, 3_000, 2_000)], "runs backwards"),
      ([stretch(two, 500, 3_000)], "before the segment"),
      ([stretch(two, 2_000, 60_001)], "after the segment"),
      ([stretch(two, 2_000, 5_000), stretch(two, 5_000, 6_000)], "overlapping"),
      ([stretch(two, 7_000, 8_000), stretch(two, 2_000, 3_000)], "out of order"),
    ] {
      #expect(Self.withPairs(pairs).shapeProblem != nil, "\(why)")
    }
  }

  @Test("a format-3 file with too many stretches, or a stretch with too many names, is refused")
  func pairCaps() {
    let one = #"{"names":[0,1],"selfNames":[0],"firstMs":0,"lastMs":0}"#
    func json(_ pairs: [String]) -> String {
      #"{"formatVersion":3,"names":["A","B"],"segments":[{"startMs":0,"roster":{"names":[],"selfNames":[]},"runs":[],"pairs":["#
        + pairs.joined(separator: ",") + "]}]}"
    }
    let tooMany = json(Array(repeating: one, count: CallEvidenceLimits.current.pairs + 1))
    let tooWide = json([#"{"names":[0,1],"selfNames":[0,1,0],"firstMs":0,"lastMs":0}"#])
    for text in [tooMany, tooWide] {
      #expect(throws: CallSpeakerLog.DecodeError.invalid("capacity.pairs")) {
        try JSONDecoder().decode(CallSpeakerLog.self, from: Data(text.utf8))
      }
    }
  }
}
