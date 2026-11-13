import EnviousWisprCore
import EnviousWisprPipeline
import Testing

@testable import EnviousWisprAppKit

@MainActor
@Suite("Setup Practice take evidence", .tags(.productOutcome))
struct SetupPracticeAttemptTests {
  @Test("Typing after a missed paste and deleting around old text cannot prove delivery")
  func ordinaryEdits() {
    let progress = SetupPracticeProgress()
    progress.text = "hello"
    progress.attempt.observe(take(.recording), focusedEditor: "editor")
    progress.attempt.observe(
      take(.complete, terminal: delivered()), focusedEditor: "editor")
    progress.text = "hello "
    #expect(progress.attempt.success == nil)
    progress.text = "before hello after"
    progress.text = "hello"
    #expect(progress.attempt.success == nil)
    #expect(progress.attempt.state == .missedBox(copiedToClipboard: false))
  }

  @Test("Only this take's verified write to the editor succeeds and survives reopening")
  func verifiedWrite() {
    let progress = SetupPracticeProgress()
    progress.attempt.observe(take(.recording, id: "old"), focusedEditor: "old editor")
    progress.attempt.detachEditor()
    progress.attempt.observe(take(.recording), focusedEditor: "editor")
    progress.attempt.observe(
      take(.complete, id: "old", terminal: delivered(editor: "editor")), focusedEditor: "editor")
    #expect(progress.attempt.success == nil)
    progress.attempt.observe(
      take(.complete, terminal: delivered(editor: "editor")), focusedEditor: "editor")
    progress.text = "My dictated words"
    progress.attempt.detachEditor()
    #expect(progress.attempt.success == .completed(polished: true))
    #expect(progress.text == "My dictated words")
    progress.reset()
    #expect(progress.attempt.success == nil)
    #expect(progress.text.isEmpty)
  }

  @Test("The previous editor and clipboard-only delivery cannot verify success")
  func missedBox() {
    var attempt = SetupPracticeAttempt()
    attempt.observe(take(.recording), focusedEditor: "new editor")
    attempt.observe(
      take(.complete, terminal: delivered(editor: "old editor")), focusedEditor: "new editor")
    #expect(attempt.state == .missedBox(copiedToClipboard: false))
    #expect(attempt.success == nil)

    attempt.observe(take(.recording, id: "next"), focusedEditor: nil)
    attempt.observe(
      take(.complete, id: "next", terminal: delivered(copied: true)), focusedEditor: nil)
    #expect(attempt.state == .missedBox(copiedToClipboard: true))
    #expect(attempt.success == nil)
  }

  @Test("Cancellation, silence and failure remain distinct")
  func terminalStates() {
    var attempt = SetupPracticeAttempt()
    attempt.observe(take(.recording), focusedEditor: "editor")
    attempt.observe(take(.idle, terminal: .cancelled), focusedEditor: "editor")
    #expect(attempt.state == .waiting)
    attempt.observe(take(.recording, id: "quiet"), focusedEditor: "editor")
    attempt.observe(take(.idle, id: "quiet", terminal: .noSpeech), focusedEditor: "editor")
    #expect(attempt.state == .noSpeech)
    attempt.observe(take(.recording, id: "next"), focusedEditor: "editor")
    attempt.observe(
      take(.error(.asrInterrupted), id: "next", terminal: .failed), focusedEditor: "editor")
    #expect(attempt.state == .pipelineFailed)
  }

  private func take(
    _ phase: PipelineState, id: String = "first", terminal: PracticeTakeEvidence? = nil
  ) -> SetupPracticeTake {
    SetupPracticeTake(id: id, phase: phase, locked: false, terminal: terminal)
  }

  private func delivered(editor: String? = nil, copied: Bool = false) -> PracticeTakeEvidence {
    .delivered(verifiedEditor: editor, copied: copied, polished: true)
  }
}
