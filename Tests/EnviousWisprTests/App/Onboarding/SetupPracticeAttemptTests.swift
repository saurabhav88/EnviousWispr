import EnviousWisprCore
import EnviousWisprPipeline
import Testing

@testable import EnviousWisprAppKit

@Suite("Setup Practice take evidence", .tags(.productOutcome))
struct SetupPracticeAttemptTests {
  @Test("Only the delivered words reaching the focused editor unlock Continue")
  func deliveredWords() {
    var attempt = SetupPracticeAttempt()
    let recording = take(.recording)
    attempt.observe(recording, focused: true)
    attempt.editorChanged(from: "", to: "Manually typed", take: recording, focused: true)
    #expect(attempt.success == nil)
    attempt.editorChanged(
      from: "Manually typed", to: "My dictated words", take: take(.transcribing), focused: true)
    attempt.observe(take(.complete, terminal: delivered(pasted: true)), focused: true)
    #expect(attempt.state == .worked)
    #expect(attempt.success == .completed(polished: true))

    attempt.observe(take(.recording, id: "next"), focused: true)
    attempt.observe(take(.idle, id: "next", terminal: .noSpeech), focused: true)
    #expect(attempt.state == .noSpeech)
    #expect(attempt.success == .completed(polished: true))
  }

  @Test("Unfocused or already-running takes cannot count as delivery to the editor")
  func missedBox() {
    var attempt = SetupPracticeAttempt()
    attempt.observe(take(.recording), focused: true, mounted: true)
    attempt.editorChanged(
      from: "", to: "My dictated words", take: take(.transcribing), focused: true)
    attempt.observe(take(.complete, terminal: delivered(pasted: true)), focused: true)
    #expect(attempt.state == .missedBox(copiedToClipboard: false))
    #expect(attempt.success == nil)

    attempt.observe(take(.recording, id: "next"), focused: false)
    attempt.observe(
      take(.complete, id: "next", terminal: delivered(pasted: false, copied: true)),
      focused: false)
    #expect(attempt.state == .missedBox(copiedToClipboard: true))
    #expect(attempt.success == nil)
  }

  @Test("The editor may receive a posted paste after the take has concluded")
  func delayedPaste() {
    var attempt = SetupPracticeAttempt()
    attempt.observe(take(.recording), focused: true)
    let complete = take(.complete, terminal: delivered(pasted: true))
    attempt.observe(complete, focused: true)
    #expect(attempt.success == nil)
    attempt.editorChanged(from: "", to: "My dictated words", take: complete, focused: true)
    #expect(attempt.success == .completed(polished: true))
  }

  @Test("A cancelled or stale terminal does not overwrite the current attempt")
  func cancelledAndStale() {
    var attempt = SetupPracticeAttempt()
    attempt.observe(take(.recording), focused: true)
    attempt.observe(take(.idle, terminal: .cancelled), focused: true)
    #expect(attempt.state == .waiting)

    attempt.observe(take(.recording, id: "next"), focused: true)
    attempt.observe(take(.complete, terminal: delivered(pasted: true)), focused: true)
    #expect(attempt.success == nil)
    attempt.observe(take(.error(.asrInterrupted), id: "next", terminal: .failed), focused: true)
    #expect(attempt.state == .pipelineFailed)
  }

  private func take(
    _ phase: PipelineState, id: String = "first", terminal: PracticeTakeEvidence? = nil
  ) -> SetupPracticeTake {
    SetupPracticeTake(id: id, phase: phase, locked: false, terminal: terminal)
  }

  private func delivered(pasted: Bool, copied: Bool = false) -> PracticeTakeEvidence {
    .delivered(text: "My dictated words", pasted: pasted, copied: copied, polished: true)
  }
}
