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

  // MARK: - #4601: a microphone that did not answer

  private func shown(_ take: SetupPracticeTake, _ attempt: SetupPracticeAttempt)
    -> SetupPracticeState
  {
    SetupPracticeRoute.displayed(
      take, microphoneOff: false, accessibilityOff: false, usable: true, attempt: attempt,
      polishOn: false)
  }

  @Test("A first press whose start was not answered shows the notice with no take or receipt")
  func sessionlessFailureShowsTheNotice() {
    let attempt = SetupPracticeAttempt()
    // The pre-warm failed before any session: the phase carries the reason, no take began.
    #expect(shown(take(.error(.micNotResponding), id: ""), attempt) == .microphoneNotResponding)
    #expect(attempt.success == nil)
  }

  @Test("A failed take whose start was not answered shows the same notice, never success")
  func failedTakeShowsTheNotice() {
    var attempt = SetupPracticeAttempt()
    attempt.observe(take(.recording), focusedEditor: "editor")
    let failed = take(.error(.micNotResponding), terminal: .failed)
    attempt.observe(failed, focusedEditor: "editor")
    #expect(shown(failed, attempt) == .microphoneNotResponding)
    #expect(attempt.success == nil, "a failed attempt cannot establish success")
  }

  @Test("An earlier verified success survives the notice, and the next press clears it")
  func successSurvivesAndRetryClears() {
    var attempt = SetupPracticeAttempt()
    attempt.observe(take(.recording), focusedEditor: "editor")
    attempt.observe(take(.complete, terminal: delivered(editor: "editor")), focusedEditor: "editor")
    #expect(attempt.success == .completed(polished: true))

    let stuck = take(.error(.micNotResponding), id: "")
    #expect(shown(stuck, attempt) == .microphoneNotResponding)
    #expect(attempt.success == .completed(polished: true), "the notice does not erase success")

    // The next press is in flight, then lands: the notice is gone.
    #expect(shown(take(.recording, id: "retry"), attempt) == .listening(handsFree: false))
    #expect(shown(take(.complete, id: "retry"), attempt) == .worked)
  }

  @Test("Permission still wins, and a generic failure keeps its own state")
  func precedenceAndGenericFailure() {
    let attempt = SetupPracticeAttempt()
    let stuck = take(.error(.micNotResponding), id: "")
    #expect(
      SetupPracticeRoute.displayed(
        stuck, microphoneOff: true, accessibilityOff: false, usable: true, attempt: attempt,
        polishOn: false) == .microphoneOff)
    #expect(shown(take(.error(.micWouldNotOpen), id: ""), attempt) != .microphoneNotResponding)
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
