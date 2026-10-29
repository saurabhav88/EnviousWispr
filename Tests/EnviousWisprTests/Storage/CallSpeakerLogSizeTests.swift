import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprServices
@testable import EnviousWisprStorage

/// #4013 13B.5: when these fail, a long or crowded meeting's speaker evidence grows past what
/// storage accepts, every later save fails, and the meeting loses its speaker names.
///
/// The fixture fills every cap in `CallEvidenceLimits` at once, with names that escape to six
/// bytes a character, every counter at its largest and the longest text values, and goes
/// through the real storage encoder and store. Building, saving and reading 345,600 samples
/// takes about eight seconds in a Debug build: that size is the subject.
@Suite("Speaker log size", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct CallSpeakerLogSizeTests {
  private static let limits = CallEvidenceLimits.current

  /// The ceilings from the 13B.5 plan (`13b4-size-arch.txt.last` §2), by component, plus the
  /// chunk-14 two-person stretches: at most 256 bytes each, 1 MiB for all of them.
  private static let namesCeiling = 512 * (6 * 1_024 + 3)
  private static let segmentFramesCeiling = 1_000 * 4_096
  private static let pairCeiling = 256
  private static let wholeCeiling = 14_348_352 + CallEvidenceLimits.current.pairs * 256

  /// `limits.names` distinct names of 256 control characters each.
  private static let names: [String] = (0..<limits.names).map { n in
    let a = Character(Unicode.Scalar(UInt8(1 + n / 31)))
    let b = Character(Unicode.Scalar(UInt8(1 + n % 31)))
    return String(repeating: "\u{1}", count: 254) + String(a) + String(b)
  }

  /// `value` with every number in its JSON set to `Int.max`.
  private static func maxed<T: Codable>(_ value: T) throws -> T {
    func walk(_ any: Any) -> Any {
      if let dictionary = any as? [String: Any] { return dictionary.mapValues(walk) }
      if let array = any as? [Any] { return array.map(walk) }
      if let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        return Int.max
      }
      return any
    }
    let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(value))
    let data = try JSONSerialization.data(withJSONObject: walk(object))
    return try JSONDecoder().decode(T.self, from: data)
  }

  private static func health() throws -> CallCaptureHealth {
    var health = CallCaptureHealth()
    for reason in CallNamingAdmission.Reason.allCases {
      health.withheldByReason[reason.rawValue] = 1
    }
    return try maxed(health)
  }

  /// Segments that each carry the most of every count, spread so the totals hit the caps.
  private static func fullLog() throws -> CallSpeakerLog {
    let segmentCount = CallSpeakerLog.maximumSegments
    let span = CallSpeakerObservation.maximumObservationMs / segmentCount
    let health = try health()
    var sessionHealth = try maxed(CallSessionHealth())
    sessionHealth.capacityReason = CallEvidenceCapacity.speakingReferences.rawValue
    var nameCursor = 0
    func nextName() -> String {
      defer { nameCursor = (nameCursor + 1) % names.count }
      return names[nameCursor]
    }
    let runsEach = limits.runs / segmentCount
    let rosterEach = limits.rosterReferences / segmentCount
    let speakingEach = limits.speakingReferences / limits.runs
    var segments: [CallSpeakerSegment] = []
    var presenceLeft = limits.presenceEntries
    var sightingsLeft = limits.sightings
    var pairsLeft = limits.pairs
    for index in 0..<segmentCount {
      let start = index * span
      // 346 samples in the first segments, 345 after, to total exactly `limits.samples`.
      let base = limits.samples / segmentCount
      let samples = base + (index < limits.samples - base * segmentCount ? 1 : 0)
      var observations: [CallSpeakerObservation] = []
      for run in 0..<runsEach {
        // Neighbouring runs name different talkers, so none merges with the next.
        let speaking = (0..<speakingEach).map {
          names[(index * runsEach + run + $0 * 7) % names.count]
        }
        let inRun = samples / runsEach + (run < samples % runsEach ? 1 : 0)
        for _ in 0..<inRun {
          observations.append(
            CallSpeakerObservation(
              observationMs: start + observations.count * 499, speaking: speaking))
        }
      }
      let presenceHere = presenceLeft / (segmentCount - index)
      presenceLeft -= presenceHere
      var presence: [CallNamePresence] = []
      for entry in 0..<presenceHere {
        // Two sightings and two absences each until only enough remain for one each.
        let pairs = sightingsLeft > presenceLeft + (presenceHere - entry) ? 2 : 1
        sightingsLeft -= pairs
        let t = start + 1_000 + entry * 10_000
        presence.append(
          CallNamePresence(
            name: names[(index * 5 + entry) % names.count],
            sightings: (0..<pairs).map {
              .init(
                firstSeenMs: t + $0 * 4_000, lastSeenMs: t + $0 * 4_000 + 1_000,
                absenceConfirmed: true)
            },
            absences: (0..<pairs).map {
              .init(firstMissingMs: t + $0 * 4_000 + 1_500, confirmedAtMs: t + $0 * 4_000 + 3_000)
            },
            sightingsFull: true))
      }
      let pairsHere = pairsLeft / (segmentCount - index)
      pairsLeft -= pairsHere
      let pairs = (0..<pairsHere).map { k in
        // Five of the longest names each, at the segment's largest times.
        CallPairStretch(
          names: [names[k % names.count], names[(k + 1) % names.count]],
          selfNames: [names[(k + 2) % names.count], names[(k + 3) % names.count]],
          accountNames: [names[(k + 4) % names.count]],
          firstMs: start + span - 1 - (pairsHere - k) * 2, lastMs: start + span - (pairsHere - k) * 2)
      }
      segments.append(
        CallSpeakerSegment(
          startMs: start, endMs: start + span, endReason: .capacityReached, surface: .teamsApp,
          source: .app, status: .noPermission, lag: CallSpeakerLag(milliseconds: -60_000),
          roster: CallSpeakerRoster(
            names: (0..<(rosterEach - 1)).map { _ in nextName() }, selfNames: [nextName()]),
          rosterFromParticipantList: true, observations: observations, presence: presence,
          health: health, pairs: pairs))
    }
    return CallSpeakerLog(
      rules: FrozenTalkerRules(
        version: .max,
        payload: String(repeating: "\u{1}", count: FrozenTalkerRules.maximumPayloadBytes)),
      presencePolicy: .current, segments: segments, sessionHealth: sessionHealth)
  }

  @Test("a recording at every cap at once still fits what storage accepts, and reads back whole")
  func fullRecordingFits() throws {
    let log = try Self.fullLog()
    #expect(log.shapeProblem == nil)
    let usage = CallEvidenceUsage(log.segments)
    #expect(usage.names.count == Self.limits.names)
    #expect(usage.runs == Self.limits.runs)
    #expect(usage.samples == Self.limits.samples)
    #expect(usage.speakingReferences == Self.limits.speakingReferences)
    #expect(usage.rosterReferences == Self.limits.rosterReferences)
    #expect(usage.presenceEntries == Self.limits.presenceEntries)
    #expect(usage.sightings == Self.limits.sightings)
    #expect(usage.absences == Self.limits.absences)
    #expect(usage.pairs == Self.limits.pairs)

    let data = try MeetingStore.encoder.encode(log)
    #expect(data.count <= Self.wholeCeiling)
    #expect(data.count <= MeetingStore.maximumCallSpeakersBytes)
    #expect(Self.wholeCeiling <= MeetingStore.maximumCallSpeakersBytes)

    let root = TestTemporaryDirectory.url.appendingPathComponent(
      "CallSpeakerLogSizeTests-\(UUID().uuidString)", isDirectory: true)
    let store = MeetingStore(root: root)
    let record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    try store.create(record)
    try store.saveCallSpeakers(log, meeting: record.id)
    #expect(store.loadCallSpeakers(meeting: record.id) == .usable(log))
  }

  @Test("the name table and the segment frames stay inside their ceilings")
  func componentCeilings() throws {
    let table = try MeetingStore.encoder.encode(Self.names)
    #expect(table.count <= Self.namesCeiling)
    let health = try Self.health()
    let empty = (0..<CallSpeakerLog.maximumSegments).map { index in
      CallSpeakerSegment(
        startMs: index, endMs: index, endReason: .capacityReached, surface: .teamsApp,
        source: .app, status: .noPermission, lag: CallSpeakerLag(milliseconds: -60_000),
        roster: .empty, rosterFromParticipantList: true, observations: [], presence: [],
        health: health)
    }
    let frames = try MeetingStore.encoder.encode(CallSpeakerLog(rules: nil, segments: empty))
    #expect(frames.count <= Self.segmentFramesCeiling)
  }

  @Test("one run, one presence entry and one sighting with its absence stay inside their ceilings")
  func frameCeilings() throws {
    let name = Self.names[0]
    let far = CallSpeakerObservation.maximumObservationMs
    func size(_ observations: [CallSpeakerObservation], _ presence: [CallNamePresence]) throws
      -> Int
    {
      try MeetingStore.encoder.encode(
        CallSpeakerLog(
          rules: nil,
          segments: [
            CallSpeakerSegment(
              startMs: 0, endMs: nil, endReason: nil, surface: .teamsApp, source: .app,
              status: .observed, lag: nil, roster: CallSpeakerRoster(names: [name], selfNames: []),
              rosterFromParticipantList: true, observations: observations, presence: presence)
          ])
      ).count
    }
    let none = try size([], [])
    // A run of one sample naming one talker: frame 128, one offset 10, one reference 5.
    let run = try size([CallSpeakerObservation(observationMs: far, speaking: [name])], []) - none
    #expect(run <= 128 + 10 + 5)
    let empty = CallNamePresence(name: name, sightings: [], absences: [], sightingsFull: true)
    let entry = try size([], [empty]) - none
    #expect(entry <= 128)
    let pair =
      try size(
        [],
        [
          CallNamePresence(
            name: name,
            sightings: [.init(firstSeenMs: far - 3, lastSeenMs: far - 2, absenceConfirmed: true)],
            absences: [.init(firstMissingMs: far - 1, confirmedAtMs: far)], sightingsFull: true)
        ]) - none - entry
    #expect(pair <= 160)
  }

  @Test("one two-person stretch with five references and the largest times stays inside its ceiling")
  func pairFrameCeiling() throws {
    let far = CallSpeakerObservation.maximumObservationMs
    func size(_ pairs: [CallPairStretch]) throws -> Int {
      try MeetingStore.encoder.encode(
        CallSpeakerLog(
          rules: nil,
          segments: [
            CallSpeakerSegment(
              startMs: 0, endMs: nil, endReason: nil, surface: .zoomApp, source: .app,
              status: .observed, lag: nil,
              roster: CallSpeakerRoster(names: Self.names, selfNames: []),
              rosterFromParticipantList: true, observations: [], pairs: pairs)
          ])
      ).count
    }
    // The roster puts every name in the table first, so these ids have three digits.
    let stretch = CallPairStretch(
      names: [Self.names[508], Self.names[509]], selfNames: [Self.names[510], Self.names[511]],
      accountNames: [Self.names[507]], firstMs: far - 1, lastMs: far)
    let one = try size([stretch]) - size([])
    #expect(one <= Self.pairCeiling)
  }

  @Test("a segment frame with the most metadata format 3 accepts stays inside its ceiling")
  func largestAcceptedFrame() throws {
    let label = String(repeating: "W", count: CallSpeakerLog.maximumLabelBytes)
    var health = CallCaptureHealth()
    for n in 0..<CallSpeakerLog.maximumHealthKeys {
      health.withheldByReason[String(format: "%02d", n) + label.dropFirst(2)] = 1
    }
    health = try Self.maxed(health)
    let healthJSON = String(decoding: try JSONEncoder().encode(health), as: UTF8.self)
    let json =
      #"{"startMs":172799999,"endMs":172800000,"endReason":""# + label + #"","surface":""#
      + label + #"","source":""# + label + #"","status":""# + label
      + #"","lag":{"milliseconds":-60000},"roster":{"names":[],"selfNames":[]},"#
      + #""rosterFromParticipantList":true,"observations":[],"presence":[],"health":"#
      + healthJSON + "}"
    let segment = try JSONDecoder().decode(CallSpeakerSegment.self, from: Data(json.utf8))
    var sessionHealth = try Self.maxed(CallSessionHealth())
    sessionHealth.capacityReason = label
    let empty = CallSpeakerLog(rules: nil, segments: [], sessionHealth: sessionHealth)
    let one = CallSpeakerLog(rules: nil, segments: [segment], sessionHealth: sessionHealth)
    #expect(one.shapeProblem == nil, "every value here is accepted")
    let frame =
      try MeetingStore.encoder.encode(one).count - MeetingStore.encoder.encode(empty).count
    #expect(frame <= 4_096)
    #expect(try MeetingStore.encoder.encode(empty).count <= 8_192, "root and session health")
  }
}
