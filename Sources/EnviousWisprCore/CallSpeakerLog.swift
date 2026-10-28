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
/// track: indicator time minus voice onset (#4013 r1 R1). Measured per surface on the real-call
/// rig; never invented.
public struct CallSpeakerLag: Sendable, Equatable, Codable {
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
public struct CallSpeakerLog: Sendable, Equatable {
  public static let currentFormatVersion = 1

  public let formatVersion: Int
  public let surfaceRaw: String?
  public let sourceRaw: String?
  public let statusRaw: String?
  public let lag: CallSpeakerLag?
  public let rules: FrozenTalkerRules?
  public let roster: CallSpeakerRoster
  public let observations: [CallSpeakerObservation]

  public var surface: CallSpeakerSurface? { surfaceRaw.flatMap(CallSpeakerSurface.init(rawValue:)) }
  public var source: CallSpeakerSource? { sourceRaw.flatMap(CallSpeakerSource.init(rawValue:)) }
  public var status: CallSpeakerObservationStatus? {
    statusRaw.flatMap(CallSpeakerObservationStatus.init(rawValue:))
  }

  public init(
    surface: CallSpeakerSurface?, source: CallSpeakerSource?,
    status: CallSpeakerObservationStatus?, lag: CallSpeakerLag?, rules: FrozenTalkerRules?,
    roster: CallSpeakerRoster, observations: [CallSpeakerObservation]
  ) {
    self.formatVersion = Self.currentFormatVersion
    self.surfaceRaw = surface?.rawValue
    self.sourceRaw = source?.rawValue
    self.statusRaw = status?.rawValue
    self.lag = lag
    self.rules = rules
    self.roster = roster
    self.observations = observations
  }
}

extension CallSpeakerLog: Codable {
  public enum DecodeError: Error, Equatable {
    case unsupportedFormatVersion(Int)
  }

  private enum CodingKeys: String, CodingKey {
    case formatVersion, surface, source, status, lag, rules, roster, observations
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .formatVersion)
    guard version <= Self.currentFormatVersion else {
      throw DecodeError.unsupportedFormatVersion(version)
    }
    formatVersion = version
    surfaceRaw = try container.decodeIfPresent(String.self, forKey: .surface)
    sourceRaw = try container.decodeIfPresent(String.self, forKey: .source)
    statusRaw = try container.decodeIfPresent(String.self, forKey: .status)
    lag = try container.decodeIfPresent(CallSpeakerLag.self, forKey: .lag)
    rules = try container.decodeIfPresent(FrozenTalkerRules.self, forKey: .rules)
    roster = try container.decodeIfPresent(CallSpeakerRoster.self, forKey: .roster) ?? .empty
    observations =
      try container.decodeIfPresent([CallSpeakerObservation].self, forKey: .observations) ?? []
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
    try container.encode(observations, forKey: .observations)
  }
}
