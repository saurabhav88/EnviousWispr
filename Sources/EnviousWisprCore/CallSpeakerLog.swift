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

/// Why a segment's collection ended. Stored as text, like the surface.
public enum CallSpeakerSegmentEnd: String, Sendable, Equatable, CaseIterable {
  /// The call moved to another app, page or app instance.
  case sourceChanged = "source_changed"
  /// No single call could be read any more (it ended, or two calls competed).
  case sourceLost = "source_lost"
  /// The recording stopped, was quit or failed.
  case recordingEnded = "recording_ended"
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
    health: CallCaptureHealth? = nil
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
  }

  /// The first shape problem, or `nil` when the segment may be admitted as evidence.
  public var shapeProblem: String? {
    let clock = 0...CallSpeakerObservation.maximumObservationMs
    guard clock.contains(startMs) else { return "startMs" }
    if let endMs, !(clock.contains(endMs) && endMs >= startMs) { return "endMs" }
    if let lag, !(-CallSpeakerLag.maximumMagnitudeMs...CallSpeakerLag.maximumMagnitudeMs).contains(
      lag.milliseconds)
    {
      return "lag"
    }
    if !(roster.names + roster.selfNames).allSatisfy(CallSpeakerLog.isName) { return "roster" }
    var previous = startMs
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
      guard observation.speaking.allSatisfy(CallSpeakerLog.isName) else {
        return "observations[\(index)].speaking"
      }
      previous = observation.observationMs
    }
    if let presence {
      guard presence.count <= Self.maximumPresenceNames else { return "presence" }
      for (index, entry) in presence.enumerated() {
        guard CallSpeakerLog.isName(entry.name) else { return "presence[\(index)].name" }
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
    return nil
  }
}

extension CallSpeakerSegment: Codable {
  private enum CodingKeys: String, CodingKey {
    case startMs, endMs, endReason, surface, source, status, lag, roster
    case rosterFromParticipantList, observations, presence, health
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
  }
}

/// Everything a recording's speaker readers saved, written beside the meeting as
/// `call-speakers.json` and kept on this Mac only (#4013 §3, r2 item 3).
///
/// Format 2 (#4013 13B): the talker rules frozen once for the whole recording, and one segment
/// per stretch read from one call source. A format-1 log (one surface for the whole recording)
/// reads as one `legacy` segment from 0 with no end. Surface, source, status and end reason are
/// stored as text: an unknown value from a newer build reads as unknown (`nil`), never as a
/// guess and never as a decode failure. A `formatVersion` newer than this build understands
/// fails to decode, so the caller keeps the composer's fallback labels.
///
/// Decoding also checks the log's shape (each segment's bounds, lag, names and observations in
/// time order inside it; segments in order without overlap; a bounded frozen payload) and
/// refuses the whole log when any part is wrong. It does not judge the frozen rules' content:
/// that belongs to the rules store's decoder, which a later pass applies when it thaws them.
public struct CallSpeakerLog: Sendable, Equatable {
  public static let currentFormatVersion = 2
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
      for name in segment.roster.selfNames where !selfNames.contains(name) { selfNames.append(name) }
    }
    return CallSpeakerRoster(
      names: order.flatMap { Array(repeating: $0, count: counts[$0] ?? 0) }, selfNames: selfNames)
  }

  /// The first shape problem, or `nil` when the log may be admitted as evidence.
  public var shapeProblem: String? {
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

  /// A display name as a call app shows one: not empty, not a paragraph.
  static let maximumNameLength = 256

  static func isName(_ name: String) -> Bool {
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
    case formatVersion, rules, presencePolicy, segments, sessionHealth
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
    } else {
      // Required: a missing or null list is damage, never a recording that read no call.
      segments = try container.decode([CallSpeakerSegment].self, forKey: .segments)
    }
    if let problem = shapeProblem { throw DecodeError.invalid(problem) }
  }

  /// Always written as the current format.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
    try container.encodeIfPresent(rules, forKey: .rules)
    try container.encodeIfPresent(presencePolicy, forKey: .presencePolicy)
    try container.encode(segments, forKey: .segments)
    try container.encodeIfPresent(sessionHealth, forKey: .sessionHealth)
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

  private init(
    startMs: Int, endMs: Int?, endReasonRaw: String?, surfaceRaw: String?, sourceRaw: String?,
    statusRaw: String?, lag: CallSpeakerLag?, roster: CallSpeakerRoster,
    rosterFromParticipantList: Bool?, observations: [CallSpeakerObservation]
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
    self.presence = nil
    self.health = nil
  }
}
