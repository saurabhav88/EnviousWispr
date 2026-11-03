import Foundation

/// What automatic speaker naming achieved for one meeting attempt, as `meeting.ended` reports it
/// (#4013 r2 item 5, r3 F4). Shape only: never a name, speaker id, meeting id, roster, room key,
/// text or rules. Every fact is optional; an unknown fact stays absent and is never guessed.
public struct SpeakerNamingSummary: Equatable, Sendable {
  /// The call app the speaker evidence came from (`speaker_names_surface`).
  public enum Surface: String, Sendable, CaseIterable {
    case zoomApp = "zoom_app"
    case teamsApp = "teams_app"
    case zoomWeb = "zoom_web"
    case teamsWeb = "teams_web"
    case meet
    case slackApp = "slack_app"
    case slackWeb = "slack_web"
    /// A call app with no talking signal (roster only, or no reader).
    case unsupported
    /// Positively known: no call app was involved.
    case none

    /// The surface a saved log names; `nil` when the log names none.
    public init?(_ surface: CallSpeakerSurface?) {
      guard let surface else { return nil }
      switch surface {
      case .zoomApp: self = .zoomApp
      case .teamsApp: self = .teamsApp
      case .zoomWeb: self = .zoomWeb
      case .teamsWeb: self = .teamsWeb
      case .meet: self = .meet
      case .slackApp: self = .slackApp
      case .slackWeb: self = .slackWeb
      case .facetime, .webex, .dialpad, .gather, .lark, .voov, .whereby, .jitsi:
        self = .unsupported
      }
    }
  }

  /// How naming ended (`speaker_names_outcome`).
  public enum Outcome: String, Sendable, CaseIterable {
    /// At least one call-sound speaker kept an automatic name.
    case named
    /// The call app could not be read: no Accessibility permission.
    case noPermission = "no_permission"
    /// No usable talking evidence fell inside the call's speech.
    case noSignal = "no_signal"
    /// Evidence existed but no speaker reached a unique, qualifying name.
    case ambiguous
    /// The call app has no talker reader, or the evidence does not match its reader.
    case unsupported
    /// Positively known: the meeting was not a call.
    case notACall = "not_a_call"
    /// The saved evidence is missing on a known call, incompatible or corrupt.
    case unavailable
    /// Automatic names were proposed, and the user's own names displaced every one.
    case manualOnly = "manual_only"
  }

  public let surface: Surface?
  public let outcome: Outcome?
  /// Committed call-sound names with automatic provenance; a known zero stays 0.
  public let autoNamedCount: Int?
  /// How the speaker reads went (`speaker_reads_*`); nil when the log had no capture attempt.
  public let readHealth: SpeakerReadHealth?

  public init(
    surface: Surface?, outcome: Outcome?, autoNamedCount: Int?,
    readHealth: SpeakerReadHealth? = nil
  ) {
    self.surface = surface
    self.outcome = outcome
    self.autoNamedCount = autoNamedCount
    self.readHealth = readHealth
  }
}

/// How one recording's speaker reads went, as counts only (#4013 reading resilience §3.4), summed
/// over its saved log's segments. `meeting.ended` reports them as buckets
/// (`speaker_reads_unusable_share_bucket`, `speaker_reads_unusable_reason`,
/// `speaker_reads_tolerated_bucket`). The denominator is capture attempts: ticks skipped before a
/// copy (busy lane, dictation, no permission) are not attempts, so a low share says reads were
/// healthy when reading happened, not that reading happened.
public struct SpeakerReadHealth: Equatable, Sendable {
  /// Which kind of unusable copy was most common (`speaker_reads_unusable_reason`).
  public enum Reason: String, Sendable, CaseIterable {
    case unreadable
    case truncated
    case unresolvedScope = "unresolved_scope"
    case none
  }

  public let captureAttempts: Int
  public let unreadableCaptures: Int
  public let truncatedCaptures: Int
  /// Complete copies whose call could not be told (`CallSpeakerAdmission` scope).
  public let unresolvedScopeCaptures: Int
  /// Failed reads the capture policy tolerated; nil when a segment with attempts was saved
  /// before the counter existed.
  public let toleratedFailures: Int?

  /// Counts as given; nil when `captureAttempts` is not above zero.
  public init?(
    captureAttempts: Int, unreadableCaptures: Int, truncatedCaptures: Int,
    unresolvedScopeCaptures: Int, toleratedFailures: Int?
  ) {
    guard captureAttempts > 0 else { return nil }
    self.captureAttempts = captureAttempts
    self.unreadableCaptures = unreadableCaptures
    self.truncatedCaptures = truncatedCaptures
    self.unresolvedScopeCaptures = unresolvedScopeCaptures
    self.toleratedFailures = toleratedFailures
  }

  /// The log's summed segment health, or nil when it holds no capture attempt. Tolerated
  /// failures are summed over every segment, one whose copies were all dropped at delivery
  /// included (its walks are counted before the drop, `CallSpeakerObserver`); a segment that
  /// walked but predates the counter makes the sum unknown.
  public init?(log: CallSpeakerLog) {
    let healths = log.segments.compactMap(\.health)
    self.init(
      captureAttempts: healths.reduce(0) { $0 + $1.captureAttempts },
      unreadableCaptures: healths.reduce(0) { $0 + $1.unreadableCaptures },
      truncatedCaptures: healths.reduce(0) { $0 + $1.truncatedCaptures },
      unresolvedScopeCaptures: healths.reduce(0) { $0 + $1.unresolvedScopeCaptures },
      toleratedFailures: healths.reduce(Optional(0)) { sum, health in
        let walked = health.walkDurationCount > 0 || health.captureAttempts > 0
        let known = health.toleratedFailures ?? (walked ? nil : 0)
        return sum.flatMap { total in known.map { total + $0 } }
      })
  }

  /// Unreadable, truncated or out-of-scope copies over capture attempts.
  public var unusableShare: Double {
    Double(unreadableCaptures + truncatedCaptures + unresolvedScopeCaptures)
      / Double(captureAttempts)
  }

  /// The most common unusable kind; ties go unreadable, truncated, unresolved scope; `none`
  /// when every copy was usable.
  public var unusableReason: Reason {
    let counts: [(Reason, Int)] = [
      (.unreadable, unreadableCaptures), (.truncated, truncatedCaptures),
      (.unresolvedScope, unresolvedScopeCaptures),
    ]
    guard let most = counts.map(\.1).max(), most > 0 else { return .none }
    return counts.first { $0.1 == most }!.0
  }
}

/// What one naming pass knew before the durable History write. Content-free: a count of
/// proposals, never the names or the speakers they were for.
public enum SpeakerNamingPass: Equatable, Sendable {
  /// Positively known: the meeting was not a call.
  case notACall
  /// The namer proposed `count` (more than zero) automatic names. `readHealth` is the saved
  /// log's read health, nil without capture attempts.
  case proposed(
    surface: SpeakerNamingSummary.Surface?, count: Int, readHealth: SpeakerReadHealth? = nil)
  /// The namer proposed nothing. `outcome` is why, or `nil` when the inputs cannot say; it is
  /// never `named`, `manualOnly` or `notACall`.
  case abstained(
    surface: SpeakerNamingSummary.Surface?, outcome: SpeakerNamingSummary.Outcome?,
    readHealth: SpeakerReadHealth? = nil)
}

/// How the durable History write of the reconciled row ended.
public enum SpeakerNamingCommit: Sendable, Equatable {
  case written
  case failed
  /// The write's result is not known.
  case unknown
}

/// A summary calculated from the reconciled row before it is written. It is not evidence of a
/// commit: only `committed(_:)` with `.written` releases it.
public struct PendingSpeakerNamingSummary: Equatable, Sendable {
  private let summary: SpeakerNamingSummary

  /// The summary for `reconciled`, the row the durable write is about to store after
  /// `proposed.reconcilingSpeakerNames(withCurrent:)`. `proposed` is the pass's own row, which
  /// carries its automatic proposals; neither row's names or ids reach the summary.
  ///
  /// `auto_named_count` counts call-sound speakers present in the row's turns whose name is
  /// recorded as `.auto`, leaving out the microphone, the undivided call ("Call"), generated
  /// labels, the user's names and names of speakers no longer in the turns. `named` needs a
  /// count above zero. `manualOnly` needs a zero count and every proposal in `proposed`
  /// displaced by the user's names in `reconciled`: its speaker now carries a user's name, or a
  /// present speaker carries the user's name with the proposal's exact spelling. Proposals that
  /// vanished any other way, or an abstention that left automatic names behind, give no outcome.
  public init(proposed: Transcript, reconciled: Transcript, pass: SpeakerNamingPass) {
    let count = Self.autoNamedCount(in: reconciled)
    switch pass {
    case .notACall:
      summary = SpeakerNamingSummary(
        surface: SpeakerNamingSummary.Surface.none, outcome: count == 0 ? .notACall : nil,
        autoNamedCount: count)
    case .proposed(let surface, let proposals, let health):
      let outcome: SpeakerNamingSummary.Outcome?
      if proposals <= 0 {
        outcome = nil
      } else if count > 0 {
        outcome = .named
      } else {
        outcome =
          Self.everyProposalDisplaced(proposed: proposed, reconciled: reconciled)
          ? .manualOnly : nil
      }
      summary = SpeakerNamingSummary(
        surface: surface, outcome: outcome, autoNamedCount: count, readHealth: health)
    case .abstained(let surface, let reason, let health):
      let outcome: SpeakerNamingSummary.Outcome?
      switch reason {
      case .named?, .manualOnly?, .notACall?, nil: outcome = nil
      case let reason?: outcome = count == 0 ? reason : nil
      }
      summary = SpeakerNamingSummary(
        surface: surface, outcome: outcome, autoNamedCount: count, readHealth: health)
    }
  }

  /// The summary when the write is known to have stored the reconciled row; otherwise `nil`.
  public func committed(_ commit: SpeakerNamingCommit) -> SpeakerNamingSummary? {
    commit == .written ? summary : nil
  }

  /// The row's call-sound speakers that are present in its turns.
  private static func presentCallSpeakers(in row: Transcript) -> Set<String> {
    Set((row.turns ?? []).map(\.speakerId)).filter {
      Transcript.trackPrefix(of: $0) == MeetingTrackKind.callSound.speakerPrefix
        && $0 != MeetingTranscriptComposer.fallbackCallSpeakerID
    }
  }

  static func autoNamedCount(in row: Transcript) -> Int {
    presentCallSpeakers(in: row).filter { id in
      guard row.speakerNameSources?[id] == .auto, let name = row.speakerNames?[id] else {
        return false
      }
      return !Transcript.isGeneratedLabel(name, for: id)
    }.count
  }

  /// Whether `proposed` has automatic call-sound names and the user's names in `reconciled`
  /// displaced each one.
  private static func everyProposalDisplaced(proposed: Transcript, reconciled: Transcript)
    -> Bool
  {
    let proposals = presentCallSpeakers(in: proposed).compactMap { id -> (String, String)? in
      guard proposed.speakerNameSources?[id] == .auto, let name = proposed.speakerNames?[id],
        !Transcript.isGeneratedLabel(name, for: id)
      else { return nil }
      return (id, name)
    }
    guard !proposals.isEmpty else { return false }
    let present = Set((reconciled.turns ?? []).map(\.speakerId))
    let manualNames = Set(
      present.filter { reconciled.speakerNameSource(for: $0) == .manual }
        .compactMap { reconciled.speakerNames?[$0] })
    return proposals.allSatisfy { id, name in
      (present.contains(id) && reconciled.speakerNameSource(for: id) == .manual)
        || manualNames.contains(name)
    }
  }
}
