import Foundation
import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #3438. The leave dialog's English words and buttons, pinned to the copy the founder
/// approved through the council and Codex workshop (plan §17).
@MainActor
@Suite("Leave dialog copy and buttons (#3438)", .tags(.driftGuard))
struct PolishSetupLeaveCopyTests {

  private static func content(
    _ problem: PolishSetupProblem, goBack: LLMProvider? = nil, keyNotSaved: Bool = false,
    scope: PolishSetupScope = .dictation
  ) -> PolishSetupLeaveDialogContent {
    PolishSetupLeaveDialogContent.make(
      for: PolishSetupLeaveRequest(
        intent: .sidebar(.history), scope: scope, episode: PolishSetupEpisodeToken(rawValue: 1),
        problem: problem, provider: .openAI, goBackProvider: goBack, keyNotSaved: keyNotSaved))
  }

  private static func sizedRequest(
    _ problem: PolishSetupProblem, size: EGOneSize?
  ) -> PolishSetupLeaveRequest {
    PolishSetupLeaveRequest(
      intent: .sidebar(.history), scope: .dictation,
      episode: PolishSetupEpisodeToken(rawValue: 1), problem: problem, provider: .egOne,
      goBackProvider: nil, keyNotSaved: false, egOneSize: size)
  }

  // #4473
  @Test("the leave question names the EG-1 size; full or unknown stays EG-1")
  func namesTheEGOneSize() {
    func message(_ problem: PolishSetupProblem, _ size: EGOneSize?) -> String {
      PolishSetupLeaveDialogContent.make(for: Self.sizedRequest(problem, size: size)).message
    }
    let tail = " Until then, text is pasted without AI polish."
    #expect(
      message(.localEngineNotDownloaded(.egOne), .micro)
        == "EG-1 Micro is not downloaded yet." + tail)
    #expect(
      message(.localEngineNotDownloaded(.egOne), .micro).hasPrefix("EG-1 Micro is not downloaded yet."))
    #expect(
      message(.localEngineNotDownloaded(.egOne), .mini)
        == "EG-1 Mini is not downloaded yet." + tail)
    #expect(
      message(.localEngineNotDownloaded(.egOne), nil) == "EG-1 is not downloaded yet." + tail)
    #expect(
      message(.localEngineNotDownloaded(.egOne), .full) == "EG-1 is not downloaded yet." + tail)
    #expect(
      message(.localEngineDownloadPaused(.egOne), .micro)
        == "The EG-1 Micro download is paused." + tail)
    #expect(
      message(.localEngineUpdatePaused(.egOne), .mini) == "The EG-1 Mini update is paused." + tail)
    #expect(
      message(.localEngineFailed(.egOne), .micro)
        == "The EG-1 Micro download did not finish." + tail)
    #expect(
      message(.localEngineFailed(.s1Mini), .micro)
        == "The S1-mini download did not finish." + tail)
  }

  @Test("the informational titles name the EG-1 size")
  func informationalTitlesNameTheSize() {
    let downloading = PolishSetupLeaveDialogContent.make(
      for: Self.sizedRequest(.localEngineDownloading(.egOne), size: .micro))
    #expect(downloading.title == "EG-1 Micro is still downloading")
    let verifying = PolishSetupLeaveDialogContent.make(
      for: Self.sizedRequest(.localEngineVerifying(.egOne), size: .mini))
    #expect(verifying.title.contains("EG-1 Mini"))
    let plain = PolishSetupLeaveDialogContent.make(
      for: Self.sizedRequest(.localEngineDownloading(.egOne), size: nil))
    #expect(plain.title == "EG-1 is still downloading")
  }

  @Test("the request hands its EG-1 size to the prompt subject")
  func promptSubjectCarriesTheSize() {
    #expect(
      Self.sizedRequest(.localEngineNotDownloaded(.egOne), size: .micro).promptSubject.egOneSize
        == .micro)
    #expect(
      Self.sizedRequest(.localEngineNotDownloaded(.egOne), size: nil).promptSubject.egOneSize
        == nil)
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
    let newerMacOS = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    #expect(off.title == (newerMacOS
      ? "Apple Intelligence wasn't enabled" : "Apple Intelligence is turned off"))
    #expect(off.message == (newerMacOS
      ? "Apple Intelligence wasn't enabled at the last check. Pick another model, or leave without AI polish. System Settings may not offer a fix."
      : "Turn it on in System Settings, or pick another model."))
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
    for scope in [PolishSetupScope.dictation, .meetingSummary] {
      for problem in problems {
        let c = Self.content(problem, goBack: .egOne, keyNotSaved: true, scope: scope)
        #expect(c.buttons.count <= 3, "\(problem)")
        let all = ([c.title, c.message] + c.buttons.map(\.title)).joined()
        #expect(all.contains("\u{2014}") == false, "\(problem)")
        #expect(all.contains("\u{2013}") == false, "\(problem)")
      }
    }
  }

  // MARK: - EnviousMeet Summaries (#4321)

  private static func summary(
    _ problem: PolishSetupProblem, goBack: LLMProvider? = nil, keyNotSaved: Bool = false
  ) -> PolishSetupLeaveDialogContent {
    content(problem, goBack: goBack, keyNotSaved: keyNotSaved, scope: .meetingSummary)
  }

  private static let summaryUntilThen = "Until then, EnviousMeet can't write meeting summaries."

  @Test("Summaries: the title and lines name meeting summaries; buttons match AI Polish")
  func summaryActionable() {
    let plain = Self.summary(.cloudKeyMissing(.claude))
    #expect(plain.title == "Finish summary setup")
    #expect(
      plain.message
        == "Add your Claude API key to write meeting summaries. " + Self.summaryUntilThen)
    #expect(plain.buttons == Self.content(.cloudKeyMissing(.claude)).buttons)

    let withBack = Self.summary(.cloudKeyMissing(.claude), goBack: .appleIntelligence)
    #expect(
      withBack.buttons.map(\.title)
        == ["Finish setup", "Go back to Apple Intelligence", "Leave anyway"])
    #expect(withBack.buttons[1].action == .goBack(.appleIntelligence))
    #expect(withBack.buttons.first?.role == .cancel)

    let draft = Self.summary(.cloudKeyMissing(.claude), keyNotSaved: true)
    #expect(draft.message == "Your Claude key is not saved yet. " + Self.summaryUntilThen)

    let cases: [(PolishSetupProblem, String)] = [
      (.cloudKeyRejected(.gemini), "Gemini did not accept your API key."),
      (.ollamaNotInstalled, "Install Ollama to write meeting summaries."),
      (.ollamaNotRunning, "Start Ollama to write meeting summaries."),
      (.ollamaNoModel, "Choose an Ollama model to write meeting summaries."),
      (.ollamaModelNotInstalled, "Download the selected Ollama model, or choose another."),
      (.localEngineNotDownloaded(.egOne), "EG-1 is not downloaded yet."),
      (.localEngineDownloadPaused(.egOne), "The EG-1 download is paused."),
      (.localEngineUpdatePaused(.egOne), "The EG-1 update is paused."),
      (.localEngineFailed(.egOne), "The EG-1 download did not finish."),
    ]
    for (problem, reason) in cases {
      let c = Self.summary(problem)
      #expect(c.title == "Finish summary setup", "\(problem)")
      #expect(c.message == reason + " " + Self.summaryUntilThen, "\(problem)")
    }
  }

  @Test("Summaries: informational notices keep OK only and name meeting summaries")
  func summaryInformational() {
    let downloading = Self.summary(.localEngineDownloading(.egOne))
    #expect(downloading.title == "EG-1 is still downloading")
    #expect(
      downloading.message
        == "The download is still in progress. Until setup finishes, EnviousMeet can't write meeting summaries."
    )
    #expect(downloading.buttons.map(\.action) == [.ok])

    let verifying = Self.summary(.localEngineVerifying(.egOne))
    #expect(verifying.title == "Checking the downloaded EG-1")
    #expect(
      verifying.message == "Until this check finishes, EnviousMeet can't write meeting summaries.")
    #expect(verifying.buttons.map(\.action) == [.ok])

    let apple = Self.summary(.appleModelNotReady)
    #expect(apple.title == "Apple Intelligence isn't ready yet")
    #expect(apple.message == "Until it is ready, EnviousMeet can't write meeting summaries.")
    #expect(apple.buttons.map(\.action) == [.ok])
  }

  @Test("Summaries: Apple Intelligence branches keep their buttons and never say AI polish")
  func summaryApple() {
    let off = Self.summary(.appleUnavailable(.appleIntelligenceDisabled), goBack: .egOne)
    let newerMacOS = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    #expect(off.title == Self.content(.appleUnavailable(.appleIntelligenceDisabled)).title)
    #expect(off.message == (newerMacOS
      ? "Apple Intelligence wasn't enabled at the last check. Pick another model, or leave without meeting summaries. System Settings may not offer a fix."
      : "Turn it on in System Settings, or pick another model."))
    #expect(
      off.buttons == Self.content(.appleUnavailable(.appleIntelligenceDisabled), goBack: .egOne)
        .buttons)

    let oldMac = Self.summary(.appleUnavailable(.unsupportedOS))
    #expect(oldMac.title == "Apple Intelligence isn't available")
    #expect(
      oldMac.message
        == "Meeting summaries with Apple Intelligence require macOS 26 or later. Pick another model.")
    #expect(oldMac.buttons.map(\.title) == ["Pick another model", "Leave anyway"])
    #expect(
      Self.summary(.appleUnavailable(.deviceNotEligible)).message
        == "This Mac does not support Apple Intelligence.")
    // Both macOS wordings of the off message, whatever this Mac runs.
    #expect(
      AppleIntelligenceSetupCopy.forOSMajorVersion(27).summaryLeaveMessage
        == "Apple Intelligence wasn't enabled at the last check. Pick another model, or leave without meeting summaries. System Settings may not offer a fix."
    )
    #expect(
      AppleIntelligenceSetupCopy.forOSMajorVersion(26).summaryLeaveMessage
        == "Turn it on in System Settings, or pick another model.")
  }

  @Test("Summaries: no summary dialog says AI polish or pasted text")
  func summaryNeverSaysPolish() {
    let problems: [PolishSetupProblem] = [
      .cloudKeyMissing(.openAI), .cloudKeyRejected(.openAI), .ollamaNotInstalled,
      .ollamaNotRunning, .ollamaNoModel, .ollamaModelNotInstalled,
      .localEngineNotDownloaded(.egOne), .localEngineDownloadPaused(.egOne),
      .localEngineUpdatePaused(.egOne), .localEngineFailed(.egOne),
      .localEngineDownloading(.egOne), .localEngineVerifying(.egOne), .appleModelNotReady,
      .appleUnavailable(.unsupportedOS), .appleUnavailable(.deviceNotEligible),
    ]
    for problem in problems {
      let c = Self.summary(problem, goBack: .egOne, keyNotSaved: true)
      let all = ([c.title, c.message] + c.buttons.map(\.title)).joined(separator: " ")
      #expect(all.localizedCaseInsensitiveContains("AI polish") == false, "\(problem): \(all)")
      #expect(all.localizedCaseInsensitiveContains("pasted") == false, "\(problem): \(all)")
    }
    for major in [26, 27] {
      let off = AppleIntelligenceSetupCopy.forOSMajorVersion(major).summaryLeaveMessage
      #expect(off.localizedCaseInsensitiveContains("AI polish") == false, "macOS \(major)")
    }
  }
}

// MARK: - The leave question as the app's own card (#4473)

/// #4473 (founder 2026-11-11). How the question's buttons sit on the card: the safe answer is the
/// filled button, every other button sits under it in order. Built from the real contents; the
/// expected titles are literals.
@MainActor
@Suite("Leave card layout (#4473)", .tags(.driftGuard))
struct PolishSetupLeaveCardLayoutTests {

  private static func content(
    _ problem: PolishSetupProblem, goBack: LLMProvider? = nil,
    scope: PolishSetupScope = .dictation
  ) -> PolishSetupLeaveDialogContent {
    PolishSetupLeaveDialogContent.make(
      for: PolishSetupLeaveRequest(
        intent: .sidebar(.history), scope: scope, episode: PolishSetupEpisodeToken(rawValue: 1),
        problem: problem, provider: .openAI, goBackProvider: goBack, keyNotSaved: false))
  }

  private static func layout(_ content: PolishSetupLeaveDialogContent)
    -> PolishSetupLeaveCardLayout
  {
    guard let layout = PolishSetupLeaveCardLayout(content) else {
      Issue.record("no layout for \(content.title)")
      return PolishSetupLeaveCardLayout(
        PolishSetupLeaveDialogContent(
          title: "", message: "",
          buttons: [PolishSetupLeaveButton(title: "x", role: .plain, action: .ok)]))!
    }
    return layout
  }

  @Test("actionable with no Go back: Finish setup is primary, Leave anyway is the only other")
  func actionablePlain() {
    let layout = Self.layout(Self.content(.localEngineNotDownloaded(.egOne)))
    #expect(layout.primary.title == "Finish setup")
    #expect(layout.primary.action == .finishSetup)
    #expect(layout.primary.role == .cancel)
    #expect(layout.secondary.map(\.title) == ["Leave anyway"])
    #expect(layout.secondary.map(\.action) == [.leaveAnyway])
    #expect(layout.escape == layout.primary)
  }

  @Test("actionable with Go back: Go back sits before Leave anyway, three buttons at most")
  func actionableGoBack() {
    let layout = Self.layout(Self.content(.cloudKeyMissing(.openAI), goBack: .gemini))
    #expect(layout.primary.title == "Finish setup")
    #expect(layout.secondary.map(\.title) == ["Go back to Gemini", "Leave anyway"])
    #expect(layout.secondary.map(\.action) == [.goBack(.gemini), .leaveAnyway])
    #expect(1 + layout.secondary.count == 3)
    #expect(layout.escape == layout.primary)
  }

  @Test("Apple Intelligence off: Pick another model is primary; Open System Settings stays")
  func appleOff() {
    let layout = Self.layout(Self.content(.appleUnavailable(.appleIntelligenceDisabled)))
    #expect(layout.primary.title == "Pick another model")
    #expect(layout.primary.role == .cancel)
    #expect(layout.primary.action == .finishSetup)
    #expect(layout.secondary.map(\.title) == ["Open System Settings", "Leave anyway"])
    #expect(layout.escape == layout.primary)
  }

  @Test("Apple Intelligence unavailable for every other reason: Pick another model is primary")
  func appleOtherReasons() {
    let reasons: [AIFailureReason] = [
      .deviceNotEligible, .unsupportedHardware, .unsupportedOS, .notCompiledIn,
      .frameworkMissingAtRuntime, .modelNotReady, .modelAccessFailed, .sessionInitFailed,
      .generationFailed, .unknownError,
    ]
    for reason in reasons {
      for scope in [PolishSetupScope.dictation, .meetingSummary] {
        let layout = Self.layout(Self.content(.appleUnavailable(reason), scope: scope))
        #expect(layout.primary.title == "Pick another model", "\(reason)")
        #expect(layout.primary.role == .cancel, "\(reason)")
        #expect(layout.secondary.map(\.title) == ["Leave anyway"], "\(reason)")
        #expect(layout.escape == layout.primary, "\(reason)")
      }
    }
  }

  @Test("an informational notice: OK is primary, nothing else, Escape answers nothing")
  func informational() {
    let layout = Self.layout(Self.content(.localEngineDownloading(.egOne)))
    #expect(layout.primary.title == "OK")
    #expect(layout.primary.action == .ok)
    #expect(layout.secondary.isEmpty)
    #expect(layout.escape == nil)
  }

  @Test("no content with buttons loses or duplicates one; Escape exists exactly with a cancel role")
  func everyProblem() {
    let stop = OutsideStopContext(provider: .egOne, generation: 1, memoryPressure: .warning)
    var problems: [PolishSetupProblem] = [
      .cloudKeyMissing(.openAI), .cloudKeyRejected(.claude), .ollamaNotInstalled,
      .ollamaNotRunning, .ollamaNoModel, .ollamaModelNotInstalled,
      .localEngineNotDownloaded(.egOne), .localEngineDownloadPaused(.s1Mini),
      .localEngineUpdatePaused(.egOne), .localEngineFailed(.egOne),
      .localEngineDownloading(.egOne), .localEngineVerifying(.s1Mini), .appleModelNotReady,
      .localEngineStoppedOutside(.egOne, stop), .cloudNoModel(.gemini),
      .cloudModelUnavailable(.openAI, "gpt-x"),
    ]
    let reasons: [AIFailureReason] = [
      .deviceNotEligible, .unsupportedHardware, .unsupportedOS, .notCompiledIn,
      .frameworkMissingAtRuntime, .appleIntelligenceDisabled, .modelNotReady, .modelAccessFailed,
      .sessionInitFailed, .generationFailed, .unknownError,
    ]
    problems += reasons.map { .appleUnavailable($0) }
    for problem in problems {
      for goBack in [nil, LLMProvider.openAI] {
        for scope in [PolishSetupScope.dictation, .meetingSummary] {
          let content = Self.content(problem, goBack: goBack, scope: scope)
          guard let layout = PolishSetupLeaveCardLayout(content) else {
            Issue.record("no layout for \(problem)")
            continue
          }
          let shown = [layout.primary] + layout.secondary
          #expect(shown.count == content.buttons.count, "\(problem)")
          for button in content.buttons {
            #expect(
              shown.filter { $0 == button }.count == content.buttons.filter { $0 == button }.count,
              "\(problem): \(button.title)")
          }
          let hasCancel = content.buttons.contains { $0.role == .cancel }
          #expect((layout.escape != nil) == hasCancel, "\(problem)")
          if hasCancel {
            #expect(layout.primary.role == .cancel, "\(problem)")
            #expect(layout.escape == layout.primary, "\(problem)")
          }
          #expect(shown.count <= 3, "\(problem)")
        }
      }
    }
  }

  @Test("a content with no buttons has no layout")
  func noButtons() {
    #expect(
      PolishSetupLeaveCardLayout(PolishSetupLeaveDialogContent(title: "t", message: "m", buttons: []))
        == nil)
  }
}
