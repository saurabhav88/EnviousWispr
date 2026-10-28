import EnviousWisprCore

extension MeetingNamingResult {
  /// This result as the content-free pass the durable write summarizes (#4013 r3 F4). `log` is
  /// the saved evidence the namer read.
  ///
  /// An outcome the namer cannot tell apart from another stays `nil`:
  /// - `noLog`: the meeting may not be a call, or its evidence may be missing; the caller that
  ///   read the file says which (`.notACall`, or `.unavailable` for a known call).
  /// - `unreadable`: a live read failure, not missing or damaged saved evidence.
  /// - `statusUnknown`: a log with no status, or one this build does not know, is not proof
  ///   that the evidence is missing, incompatible or corrupt.
  /// - `rulesUnusable`: frozen rules that no longer decode, or rules that forbid a talker.
  /// - `lagUnmeasured`, `rosterUncertain`: a talker surface the namer may not use yet.
  /// - `noEligibleSpeakers`: no one else spoke, or eligibility was not supplied.
  package func pass(log: CallSpeakerLog?) -> SpeakerNamingPass {
    let surface = SpeakerNamingSummary.Surface(log?.surface)
    let reason: SpeakerNamingSummary.Outcome?
    switch outcome {
    case .named:
      return proposals.isEmpty
        ? .abstained(surface: surface, outcome: nil)
        : .proposed(surface: surface, count: proposals.count)
    case .noPermission: reason = .noPermission
    case .unsupported: reason = .unsupported
    case .noSignal: reason = .noSignal
    case .ambiguous: reason = .ambiguous
    case .noLog, .unreadable, .rulesUnusable, .statusUnknown, .lagUnmeasured, .rosterUncertain,
      .noEligibleSpeakers:
      reason = nil
    }
    return .abstained(surface: surface, outcome: reason)
  }
}
