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

  public init(surface: Surface?, outcome: Outcome?, autoNamedCount: Int?) {
    self.surface = surface
    self.outcome = outcome
    self.autoNamedCount = autoNamedCount
  }
}

/// What one naming pass knew before the durable History write. Content-free: a count of
/// proposals, never the names or the speakers they were for.
public enum SpeakerNamingPass: Equatable, Sendable {
  /// Positively known: the meeting was not a call.
  case notACall
  /// The namer proposed `count` (more than zero) automatic names.
  case proposed(surface: SpeakerNamingSummary.Surface?, count: Int)
  /// The namer proposed nothing. `outcome` is why, or `nil` when the inputs cannot say; it is
  /// never `named`, `manualOnly` or `notACall`.
  case abstained(surface: SpeakerNamingSummary.Surface?, outcome: SpeakerNamingSummary.Outcome?)
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
    case .proposed(let surface, let proposals):
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
      summary = SpeakerNamingSummary(surface: surface, outcome: outcome, autoNamedCount: count)
    case .abstained(let surface, let reason):
      let outcome: SpeakerNamingSummary.Outcome?
      switch reason {
      case .named?, .manualOnly?, .notACall?, nil: outcome = nil
      case let reason?: outcome = count == 0 ? reason : nil
      }
      summary = SpeakerNamingSummary(surface: surface, outcome: outcome, autoNamedCount: count)
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
