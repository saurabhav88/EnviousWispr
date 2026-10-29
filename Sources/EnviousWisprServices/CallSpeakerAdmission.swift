import Foundation

/// What the observer established about one capture of a call app (#4013 r5 item 1). A reader
/// never infers these from the tree it was given: a non-empty tree is not proof that the copy
/// was complete, nor that it belongs to the one call being recorded.
package struct CallCaptureContext: Sendable, Equatable {
  package enum Completeness: Sendable, Equatable {
    /// Every element within the copy's bounds was reached and every read succeeded.
    case complete
    /// The copy stopped at its node, depth or time bound.
    case truncated
    /// A read failed (the app went away, an attribute could not be read).
    case unreadable
    case unknown
  }

  package enum Scope: Sendable, Equatable {
    /// The windows or pages copied belong to the one linked call.
    case resolved
    /// More than one candidate call, or windows that could belong to different calls.
    case unresolved
    case unknown
  }

  package let completeness: Completeness
  package let scope: Scope

  package init(completeness: Completeness, scope: Scope) {
    self.completeness = completeness
    self.scope = scope
  }
}

/// One participant a reader identified in one snapshot. `key` tells participants apart within
/// that snapshot only (a tile position, a roster row); it is never a display name, never kept
/// past the snapshot and never saved, logged or sent.
package struct CallParticipant: Sendable, Equatable {
  package let key: String
  /// `nil` when the participant's name could not be read.
  package let name: String?
  package let isTalking: Bool
  /// The app itself marked this participant as the user.
  package let isSelf: Bool

  package init(key: String, name: String?, isTalking: Bool, isSelf: Bool) {
    self.key = key
    self.name = name
    self.isTalking = isTalking
    self.isSelf = isSelf
  }
}

/// Whether one reading may become a naming observation, and why not.
package enum CallNamingAdmission: Sendable, Equatable {
  case admitted
  case withheld(Reason)

  package enum Reason: String, Sendable, Equatable, CaseIterable {
    case captureTruncated
    case captureUnreadable
    case completenessUnknown
    case callScopeUnresolved
    /// The reader could not tell distinct participants from repeated views of one participant.
    case identityUnestablished
    /// Someone talking has no readable name.
    case unnamedTalker
    /// Someone talking shares a display name with another participant.
    case ambiguousTalker
  }
}

/// The one admission rule every reader's output goes through (#4013 r5 item 1). Readers own how
/// they find participants on their surface; none of them decides ambiguity on its own.
///
/// Step 4 contract: the namer consumes only observations admitted here, keeps its status,
/// source, rules, lag, self, eligible-speech and voting checks, and excludes names that two
/// distinct participants share (the roster the readers now keep with duplicates). It no longer
/// requires `rosterFromParticipantList`, and no other complete-roster requirement replaces it.
package enum CallSpeakerAdmission {
  package static func admission(of reading: CallSpeakerReading, context: CallCaptureContext)
    -> CallNamingAdmission
  {
    switch context.completeness {
    case .complete: break
    case .truncated: return .withheld(.captureTruncated)
    case .unreadable: return .withheld(.captureUnreadable)
    case .unknown: return .withheld(.completenessUnknown)
    }
    guard context.scope == .resolved else { return .withheld(.callScopeUnresolved) }
    guard reading.participantIdentityEstablished else { return .withheld(.identityUnestablished) }
    let talkers = reading.participants.filter(\.isTalking)
    if talkers.contains(where: { $0.name == nil }) { return .withheld(.unnamedTalker) }
    for talker in talkers {
      guard let name = talker.name else { continue }
      let sharing = reading.participants.filter { $0.name == name && $0.key != talker.key }
      if !sharing.isEmpty || reading.sharedNames.contains(name) {
        return .withheld(.ambiguousTalker)
      }
    }
    return .admitted
  }

  /// What an admitted reading contributes to the saved observations: the names shown talking,
  /// the user's included (the namer removes them). `nil` for a withheld reading, which is never
  /// an ordinary quiet observation; an empty array is a valid quiet reading.
  package static func observationSpeaking(
    _ reading: CallSpeakerReading, context: CallCaptureContext
  ) -> [String]? {
    guard admission(of: reading, context: context) == .admitted else { return nil }
    return uniqueInOrder(reading.participants.filter(\.isTalking).compactMap(\.name))
  }
}
