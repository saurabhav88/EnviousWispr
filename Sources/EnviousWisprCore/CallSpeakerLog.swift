import Foundation

/// The call surface a speaker reader watched (#4013). Stored as text in `CallSpeakerLog`, like
/// `MeetingRecord.callAppRaw`, so a surface added by a newer build never stops an older one from
/// reading the log.
public enum CallSpeakerSurface: String, Sendable, Equatable, CaseIterable {
  /// Readers with a talking signal (#4013 D2).
  case zoomApp = "zoom_app"
  case teamsApp = "teams_app"
  case zoomWeb = "zoom_web"
  case teamsWeb = "teams_web"
  case meet
  case slackApp = "slack_app"
  case slackWeb = "slack_web"
  /// Roster-only readers: participant names for the rename pick list, never a talking signal
  /// (#4013 D4, plan r2 item 9).
  case facetime
  case webex
  case dialpad
  case gather
  case lark
  case voov
  case whereby
  case jitsi
}

/// Where a reader's talking signal came from: the app's own words ("is speaking") or the
/// downloaded selector rules (#4013 D3). A roster-only reader records `.roster`.
public enum CallSpeakerSource: String, Sendable, Equatable, CaseIterable {
  case app
  case rules
  case roster
}

/// How observation went for a whole recording, saved even when no talker sample was collected,
/// so a later pass can tell "nothing was said" from "nothing could be read" (#4013 r2 item 3).
public enum CallSpeakerObservationStatus: String, Sendable, Equatable, CaseIterable {
  case observed
  case noPermission = "no_permission"
  case unreadable
  case unsupported
}

/// Signed delay between a call app's talking indicator and the far side's voice on the call-sound
/// track: indicator time minus voice onset (#4013 r1 R1). The value a recording saved: the
/// correction configured for its surface when it started (#4013 r5 item 3), never filled in later
/// for a log saved without one.
public struct CallSpeakerLag: Sendable, Equatable, Codable {
  /// A saved lag beyond a minute is not a real correction; the bound also keeps `audioAlignedMs`
  /// free of overflow for every admitted observation.
  public static let maximumMagnitudeMs = 60_000

  public let milliseconds: Int

  public init(milliseconds: Int) {
    self.milliseconds = milliseconds
  }

  /// The meeting-timeline time of the voice an observation at `observationMs` points to
  /// (#4013 r2 item 2: audio-aligned time is observation time minus lag).
  public func audioAlignedMs(_ observationMs: Int) -> Int {
    observationMs - milliseconds
  }
}

/// One read of the call app: who it showed as talking at `observationMs` on the meeting's
/// recording clock (milliseconds after the recorder's host-time anchor, #4013 r2 item 2).
/// Names keep the app's order and duplicates; deciding what is ambiguous is the namer's job.
public struct CallSpeakerObservation: Sendable, Equatable, Codable {
  /// Two days of recording clock: far past any meeting, and far from integer overflow.
  public static let maximumObservationMs = 48 * 60 * 60 * 1000

  public let observationMs: Int
  public let speaking: [String]

  public init(observationMs: Int, speaking: [String]) {
    self.observationMs = observationMs
    self.speaking = speaking
  }
}

/// The call's participants as the reader saw them. `names` keeps duplicates so two people with
/// one display name stay visible as ambiguous (#4013 r1 R1). `selfNames` holds only names the app
/// itself marked as the user ("(me)", "Myself video"); a role such as "Organizer" never counts.
public struct CallSpeakerRoster: Sendable, Equatable, Codable {
  public let names: [String]
  public let selfNames: [String]

  public init(names: [String], selfNames: [String]) {
    self.names = names
    self.selfNames = selfNames
  }

  public static let empty = CallSpeakerRoster(names: [], selfNames: [])
}

/// The selector rules in force when the recording started, frozen so Transcribe again uses the
/// same rules (#4013 r1 R7). The payload is the rules document as text; its schema belongs to
/// the rules store.
public struct FrozenTalkerRules: Sendable, Equatable, Codable {
  /// The rules document's size cap (#4013 R7). The rules store refuses a larger document, so a
  /// larger frozen payload was never valid rules.
  public static let maximumPayloadBytes = 32 * 1024

  public let version: Int
  public let payload: String

  public init(version: Int, payload: String) {
    self.version = version
    self.payload = payload
  }
}

/// A stretch of consecutive readings that each proved a two-person call (#4013 chunk 14): the
/// app's own count said two, both people were named and nobody else was shown. Evidence only;
/// the namer decides who is the user and who is the other person. Times are the first and last
/// such reading on the recording clock; a known interruption or any other reading ends it.
public struct CallPairStretch: Sendable, Equatable, Codable {
  /// The longest gap between two readings of one stretch: Granola 7.668.3 restarts its one-on-one
  /// candidate after more than 7,000 ms unseen (`zN`).
  public static let maximumGapMs = 7_000

  /// The two people shown, in the reader's order.
  public let names: [String]
  /// Names the app itself marked as the user in these readings (at most two, normally one).
  public let selfNames: [String]
  /// The display name of the account signed in to the call app during these readings, at most
  /// one (Zoom's menu bar). Not a meeting marking: the namer uses it only to tell the user from
  /// the other person when no app marking says, under the founder's recorded D5 exception
  /// (#4013 plan r4); votes and rename suggestions never use it. Empty when not read.
  public let accountNames: [String]
  public let firstMs: Int
  public let lastMs: Int

  public init(
    names: [String], selfNames: [String], accountNames: [String] = [], firstMs: Int, lastMs: Int
  ) {
    self.names = names
    self.selfNames = selfNames
    self.accountNames = accountNames
    self.firstMs = firstMs
    self.lastMs = lastMs
  }

  private enum CodingKeys: String, CodingKey {
    case names, selfNames, accountNames, firstMs, lastMs
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    names = try container.decode([String].self, forKey: .names)
    selfNames = try container.decode([String].self, forKey: .selfNames)
    accountNames = try container.decodeIfPresent([String].self, forKey: .accountNames) ?? []
    firstMs = try container.decode(Int.self, forKey: .firstMs)
    lastMs = try container.decode(Int.self, forKey: .lastMs)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(names, forKey: .names)
    try container.encode(selfNames, forKey: .selfNames)
    if !accountNames.isEmpty { try container.encode(accountNames, forKey: .accountNames) }
    try container.encode(firstMs, forKey: .firstMs)
    try container.encode(lastMs, forKey: .lastMs)
  }

  /// The most names one stretch holds: two people, two self names, one account name.
  static let maximumNames = 5

  /// The first shape problem, or `nil`: two distinct names, at most two self names and one
  /// account name, all valid, and a stretch that does not run backwards.
  var shapeProblem: String? {
    guard names.count == 2, names[0] != names[1] else { return "names" }
    guard selfNames.count <= 2 else { return "selfNames" }
    guard accountNames.count <= 1 else { return "accountNames" }
    guard (names + selfNames + accountNames).allSatisfy(CallSpeakerLog.isStoredName) else {
      return "name"
    }
    guard lastMs >= firstMs else { return "times" }
    return nil
  }
}

/// Why a segment's collection ended. Stored as text, like the surface.
public enum CallSpeakerSegmentEnd: String, Sendable, Equatable, CaseIterable {
  /// The call moved to another app, page or app instance.
  case sourceChanged = "source_changed"
  /// No single call could be read any more (it ended, or two calls competed).
  case sourceLost = "source_lost"
  /// The recording stopped, was quit or failed.
  case recordingEnded = "recording_ended"
  /// The recording's evidence reached a cap (`CallEvidenceLimits`); nothing more was read.
  case capacityReached = "capacity_reached"
  /// A format-1 log: the whole recording as one segment, with no known boundaries.
  case legacy
}

/// One stretch of a recording read from one call source (#4013 13B): one surface, its source,
/// status and lag, and what it saw. Times are milliseconds on the recording's clock (the
/// recorder's host-time anchor). A recording that changed calls, or lost and found its call
/// again, has several, in time order, never overlapping; a gap between two is time nothing was
/// read.
public struct CallSpeakerSegment: Sendable, Equatable {
  public let startMs: Int
  /// `nil` for a segment still collecting, or a format-1 log's only segment.
  public let endMs: Int?
  public let endReasonRaw: String?
  public let surfaceRaw: String?
  public let sourceRaw: String?
  public let statusRaw: String?
  public let lag: CallSpeakerLag?
  public let roster: CallSpeakerRoster
  /// Whether `roster` came from the call app's participant list (true), only from tiles, where
  /// one person can appear twice and two can share a name (false), or is not known (`nil`, a log
  /// written before this was recorded). Neither false nor `nil` confirms the names are unique.
  public let rosterFromParticipantList: Bool?
  public let observations: [CallSpeakerObservation]
  /// When each name was seen (#4013 13B); `nil` when not recorded (a format-1 log).
  public let presence: [CallNamePresence]?
  /// How this segment's captures went; `nil` when not recorded (unknown, never zero).
  public let health: CallCaptureHealth?
  /// Stretches that proved a two-person call (#4013 chunk 14), in time order; `nil` when not
  /// recorded (a log written before them), which is unknown, never "no such stretch".
  public let pairs: [CallPairStretch]?

  /// More names than any call shows; bounds the work of reading a damaged file.
  public static let maximumPresenceNames = 1_000

  public var surface: CallSpeakerSurface? { surfaceRaw.flatMap(CallSpeakerSurface.init(rawValue:)) }
  public var source: CallSpeakerSource? { sourceRaw.flatMap(CallSpeakerSource.init(rawValue:)) }
  public var status: CallSpeakerObservationStatus? {
    statusRaw.flatMap(CallSpeakerObservationStatus.init(rawValue:))
  }
  public var endReason: CallSpeakerSegmentEnd? {
    endReasonRaw.flatMap(CallSpeakerSegmentEnd.init(rawValue:))
  }

  public init(
    startMs: Int, endMs: Int?, endReason: CallSpeakerSegmentEnd?, surface: CallSpeakerSurface?,
    source: CallSpeakerSource?, status: CallSpeakerObservationStatus?, lag: CallSpeakerLag?,
    roster: CallSpeakerRoster, rosterFromParticipantList: Bool?,
    observations: [CallSpeakerObservation], presence: [CallNamePresence]? = nil,
    health: CallCaptureHealth? = nil, pairs: [CallPairStretch]? = nil
  ) {
    self.startMs = startMs
    self.endMs = endMs
    self.endReasonRaw = endReason?.rawValue
    self.surfaceRaw = surface?.rawValue
    self.sourceRaw = source?.rawValue
    self.statusRaw = status?.rawValue
    self.lag = lag
    self.roster = roster
    self.rosterFromParticipantList = rosterFromParticipantList
    self.observations = observations
    self.presence = presence
    self.health = health
    self.pairs = pairs
  }

  /// The first shape problem, or `nil` when the segment may be admitted as evidence.
  public var shapeProblem: String? {
    let clock = 0...CallSpeakerObservation.maximumObservationMs
    guard clock.contains(startMs) else { return "startMs" }
    if let endMs, !(clock.contains(endMs) && endMs >= startMs) { return "endMs" }
    if let lag,
      !(-CallSpeakerLag.maximumMagnitudeMs...CallSpeakerLag.maximumMagnitudeMs).contains(
        lag.milliseconds)
    {
      return "lag"
    }
    if !(roster.names + roster.selfNames).allSatisfy(CallSpeakerLog.isStoredName) {
      return "roster"
    }
    var previous = startMs
    // Consecutive samples usually name the same talkers; their names are checked once.
    var checked: CallSpeakerObservation?
    for (index, observation) in observations.enumerated() {
      guard clock.contains(observation.observationMs) else {
        return "observations[\(index)].observationMs"
      }
      guard observation.observationMs >= previous else {
        return "observations[\(index)] out of order or before the segment"
      }
      if let endMs, observation.observationMs > endMs {
        return "observations[\(index)] after the segment"
      }
      if !CallSpeakerRun.sameTalkers(checked, observation) {
        guard observation.speaking.allSatisfy(CallSpeakerLog.isStoredName) else {
          return "observations[\(index)].speaking"
        }
        checked = observation
      }
      previous = observation.observationMs
    }
    if let presence {
      guard presence.count <= Self.maximumPresenceNames else { return "presence" }
      guard Set(presence.map(\.name)).count == presence.count else {
        return "presence names repeat"
      }
      for (index, entry) in presence.enumerated() {
        guard CallSpeakerLog.isStoredName(entry.name) else { return "presence[\(index)].name" }
        if let problem = entry.shapeProblem { return "presence[\(index)] \(problem)" }
        // Every time stays inside the segment.
        let times =
          entry.sightings.flatMap { [$0.firstSeenMs, $0.lastSeenMs] }
          + entry.absences.flatMap { [$0.firstMissingMs, $0.confirmedAtMs] }
        guard times.allSatisfy({ $0 >= startMs && $0 <= (endMs ?? clock.upperBound) }) else {
          return "presence[\(index)] outside the segment"
        }
      }
    }
    if let pairs {
      // In time order without overlap, each inside the segment.
      var previousEnd: Int?
      for (index, pair) in pairs.enumerated() {
        if let problem = pair.shapeProblem { return "pairs[\(index)].\(problem)" }
        guard pair.firstMs >= startMs, pair.lastMs <= (endMs ?? clock.upperBound) else {
          return "pairs[\(index)] outside the segment"
        }
        if let previousEnd, pair.firstMs <= previousEnd {
          return "pairs[\(index)] out of order"
        }
        previousEnd = pair.lastMs
      }
    }
    return nil
  }
}

extension CallSpeakerSegment: Codable {
  private enum CodingKeys: String, CodingKey {
    case startMs, endMs, endReason, surface, source, status, lag, roster
    case rosterFromParticipantList, observations, presence, health, pairs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    startMs = try container.decode(Int.self, forKey: .startMs)
    endMs = try container.decodeIfPresent(Int.self, forKey: .endMs)
    endReasonRaw = try container.decodeIfPresent(String.self, forKey: .endReason)
    surfaceRaw = try container.decodeIfPresent(String.self, forKey: .surface)
    sourceRaw = try container.decodeIfPresent(String.self, forKey: .source)
    statusRaw = try container.decodeIfPresent(String.self, forKey: .status)
    lag = try container.decodeIfPresent(CallSpeakerLag.self, forKey: .lag)
    roster = try container.decodeIfPresent(CallSpeakerRoster.self, forKey: .roster) ?? .empty
    rosterFromParticipantList = try container.decodeIfPresent(
      Bool.self, forKey: .rosterFromParticipantList)
    observations =
      try container.decodeIfPresent([CallSpeakerObservation].self, forKey: .observations) ?? []
    presence = try container.decodeIfPresent([CallNamePresence].self, forKey: .presence)
    health = try container.decodeIfPresent(CallCaptureHealth.self, forKey: .health)
    pairs = try container.decodeIfPresent([CallPairStretch].self, forKey: .pairs)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(startMs, forKey: .startMs)
    try container.encodeIfPresent(endMs, forKey: .endMs)
    try container.encodeIfPresent(endReasonRaw, forKey: .endReason)
    try container.encodeIfPresent(surfaceRaw, forKey: .surface)
    try container.encodeIfPresent(sourceRaw, forKey: .source)
    try container.encodeIfPresent(statusRaw, forKey: .status)
    try container.encodeIfPresent(lag, forKey: .lag)
    try container.encode(roster, forKey: .roster)
    try container.encodeIfPresent(rosterFromParticipantList, forKey: .rosterFromParticipantList)
    try container.encode(observations, forKey: .observations)
    try container.encodeIfPresent(presence, forKey: .presence)
    try container.encodeIfPresent(health, forKey: .health)
    try container.encodeIfPresent(pairs, forKey: .pairs)
  }
}

/// Everything a recording's speaker readers saved, written beside the meeting as
/// `call-speakers.json` and kept on this Mac only (#4013 §3, r2 item 3).
///
/// Format 2 (#4013 13B): the talker rules frozen once for the whole recording, and one segment
/// per stretch read from one call source. A format-1 log (one surface for the whole recording)
/// reads as one `legacy` segment from 0 with no end.
///
/// Format 3 (#4013 13B.5), written now: the same content, stored compactly. Every name is kept
/// once in a recording-wide table that rosters, presence and talkers point into, and samples
/// are stored as runs of the same talkers (`CallSpeakerRun`), each sample at its exact time. It
/// reads back as exactly the samples it was written from. A format-3 log also stays within
/// `CallEvidenceLimits.current`; formats 1 and 2 are read as they were written. Surface, source, status and end reason are
/// stored as text: an unknown value from a newer build reads as unknown (`nil`), never as a
/// guess and never as a decode failure. A `formatVersion` newer than this build understands
/// fails to decode, so the caller keeps the composer's fallback labels.
///
/// Decoding also checks the log's shape (each segment's bounds, lag, names and observations in
/// time order inside it; segments in order without overlap; a bounded frozen payload) and
/// refuses the whole log when any part is wrong. It does not judge the frozen rules' content:
/// that belongs to the rules store's decoder, which a later pass applies when it thaws them.
public struct CallSpeakerLog: Sendable, Equatable {
  public static let currentFormatVersion = 3
  /// Far more call changes than any recording has; bounds the work of reading a damaged file.
  public static let maximumSegments = 1_000

  public let formatVersion: Int
  public let rules: FrozenTalkerRules?
  /// The presence rule frozen at recording start; `nil` when presence was not recorded.
  public let presencePolicy: CallPresencePolicy?
  public let segments: [CallSpeakerSegment]
  /// How the search for the call went; `nil` when not recorded.
  public let sessionHealth: CallSessionHealth?

  public init(
    rules: FrozenTalkerRules?, presencePolicy: CallPresencePolicy? = nil,
    segments: [CallSpeakerSegment], sessionHealth: CallSessionHealth? = nil
  ) {
    self.formatVersion = Self.currentFormatVersion
    self.rules = rules
    self.presencePolicy = presencePolicy
    self.segments = segments
    self.sessionHealth = sessionHealth
  }

  /// The one surface every segment shares, or `nil` with none or more than one (a mixed
  /// recording is never reported as its last surface).
  public var singleSurface: CallSpeakerSurface? {
    let surfaces = Set(segments.map(\.surfaceRaw))
    guard surfaces.count == 1, let only = surfaces.first else { return nil }
    return only.flatMap(CallSpeakerSurface.init(rawValue:))
  }

  /// Every segment's participants as one list: each name as often as the segment that showed
  /// it most (a person seen in two calls is one person; two people sharing a name stay two),
  /// in first-seen order; self names from every segment.
  public var combinedRoster: CallSpeakerRoster {
    var counts: [String: Int] = [:]
    var order: [String] = []
    var selfNames: [String] = []
    for segment in segments {
      var here: [String: Int] = [:]
      for name in segment.roster.names { here[name, default: 0] += 1 }
      for name in segment.roster.names where counts[name] == nil {
        order.append(name)
        counts[name] = 0
      }
      for (name, count) in here { counts[name] = max(counts[name] ?? 0, count) }
      for name in segment.roster.selfNames where !selfNames.contains(name) {
        selfNames.append(name)
      }
    }
    return CallSpeakerRoster(
      names: order.flatMap { Array(repeating: $0, count: counts[$0] ?? 0) }, selfNames: selfNames)
  }

  /// The first shape problem, or `nil` when the log may be admitted as evidence: the rules every
  /// format shares, plus the current format's limits for a log in it (formats 1 and 2 are read
  /// as they were written).
  public var shapeProblem: String? {
    sharedShapeProblem ?? (formatVersion >= 3 ? currentFormatOnlyProblem : nil)
  }

  /// Why this log cannot be written in the current format, or `nil`. A log read from an older
  /// format may hold more than the current format allows; it is then kept as it is, never
  /// rewritten (`MeetingStore.saveCallSpeakers` refuses it before writing).
  public var currentFormatProblem: String? {
    sharedShapeProblem ?? currentFormatOnlyProblem
  }

  /// The longest text a log keeps for a surface, source, status, end reason, health key or
  /// capacity reason (every value this build writes is far shorter), and the most health keys.
  public static let maximumLabelBytes = 64

  /// A label as this build writes one: ASCII letters, digits and underscores, so it never
  /// grows when written, at most `maximumLabelBytes`.
  public static func isLabel(_ text: String) -> Bool {
    text.utf8.count <= maximumLabelBytes
      && text.utf8.allSatisfy { byte in
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
          || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
          || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "_")
      }
  }
  public static let maximumHealthKeys = 16

  private var currentFormatOnlyProblem: String? {
    let usage = CallEvidenceUsage(segments)
    if let capacity = usage.exceeded(.current) { return "capacity.\(capacity.rawValue)" }
    // Each distinct spelling once.
    guard usage.names.allSatisfy({ Self.isName(String(decoding: $0, as: UTF8.self)) }) else {
      return "names"
    }
    func isLabel(_ text: String?) -> Bool { text.map(Self.isLabel) ?? true }
    guard isLabel(sessionHealth?.capacityReason) else { return "sessionHealth.capacityReason" }
    for (index, segment) in segments.enumerated() {
      guard
        [segment.surfaceRaw, segment.sourceRaw, segment.statusRaw, segment.endReasonRaw]
          .allSatisfy(isLabel)
      else { return "segments[\(index)].labels" }
      if let reasons = segment.health?.withheldByReason {
        guard reasons.count <= Self.maximumHealthKeys, reasons.keys.allSatisfy(isLabel) else {
          return "segments[\(index)].health"
        }
      }
    }
    return nil
  }

  private var sharedShapeProblem: String? {
    if let rules {
      if rules.version < 1 { return "rules.version" }
      if rules.payload.isEmpty || rules.payload.utf8.count > FrozenTalkerRules.maximumPayloadBytes {
        return "rules.payload"
      }
    }
    guard segments.count <= Self.maximumSegments else { return "segments" }
    var previousEnd: Int?
    for (index, segment) in segments.enumerated() {
      if let problem = segment.shapeProblem { return "segments[\(index)].\(problem)" }
      if index > 0 {
        // Only the last segment may be open; the next starts at or after its end.
        guard let end = previousEnd, segment.startMs >= end else {
          return "segments[\(index)] overlaps the one before"
        }
      }
      previousEnd = segment.endMs
    }
    return nil
  }

  /// A display name as a call app shows one: not empty, not a paragraph. Bounded in characters
  /// and in bytes, since one character can hold many combining marks.
  public static let maximumNameLength = 256
  public static let maximumNameBytes = 1_024

  public static func isName(_ name: String) -> Bool {
    isStoredName(name) && name.utf8.count <= maximumNameBytes
  }

  /// A name as formats 1 and 2 allowed one: bounded in characters only.
  static func isStoredName(_ name: String) -> Bool {
    !name.isEmpty && name.count <= maximumNameLength
  }
}

extension CallSpeakerLog: Codable {
  public enum DecodeError: Error, Equatable {
    case unsupportedFormatVersion(Int)
    /// The log decoded but its shape is wrong (`shapeProblem`); none of it is admitted.
    case invalid(String)
  }

  private enum CodingKeys: String, CodingKey {
    case formatVersion, rules, presencePolicy, segments, sessionHealth, names
    // Format 1's single-surface fields.
    case surface, source, status, lag, roster, rosterFromParticipantList, observations
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .formatVersion)
    guard version <= Self.currentFormatVersion else {
      throw DecodeError.unsupportedFormatVersion(version)
    }
    // Only versions this build wrote are admitted; there was never a version below 1.
    guard version >= 1 else { throw DecodeError.invalid("formatVersion") }
    formatVersion = version
    rules = try container.decodeIfPresent(FrozenTalkerRules.self, forKey: .rules)
    presencePolicy = try container.decodeIfPresent(
      CallPresencePolicy.self, forKey: .presencePolicy)
    sessionHealth = try container.decodeIfPresent(CallSessionHealth.self, forKey: .sessionHealth)
    if version == 1 {
      segments = [
        CallSpeakerSegment(
          startMs: 0, endMs: nil, endReason: .legacy,
          surface: nil, source: nil, status: nil, lag: nil, roster: .empty,
          rosterFromParticipantList: nil, observations: []
        ).legacy(
          surfaceRaw: try container.decodeIfPresent(String.self, forKey: .surface),
          sourceRaw: try container.decodeIfPresent(String.self, forKey: .source),
          statusRaw: try container.decodeIfPresent(String.self, forKey: .status),
          lag: try container.decodeIfPresent(CallSpeakerLag.self, forKey: .lag),
          roster: try container.decodeIfPresent(CallSpeakerRoster.self, forKey: .roster) ?? .empty,
          rosterFromParticipantList: try container.decodeIfPresent(
            Bool.self, forKey: .rosterFromParticipantList),
          observations: try container.decodeIfPresent(
            [CallSpeakerObservation].self, forKey: .observations) ?? [])
      ]
    } else if version == 2 {
      // Required: a missing or null list is damage, never a recording that read no call.
      segments = try container.decode([CallSpeakerSegment].self, forKey: .segments)
    } else {
      let names = try container.decode([String].self, forKey: .names)
      guard names.allSatisfy(Self.isName),
        Set(names.map { Array($0.utf8) }).count == names.count
      else { throw DecodeError.invalid("names") }
      let wire = try container.decode([CallSpeakerWireSegment].self, forKey: .segments)
      // Counted before any sample is made, so a small file cannot unfold into millions.
      if let capacity = CallSpeakerWireSegment.exceeded(wire, names: names.count, .current) {
        throw DecodeError.invalid("capacity.\(capacity.rawValue)")
      }
      segments = try wire.map { try $0.segment(names: names) }
    }
    if let problem = shapeProblem { throw DecodeError.invalid(problem) }
  }

  /// Always written as the current format; a log the current format cannot hold
  /// (`currentFormatProblem`) is refused, never written.
  public func encode(to encoder: Encoder) throws {
    if let problem = currentFormatProblem {
      throw EncodingError.invalidValue(
        self, .init(codingPath: encoder.codingPath, debugDescription: problem))
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
    try container.encodeIfPresent(rules, forKey: .rules)
    try container.encodeIfPresent(presencePolicy, forKey: .presencePolicy)
    var table = CallSpeakerNameTable()
    let wire = segments.map { CallSpeakerWireSegment($0, table: &table) }
    try container.encode(table.names, forKey: .names)
    try container.encode(wire, forKey: .segments)
    try container.encodeIfPresent(sessionHealth, forKey: .sessionHealth)
  }
}

/// Format 3's name table: each spelling once, by its bytes (two spellings Swift calls equal stay
/// two), in first-written order.
private struct CallSpeakerNameTable {
  private(set) var names: [String] = []
  private var ids: [[UInt8]: Int] = [:]

  mutating func id(_ name: String) -> Int {
    let key = Array(name.utf8)
    if let id = ids[key] { return id }
    ids[key] = names.count
    names.append(name)
    return names.count - 1
  }
}

/// Format 3's segment: names as table positions, samples as runs.
private struct CallSpeakerWireSegment: Codable {
  struct Roster: Codable {
    let names: [Int]
    let selfNames: [Int]
  }

  /// `offsets` are each sample's milliseconds after `startMs`; the first is 0.
  struct Run: Codable {
    let startMs: Int
    let speaking: [Int]
    let offsets: [Int]
  }

  struct Presence: Codable {
    let name: Int
    let sightings: [CallNamePresence.Sighting]
    let absences: [CallNamePresence.Absence]
    let sightingsFull: Bool?
  }

  struct Pair: Codable {
    let names: [Int]
    let selfNames: [Int]
    /// Absent when no account name was read.
    let accountNames: [Int]?
    let firstMs: Int
    let lastMs: Int
  }

  let startMs: Int
  let endMs: Int?
  let endReason: String?
  let surface: String?
  let source: String?
  let status: String?
  let lag: CallSpeakerLag?
  let roster: Roster
  let rosterFromParticipantList: Bool?
  let runs: [Run]
  let presence: [Presence]?
  let health: CallCaptureHealth?
  let pairs: [Pair]?

  init(_ segment: CallSpeakerSegment, table: inout CallSpeakerNameTable) {
    startMs = segment.startMs
    endMs = segment.endMs
    endReason = segment.endReasonRaw
    surface = segment.surfaceRaw
    source = segment.sourceRaw
    status = segment.statusRaw
    lag = segment.lag
    roster = Roster(
      names: segment.roster.names.map { table.id($0) },
      selfNames: segment.roster.selfNames.map { table.id($0) })
    rosterFromParticipantList = segment.rosterFromParticipantList
    var runs: [Run] = []
    var current: (start: CallSpeakerObservation, offsets: [Int])?
    var previous: CallSpeakerObservation?
    func close() {
      guard let run = current else { return }
      runs.append(
        Run(
          startMs: run.start.observationMs, speaking: run.start.speaking.map { table.id($0) },
          offsets: run.offsets))
    }
    for observation in segment.observations {
      if let start = current?.start, CallSpeakerRun.continues(previous, with: observation) {
        current?.offsets.append(observation.observationMs - start.observationMs)
      } else {
        close()
        current = (observation, [0])
      }
      previous = observation
    }
    close()
    self.runs = runs
    presence = segment.presence?.map {
      Presence(
        name: table.id($0.name), sightings: $0.sightings, absences: $0.absences,
        sightingsFull: $0.sightingsFull)
    }
    health = segment.health
    pairs = segment.pairs?.map {
      Pair(
        names: $0.names.map { table.id($0) }, selfNames: $0.selfNames.map { table.id($0) },
        accountNames: $0.accountNames.isEmpty ? nil : $0.accountNames.map { table.id($0) },
        firstMs: $0.firstMs, lastMs: $0.lastMs)
    }
  }

  /// The first cap the stored counts pass, before anything is unfolded.
  static func exceeded(
    _ segments: [CallSpeakerWireSegment], names: Int, _ limits: CallEvidenceLimits
  ) -> CallEvidenceCapacity? {
    if segments.count > CallSpeakerLog.maximumSegments { return .segments }
    if names > limits.names { return .names }
    var runs = 0
    var samples = 0
    var speaking = 0
    var roster = 0
    var presence = 0
    var sightings = 0
    var absences = 0
    var pairs = 0
    for segment in segments {
      // A stretch holds at most five names; more is damage, refused before anything unfolds.
      if (segment.pairs ?? []).contains(where: {
        $0.names.count + $0.selfNames.count + ($0.accountNames?.count ?? 0)
          > CallPairStretch.maximumNames
      }) {
        return .pairs
      }
      pairs += segment.pairs?.count ?? 0
      runs += segment.runs.count
      roster += segment.roster.names.count + segment.roster.selfNames.count
      for run in segment.runs {
        samples += run.offsets.count
        speaking += run.speaking.count
      }
      for entry in segment.presence ?? [] {
        presence += 1
        sightings += entry.sightings.count
        absences += entry.absences.count
      }
    }
    if runs > limits.runs { return .runs }
    if samples > limits.samples { return .samples }
    if speaking > limits.speakingReferences { return .speakingReferences }
    if roster > limits.rosterReferences { return .rosterReferences }
    if presence > limits.presenceEntries { return .presenceEntries }
    if sightings > limits.sightings { return .sightings }
    if absences > limits.absences { return .absences }
    if pairs > limits.pairs { return .pairs }
    return nil
  }

  /// The segment this was written from; a position outside the table, or a run that is empty,
  /// starts anywhere but 0 or goes back in time, refuses the log.
  func segment(names: [String]) throws -> CallSpeakerSegment {
    func name(_ id: Int) throws -> String {
      guard names.indices.contains(id) else { throw CallSpeakerLog.DecodeError.invalid("name id") }
      return names[id]
    }
    let clock = CallSpeakerObservation.maximumObservationMs
    var observations: [CallSpeakerObservation] = []
    for run in runs {
      guard run.offsets.first == 0,
        zip(run.offsets, run.offsets.dropFirst()).allSatisfy({ $0 <= $1 }),
        (0...clock).contains(run.startMs), let last = run.offsets.last, last <= clock - run.startMs
      else { throw CallSpeakerLog.DecodeError.invalid("runs") }
      let speaking = try run.speaking.map(name)
      for offset in run.offsets {
        observations.append(
          CallSpeakerObservation(observationMs: run.startMs + offset, speaking: speaking))
      }
    }
    return CallSpeakerSegment(
      startMs: startMs, endMs: endMs, endReasonRaw: endReason, surfaceRaw: surface,
      sourceRaw: source, statusRaw: status, lag: lag,
      roster: CallSpeakerRoster(
        names: try roster.names.map(name), selfNames: try roster.selfNames.map(name)),
      rosterFromParticipantList: rosterFromParticipantList, observations: observations,
      presence: try presence?.map {
        CallNamePresence(
          name: try name($0.name), sightings: $0.sightings, absences: $0.absences,
          sightingsFull: $0.sightingsFull)
      }, health: health,
      pairs: try pairs?.map {
        CallPairStretch(
          names: try $0.names.map(name), selfNames: try $0.selfNames.map(name),
          accountNames: try ($0.accountNames ?? []).map(name), firstMs: $0.firstMs,
          lastMs: $0.lastMs)
      })
  }
}

extension CallSpeakerSegment {
  /// A format-1 log's fields as its one segment, with its stored text kept as it was.
  fileprivate func legacy(
    surfaceRaw: String?, sourceRaw: String?, statusRaw: String?, lag: CallSpeakerLag?,
    roster: CallSpeakerRoster, rosterFromParticipantList: Bool?,
    observations: [CallSpeakerObservation]
  ) -> CallSpeakerSegment {
    CallSpeakerSegment(
      startMs: startMs, endMs: endMs, endReasonRaw: endReasonRaw, surfaceRaw: surfaceRaw,
      sourceRaw: sourceRaw, statusRaw: statusRaw, lag: lag, roster: roster,
      rosterFromParticipantList: rosterFromParticipantList, observations: observations)
  }

  fileprivate init(
    startMs: Int, endMs: Int?, endReasonRaw: String?, surfaceRaw: String?, sourceRaw: String?,
    statusRaw: String?, lag: CallSpeakerLag?, roster: CallSpeakerRoster,
    rosterFromParticipantList: Bool?, observations: [CallSpeakerObservation],
    presence: [CallNamePresence]? = nil, health: CallCaptureHealth? = nil,
    pairs: [CallPairStretch]? = nil
  ) {
    self.startMs = startMs
    self.endMs = endMs
    self.endReasonRaw = endReasonRaw
    self.surfaceRaw = surfaceRaw
    self.sourceRaw = sourceRaw
    self.statusRaw = statusRaw
    self.lag = lag
    self.roster = roster
    self.rosterFromParticipantList = rosterFromParticipantList
    self.observations = observations
    self.presence = presence
    self.health = health
    self.pairs = pairs
  }
}
