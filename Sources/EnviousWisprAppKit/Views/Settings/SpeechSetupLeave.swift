import EnviousWisprCore
import Foundation

// MARK: - Leaving a speech engine tab with the picked engine not downloaded (#4578)

/// Which picked speech engine a leave question is about: dictation's on Dictation > Engine, or
/// EnviousMeet's on EnviousMeet > Models. The same card as AI Polish's leave question
/// (`PolishSetupLeaveCard`), with its own words and answers.
enum SpeechSetupScope: Equatable, CaseIterable {
  case dictation
  case meetings

  func contains(_ state: SettingsNavigationState) -> Bool {
    switch self {
    case .dictation: state.selectedPage == .dictation && state.dictationTab == .engine
    case .meetings: state.selectedPage == .meetings && state.meetingsTab == .models
    }
  }

  /// A new visit begins: the window records the engine picked at that moment for "Go back to".
  func entered(from before: SettingsNavigationState, to after: SettingsNavigationState) -> Bool {
    !contains(before) && contains(after)
  }

  /// A window state inside the guarded place, for judging an answer against the live facts.
  var guardedState: SettingsNavigationState {
    var state = SettingsNavigationState()
    switch self {
    case .dictation: state.perform(.destination(.dictation(.engine)))
    case .meetings: state.perform(.destination(.meetings(.models)))
    }
    return state
  }
}

/// One pending speech-engine leave question.
struct SpeechSetupLeaveRequest: Equatable {
  var intent: SettingsNavigationIntent
  let scope: SpeechSetupScope
  /// The picked engine that is not downloaded.
  let engine: ASRBackendType
  /// Its download is under way: a notice, nothing to set up.
  let downloading: Bool
  /// The engine picked when this visit began, offered only when it differs and is downloaded.
  let goBack: ASRBackendType?
}

/// The facts a question is judged on, read live by the window each time.
struct SpeechSetupFacts {
  /// The picked engine of each scope.
  let picked: (SpeechSetupScope) -> ASRBackendType
  /// Installed, missing, or nil while unknown (unknown never asks).
  let installed: (ASRBackendType) -> Bool?
  /// A download of this engine is under way.
  let downloading: (ASRBackendType) -> Bool
}

enum SpeechSetupLeaveGuard {
  /// The question to ask before `intent` leaves `scope`'s place, or nil to go.
  static func request(
    for intent: SettingsNavigationIntent, from state: SettingsNavigationState,
    scope: SpeechSetupScope, facts: SpeechSetupFacts, previous: ASRBackendType?
  ) -> SpeechSetupLeaveRequest? {
    guard scope.contains(state) else { return nil }
    var projected = state
    projected.perform(intent)
    guard !scope.contains(projected) else { return nil }
    let engine = facts.picked(scope)
    guard facts.installed(engine) == false else { return nil }
    let downloading = facts.downloading(engine)
    let goBack = previous.flatMap { $0 != engine && facts.installed($0) == true ? $0 : nil }
    return SpeechSetupLeaveRequest(
      intent: intent, scope: scope, engine: engine, downloading: downloading,
      goBack: downloading ? nil : goBack)
  }

  enum Outcome: Equatable {
    case stay
    /// Stay and start this engine's Set up model.
    case setUp(ASRBackendType)
    case navigate(SettingsNavigationIntent)
    /// Pick the engine again, then go.
    case restore(ASRBackendType, then: SettingsNavigationIntent)
  }

  /// The answer a press gives. Escape presses the card's safe button, which here is "Set up
  /// model"; Escape only stays and closes the question, so it never starts a download.
  static func answer(
    _ button: PolishSetupLeaveButton, press: PolishSetupLeaveCard.Press
  ) -> PolishSetupLeaveAction? {
    press == .escape ? nil : button.action
  }

  /// An answer, judged against the facts now: a question repaired meanwhile only lets the
  /// person go where they asked, and a changed question makes the answer do nothing.
  static func resolve(
    _ action: PolishSetupLeaveAction, request: SpeechSetupLeaveRequest, facts: SpeechSetupFacts,
    previous: ASRBackendType?
  ) -> Outcome {
    let live = Self.request(
      for: request.intent, from: request.scope.guardedState, scope: request.scope, facts: facts,
      previous: previous)
    guard let live else {
      switch action {
      case .finishSetup, .openSystemSettings, .goBack: return .stay
      case .goBackToEngine, .leaveAnyway, .ok: return .navigate(request.intent)
      }
    }
    guard live.engine == request.engine, live.downloading == request.downloading else {
      return .stay
    }
    switch action {
    case .finishSetup: return .setUp(request.engine)
    case .openSystemSettings, .goBack: return .stay
    case .goBackToEngine(let engine):
      // Only while it is still offered: different from the pick, and downloaded right now.
      guard live.goBack == engine else { return .stay }
      return .restore(engine, then: request.intent)
    case .leaveAnyway, .ok: return .navigate(request.intent)
    }
  }

  /// The card's words and buttons. "Set up model" is the safe answer: it stays and downloads.
  static func content(for request: SpeechSetupLeaveRequest) -> PolishSetupLeaveDialogContent {
    let name = request.engine.displayName
    let untilThen = untilThen(request.scope)
    if request.downloading {
      return PolishSetupLeaveDialogContent(
        title: Copy.downloadingTitle,
        message: Copy.downloading(name) + " " + untilThen,
        buttons: [
          PolishSetupLeaveButton(
            title: PolishSetupLeaveDialogContent.Copy.ok, role: .plain, action: .ok)
        ])
    }
    var buttons = [
      PolishSetupLeaveButton(title: Copy.setUpModel, role: .cancel, action: .finishSetup)
    ]
    if let goBack = request.goBack {
      buttons.append(
        PolishSetupLeaveButton(
          title: PolishSetupLeaveDialogContent.Copy.goBack(goBack.displayName), role: .plain,
          action: .goBackToEngine(goBack)))
    }
    buttons.append(
      PolishSetupLeaveButton(
        title: PolishSetupLeaveDialogContent.Copy.leaveAnyway, role: .plain, action: .leaveAnyway))
    return PolishSetupLeaveDialogContent(
      title: Copy.finishTitle, message: Copy.notDownloaded(name) + " " + untilThen,
      buttons: buttons)
  }

  private static func untilThen(_ scope: SpeechSetupScope) -> String {
    switch scope {
    case .dictation: Copy.untilThenDictation
    case .meetings: Copy.untilThenMeetings
    }
  }

  enum Copy {
    static let finishTitle = String(
      localized: "Finish speech engine setup",
      comment:
        "Speech engine settings, pop-up when leaving the tab while the picked speech engine is not downloaded."
    )
    static let downloadingTitle = String(
      localized: "Speech engine still downloading",
      comment:
        "Speech engine settings, notice when leaving the tab while the picked speech engine downloads."
    )
    static let setUpModel = String(
      localized: "Set up model",
      comment:
        "Speech engine settings, leave pop-up button: stay and download the picked speech engine.")
    static let untilThenDictation = String(
      localized: "Until then, dictation won't work.",
      comment:
        "Speech engine settings, leave pop-up: what does not work until the speech engine is downloaded."
    )
    static let untilThenMeetings = String(
      localized: "Until then, meetings won't get a transcript.",
      comment:
        "Speech engine settings, leave pop-up on EnviousMeet > Models: what does not work until the speech engine is downloaded."
    )

    static func notDownloaded(_ engine: String) -> String {
      String(
        localized: "\(engine) is not downloaded yet.",
        comment: "Speech engine settings, leave pop-up: the picked speech engine; its name.")
    }

    static func downloading(_ engine: String) -> String {
      String(
        localized: "\(engine) is still downloading.",
        comment:
          "Speech engine settings, leave notice: the picked speech engine downloads; its name.")
    }
  }
}
