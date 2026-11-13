/// Read-only projection of the existing kernel terminal for Setup. Text stays in process and is
/// used only to verify delivery to the practice editor, never to fill it or report telemetry.
package enum PracticeTakeEvidence: Equatable {
  case delivered(text: String, pasted: Bool, copied: Bool, polished: Bool)
  case noSpeech
  case failed
  case cancelled
}
