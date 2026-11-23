import EnviousWisprCore

/// Read-only projection of the existing kernel terminal for Setup. A target identifier
/// is available only when the paste owner verified the direct write to that editor.
package enum PracticeTakeEvidence: Equatable {
  /// `waitedForModel` (#4845): this take missed polish only because the local polish model was
  /// not ready yet (still downloading, starting, paused) or the take was too short to polish.
  /// After Skip ahead that is the promised basic cleanup; any other miss (a failure, a crash
  /// mid-request, a truncated answer) is not.
  case delivered(verifiedEditor: String?, copied: Bool, polished: Bool, waitedForModel: Bool = false)
  case noSpeech
  case failed
  case cancelled
}

extension PracticeTakeEvidence {
  /// #4845: whether `polish` (this take's own outcome) missed polish only because the local
  /// polish model was not ready yet or the take was too short to polish. Any other miss (a
  /// failure, a crash mid-request, a truncated answer) and a take with no outcome are not.
  package static func waitedForModel(_ polish: PolishTakeOutcome?) -> Bool {
    guard let polish, polish.result != .polished else { return false }
    if polish.result == .bypassed { return true }
    return polish.evidence == .localEngineNotReady || polish.evidence == .localEngineDownloadPending
  }
}
