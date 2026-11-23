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
