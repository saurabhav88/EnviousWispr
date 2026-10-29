import EnviousWisprCore
import Foundation

/// The meeting's saved call-speaker evidence as one processing pass received it (#4013 chunk
/// 12A): read once, before the pass starts, and never read again during it. The coordinator
/// projects the store's load result into this, so Pipeline does not depend on Storage.
///
/// Absent evidence never means "not a call": an older meeting, a call app with no reader and a
/// meeting with no call all look the same here.
package enum MeetingCallSpeakerEvidence: Sendable, Equatable {
  case usable(CallSpeakerLog)
  /// No evidence file.
  case absent
  /// A file exists but cannot be used.
  case unusable(UnusableReason)

  package enum UnusableReason: String, Sendable, Equatable {
    case unreadable
    case tooLarge
    case newerFormat
    case invalid
  }

  /// The log the namer reads; `nil` unless usable.
  package var log: CallSpeakerLog? {
    if case .usable(let log) = self { return log }
    return nil
  }
}

/// What a pass's automatic speaker naming produced, kept apart from the composition, which it
/// never changes. `result.proposals` are proposals only: what History keeps is decided by the
/// durable write, where the user's own names win.
package struct MeetingNamingOutput: Sendable, Equatable {
  /// The evidence the namer read, so later telemetry can tell absent from unusable.
  package let evidence: MeetingCallSpeakerEvidence
  /// Who could be named and where, derived from the pass's own pieces before composition.
  package let eligibility: MeetingNamingEligibility
  package let result: MeetingNamingResult

  package init(
    evidence: MeetingCallSpeakerEvidence, eligibility: MeetingNamingEligibility,
    result: MeetingNamingResult
  ) {
    self.evidence = evidence
    self.eligibility = eligibility
    self.result = result
  }
}
