/// Read-only projection of the existing kernel terminal for Setup. A target identifier
/// is available only when the paste owner verified the direct write to that editor.
package enum PracticeTakeEvidence: Equatable {
  case delivered(verifiedEditor: String?, copied: Bool, polished: Bool)
  case noSpeech
  case failed
  case cancelled
}
