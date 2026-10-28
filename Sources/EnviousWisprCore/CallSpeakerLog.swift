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

/// Everything a recording's speaker readers saved, written beside the meeting as
/// `call-speakers.json` and kept on this Mac only (#4013 §3, r2 item 3).
///
/// Surface, source and status are stored as text: an unknown value from a newer build reads as
/// unknown (`nil`), never as a guess and never as a decode failure. A `formatVersion` newer than
/// this build understands fails to decode, so the caller keeps the composer's fallback labels.
///
/// Decoding also checks the log's shape (bounded times and lag, observations in time order,
/// non-empty names, a bounded frozen payload) and refuses the whole log when any part is wrong.
/// It does not judge the frozen rules' content: that belongs to the rules store's decoder, which
/// a later pass applies when it thaws them.
public struct CallSpeakerLog: Sendable, Equatable {
  public static let currentFormatVersion = 1

  public let formatVersion: Int
  public let surfaceRaw: String?
  public let sourceRaw: String?
  public let statusRaw: String?
  public let lag: CallSpeakerLag?
  public let rules: FrozenTalkerRules?
  public let roster: CallSpeakerRoster
  /// Whether `roster` came from the call app's participant list (true), only from tiles, where
  /// one person can appear twice and two can share a name (false), or is not known (`nil`, a log
  /// written before this was recorded). Neither false nor `nil` confirms the names are unique.
  public let rosterFromParticipantList: Bool?
  public let observations: [CallSpeakerObservation]

  public var surface: CallSpeakerSurface? { surfaceRaw.flatMap(CallSpeakerSurface.init(rawValue:)) }
  public var source: CallSpeakerSource? { sourceRaw.flatMap(CallSpeakerSource.init(rawValue:)) }
  public var status: CallSpeakerObservationStatus? {
    statusRaw.flatMap(CallSpeakerObservationStatus.init(rawValue:))
  }

  public init(
    surface: CallSpeakerSurface?, source: CallSpeakerSource?,
    status: CallSpeakerObservationStatus?, lag: CallSpeakerLag?, rules: FrozenTalkerRules?,
    roster: CallSpeakerRoster, rosterFromParticipantList: Bool?,
    observations: [CallSpeakerObservation]
  ) {
    self.formatVersion = Self.currentFormatVersion
    self.surfaceRaw = surface?.rawValue
    self.sourceRaw = source?.rawValue
    self.statusRaw = status?.rawValue
    self.lag = lag
    self.rules = rules
    self.roster = roster
    self.rosterFromParticipantList = rosterFromParticipantList
    self.observations = observations
  }

  /// The first shape problem, or `nil` when the log may be admitted as evidence.
  public var shapeProblem: String? {
    if let lag, !(-CallSpeakerLag.maximumMagnitudeMs...CallSpeakerLag.maximumMagnitudeMs).contains(
      lag.milliseconds)
    {
      return "lag"
    }
    if let rules {
      if rules.version < 1 { return "rules.version" }
      if rules.payload.isEmpty || rules.payload.utf8.count > FrozenTalkerRules.maximumPayloadBytes {
        return "rules.payload"
      }
    }
    if !(roster.names + roster.selfNames).allSatisfy(Self.isName) { return "roster" }
    var previous = 0
    for (index, observation) in observations.enumerated() {
      guard (0...CallSpeakerObservation.maximumObservationMs).contains(observation.observationMs)
      else { return "observations[\(index)].observationMs" }
      guard observation.observationMs >= previous else { return "observations[\(index)] out of order" }
      guard observation.speaking.allSatisfy(Self.isName) else {
        return "observations[\(index)].speaking"
      }
      previous = observation.observationMs
    }
    return nil
  }

  /// A display name as a call app shows one: not empty, not a paragraph.
  static let maximumNameLength = 256

  private static func isName(_ name: String) -> Bool {
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
    case formatVersion, surface, source, status, lag, rules, roster, rosterFromParticipantList
    case observations
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
    surfaceRaw = try container.decodeIfPresent(String.self, forKey: .surface)
    sourceRaw = try container.decodeIfPresent(String.self, forKey: .source)
    statusRaw = try container.decodeIfPresent(String.self, forKey: .status)
    lag = try container.decodeIfPresent(CallSpeakerLag.self, forKey: .lag)
    rules = try container.decodeIfPresent(FrozenTalkerRules.self, forKey: .rules)
    roster = try container.decodeIfPresent(CallSpeakerRoster.self, forKey: .roster) ?? .empty
    rosterFromParticipantList = try container.decodeIfPresent(
      Bool.self, forKey: .rosterFromParticipantList)
    observations =
      try container.decodeIfPresent([CallSpeakerObservation].self, forKey: .observations) ?? []
    if let problem = shapeProblem { throw DecodeError.invalid(problem) }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(formatVersion, forKey: .formatVersion)
    try container.encodeIfPresent(surfaceRaw, forKey: .surface)
    try container.encodeIfPresent(sourceRaw, forKey: .source)
    try container.encodeIfPresent(statusRaw, forKey: .status)
    try container.encodeIfPresent(lag, forKey: .lag)
    try container.encodeIfPresent(rules, forKey: .rules)
    try container.encode(roster, forKey: .roster)
    try container.encodeIfPresent(rosterFromParticipantList, forKey: .rosterFromParticipantList)
    try container.encode(observations, forKey: .observations)
  }
}
