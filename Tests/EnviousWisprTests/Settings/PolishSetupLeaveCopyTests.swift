import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #3438. The leave dialog's English words and buttons, pinned to the copy the founder
/// approved through the council and Codex workshop (plan §17).
@MainActor
@Suite("Leave dialog copy and buttons (#3438)", .tags(.driftGuard))
struct PolishSetupLeaveCopyTests {

  private static func content(
    _ problem: PolishSetupProblem, goBack: LLMProvider? = nil, keyNotSaved: Bool = false
  ) -> PolishSetupLeaveDialogContent {
    PolishSetupLeaveDialogContent.make(
      for: PolishSetupLeaveRequest(
        intent: .sidebar(.history), episode: PolishSetupEpisodeToken(rawValue: 1),
        problem: problem, goBackProvider: goBack, keyNotSaved: keyNotSaved))
  }

  @Test("a missing cloud key, with and without Go back, and with an unsaved draft")
  func cloudKey() {
    let plain = Self.content(.cloudKeyMissing(.openAI))
    #expect(plain.title == "Finish AI polish setup")
    #expect(
      plain.message
        == "Add your OpenAI API key to use AI polish. Until then, text is pasted without AI polish."
    )
    #expect(plain.buttons.map(\.title) == ["Finish setup", "Leave anyway"])
    #expect(plain.buttons.first?.role == .cancel)

    let withBack = Self.content(.cloudKeyMissing(.openAI), goBack: .egOne)
    #expect(withBack.buttons.map(\.title) == ["Finish setup", "Go back to EG-1", "Leave anyway"])
    #expect(withBack.buttons[1].action == .goBack(.egOne))

    let draft = Self.content(.cloudKeyMissing(.claude), keyNotSaved: true)
    #expect(
      draft.message
        == "Your Claude key is not saved yet. Until then, text is pasted without AI polish.")
  }

  @Test("every actionable reason has its sentence")
  func actionableReasons() {
    let cases: [(PolishSetupProblem, String)] = [
      (.cloudKeyRejected(.gemini), "Gemini did not accept your API key."),
      (.ollamaNotInstalled, "Install Ollama to use AI polish."),
      (.ollamaNotRunning, "Start Ollama to use AI polish."),
      (.ollamaNoModel, "Choose an Ollama model to use AI polish."),
      (.ollamaModelNotInstalled, "Download the selected Ollama model, or choose another."),
      (.localEngineNotDownloaded(.egOne), "EG-1 is not downloaded yet."),
      (.localEngineDownloadPaused(.s1Mini), "The S1-mini download is paused."),
      (.localEngineUpdatePaused(.egOne), "The EG-1 update is paused."),
      (.localEngineFailed(.egOne), "The EG-1 download did not finish."),
    ]
    for (problem, reason) in cases {
      #expect(
        Self.content(problem).message
          == reason + " Until then, text is pasted without AI polish.", "\(problem)")
    }
  }

  @Test("informational notices have OK only")
  func informational() {
    let downloading = Self.content(.localEngineDownloading(.egOne))
    #expect(downloading.title == "EG-1 is still downloading")
    #expect(
      downloading.message
        == "The download is still in progress. Until setup finishes, text is pasted without AI polish."
    )
    #expect(downloading.buttons.map(\.title) == ["OK"])
    #expect(downloading.buttons.map(\.action) == [.ok])

    let verifying = Self.content(.localEngineVerifying(.s1Mini))
    #expect(verifying.title == "Checking the downloaded S1-mini")
    #expect(verifying.message == "Until this check finishes, text is pasted without AI polish.")

    let apple = Self.content(.appleModelNotReady)
    #expect(apple.title == "Apple Intelligence isn't ready yet")
    #expect(apple.message == "Until it is ready, text is pasted without AI polish.")
    #expect(apple.buttons.map(\.title) == ["OK"])
  }

  @Test("Apple Intelligence: off has three buttons, unavailable has two, never Go back")
  func apple() {
    let off = Self.content(.appleUnavailable(.appleIntelligenceDisabled), goBack: .egOne)
    #expect(off.title == "Apple Intelligence is turned off")
    #expect(off.message == "Turn it on in System Settings, or pick another model.")
    #expect(
      off.buttons.map(\.title) == ["Open System Settings", "Pick another model", "Leave anyway"])
    #expect(off.buttons[1].role == .cancel)

    let oldMac = Self.content(.appleUnavailable(.unsupportedOS), goBack: .egOne)
    #expect(oldMac.title == "Apple Intelligence isn't available")
    #expect(
      oldMac.message
        == "AI polish with Apple Intelligence requires macOS 26 or later. Pick another model.")
    #expect(oldMac.buttons.map(\.title) == ["Pick another model", "Leave anyway"])

    let ineligible = Self.content(.appleUnavailable(.deviceNotEligible))
    #expect(ineligible.message == "This Mac does not support Apple Intelligence.")
  }

  @Test("no dialog has more than three buttons, and no copy has a long dash")
  func limits() {
    let problems: [PolishSetupProblem] = [
      .cloudKeyMissing(.openAI), .appleUnavailable(.appleIntelligenceDisabled),
      .localEngineDownloading(.egOne), .ollamaNotRunning,
    ]
    for problem in problems {
      let c = Self.content(problem, goBack: .egOne, keyNotSaved: true)
      #expect(c.buttons.count <= 3, "\(problem)")
      let all = ([c.title, c.message] + c.buttons.map(\.title)).joined()
      #expect(all.contains("\u{2014}") == false, "\(problem)")
      #expect(all.contains("\u{2013}") == false, "\(problem)")
    }
  }
}
