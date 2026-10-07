import EnviousWisprCore
import EnviousWisprLLM
import Foundation
import SwiftUI

// MARK: - Leaving AI Polish with an unfinished setup (#3438)

/// Where a person asked to go: a sidebar row (that page's remembered tab) or an explicit
/// destination (a link or the menu, with its own tab), or a chosen Settings search result (#3482,
/// carried whole so the entry survives a pending dialog). Kept apart through a pending dialog, so
/// a sidebar click never turns into a default tab.
enum SettingsNavigationIntent: Equatable {
  case sidebar(SettingsPage)
  case destination(SettingsDestination)
  case search(SettingsSearchRequest)

  var page: SettingsPage {
    switch self {
    case .sidebar(let page): page
    case .destination(let destination): destination.page
    case .search(let request): request.destination.page
    }
  }
}

extension SettingsNavigationState {
  mutating func perform(_ intent: SettingsNavigationIntent) {
    switch intent {
    case .sidebar(let page): selectSidebar(page)
    case .destination(let destination): apply(destination)
    case .search(let request): apply(request)
    }
  }
}

/// One pending "you are leaving AI Polish" question: where the person was going (the latest
/// request wins), which episode it is about, and what the dialog offers.
struct PolishSetupLeaveRequest: Equatable {
  var intent: SettingsNavigationIntent
  let episode: PolishSetupEpisodeToken
  let problem: PolishSetupProblem
  /// The provider that had `problem` when the question was raised; reported with every answer.
  let provider: LLMProvider
  /// The provider chosen when this AI Polish visit began, offered as "Go back to" only when it
  /// differs from the current one and is fully set up now.
  let goBackProvider: LLMProvider?
  /// The current cloud provider has no saved key and the person typed one without saving.
  let keyNotSaved: Bool

  var promptSubject: PolishSetupPromptSubject {
    PolishSetupPromptSubject(problem: problem, provider: provider)
  }
}

/// What a button does. Every action is judged against the live state when pressed.
enum PolishSetupLeaveAction: Equatable {
  /// Stay on AI Polish (also Escape). Not an answer: nothing is acknowledged.
  case finishSetup
  case goBack(LLMProvider)
  case leaveAnyway
  /// The only button of an informational notice.
  case ok
  case openSystemSettings
}

struct PolishSetupLeaveButton: Equatable {
  enum Role: Equatable { case cancel, plain }
  let title: String
  let role: Role
  let action: PolishSetupLeaveAction
}

/// The dialog's words and buttons for one request. Pure, so every variant is tested without a
/// window. Never more than three buttons.
struct PolishSetupLeaveDialogContent: Equatable {
  let title: String
  let message: String
  let buttons: [PolishSetupLeaveButton]

  static func make(for request: PolishSetupLeaveRequest) -> PolishSetupLeaveDialogContent {
    let problem = request.problem
    if !problem.isActionable {
      return PolishSetupLeaveDialogContent(
        title: informationalTitle(problem), message: informationalMessage(problem),
        buttons: [PolishSetupLeaveButton(title: Copy.ok, role: .plain, action: .ok)])
    }
    if case .appleUnavailable(let reason) = problem {
      return apple(reason)
    }
    var buttons = [
      PolishSetupLeaveButton(title: Copy.finishSetup, role: .cancel, action: .finishSetup)
    ]
    if let previous = request.goBackProvider {
      buttons.append(
        PolishSetupLeaveButton(
          title: Copy.goBack(previous.displayName), role: .plain, action: .goBack(previous)))
    }
    buttons.append(
      PolishSetupLeaveButton(title: Copy.leaveAnyway, role: .plain, action: .leaveAnyway))
    return PolishSetupLeaveDialogContent(
      title: Copy.finishTitle,
      message: actionableReason(problem, keyNotSaved: request.keyNotSaved) + " " + Copy.untilThen,
      buttons: buttons)
  }

  private static func apple(_ reason: AIFailureReason) -> PolishSetupLeaveDialogContent {
    if reason == .appleIntelligenceDisabled {
      return PolishSetupLeaveDialogContent(
        title: Copy.appleOffTitle, message: Copy.appleOffMessage,
        buttons: [
          PolishSetupLeaveButton(
            title: Copy.openSystemSettings, role: .plain, action: .openSystemSettings),
          PolishSetupLeaveButton(title: Copy.pickAnother, role: .cancel, action: .finishSetup),
          PolishSetupLeaveButton(title: Copy.leaveAnyway, role: .plain, action: .leaveAnyway),
        ])
    }
    let message: String
    switch reason {
    case .deviceNotEligible, .unsupportedHardware: message = Copy.appleIneligibleMessage
    case .unsupportedOS, .notCompiledIn, .frameworkMissingAtRuntime, .appleIntelligenceDisabled,
      .modelNotReady, .modelAccessFailed, .sessionInitFailed, .generationFailed, .unknownError:
      message = Copy.appleUnsupportedOSMessage
    }
    return PolishSetupLeaveDialogContent(
      title: Copy.appleUnavailableTitle, message: message,
      buttons: [
        PolishSetupLeaveButton(title: Copy.pickAnother, role: .cancel, action: .finishSetup),
        PolishSetupLeaveButton(title: Copy.leaveAnyway, role: .plain, action: .leaveAnyway),
      ])
  }

  private static func actionableReason(_ problem: PolishSetupProblem, keyNotSaved: Bool) -> String {
    switch problem {
    case .cloudKeyMissing(let provider):
      return keyNotSaved
        ? Copy.keyNotSaved(provider.displayName) : Copy.addKey(provider.displayName)
    case .cloudKeyRejected(let provider): return Copy.keyRejected(provider.displayName)
    case .ollamaNotInstalled: return Copy.installOllama
    case .ollamaNotRunning: return Copy.startOllama
    case .ollamaNoModel: return Copy.chooseOllamaModel
    case .ollamaModelNotInstalled: return Copy.ollamaModelMissing
    case .localEngineNotDownloaded(let provider): return Copy.notDownloaded(provider.displayName)
    case .localEngineDownloadPaused(let provider):
      return Copy.downloadPaused(provider.displayName)
    case .localEngineUpdatePaused(let provider): return Copy.updatePaused(provider.displayName)
    case .localEngineFailed(let provider): return Copy.downloadFailed(provider.displayName)
    // Informational and Apple problems never reach here (handled above); spelled out so a new
    // problem must be decided.
    case .localEngineDownloading(let provider), .localEngineVerifying(let provider):
      return Copy.notDownloaded(provider.displayName)
    case .appleUnavailable, .appleModelNotReady:
      return Copy.appleUnsupportedOSMessage
    }
  }

  private static func informationalTitle(_ problem: PolishSetupProblem) -> String {
    switch problem {
    case .localEngineVerifying(let provider): return Copy.verifyingTitle(provider.displayName)
    case .appleModelNotReady: return Copy.appleNotReadyTitle
    case .localEngineDownloading(let provider): return Copy.downloadingTitle(provider.displayName)
    case .cloudKeyMissing, .cloudKeyRejected, .ollamaNotInstalled, .ollamaNotRunning,
      .ollamaNoModel, .ollamaModelNotInstalled, .localEngineNotDownloaded,
      .localEngineDownloadPaused, .localEngineUpdatePaused, .localEngineFailed, .appleUnavailable:
      return Copy.finishTitle
    }
  }

  private static func informationalMessage(_ problem: PolishSetupProblem) -> String {
    switch problem {
    case .localEngineVerifying: return Copy.verifyingMessage
    case .appleModelNotReady: return Copy.appleNotReadyMessage
    case .localEngineDownloading, .cloudKeyMissing, .cloudKeyRejected, .ollamaNotInstalled,
      .ollamaNotRunning, .ollamaNoModel, .ollamaModelNotInstalled, .localEngineNotDownloaded,
      .localEngineDownloadPaused, .localEngineUpdatePaused, .localEngineFailed, .appleUnavailable:
      return Copy.downloadingMessage
    }
  }

  /// The words, from the plan's copy deck (§17; council and Codex workshop, 2026-10-04).
  enum Copy {
    static var finishTitle: String {
      String(
        localized: "Finish AI polish setup",
        comment: "AI Polish, pop-up when leaving the page while the chosen model is not set up.")
    }
    static var untilThen: String {
      String(
        localized: "Until then, text is pasted without AI polish.",
        comment: "AI Polish, leave pop-up: the sentence after the reason.")
    }
    static func addKey(_ provider: String) -> String {
      String(
        localized: "Add your \(provider) API key to use AI polish.",
        comment: "AI Polish, leave pop-up reason. %@ is a provider name, such as OpenAI.")
    }
    static func keyNotSaved(_ provider: String) -> String {
      String(
        localized: "Your \(provider) key is not saved yet.",
        comment:
          "AI Polish, leave pop-up reason: a key was typed but Save was not pressed. %@ is a provider name, such as OpenAI."
      )
    }
    static func keyRejected(_ provider: String) -> String {
      String(
        localized: "\(provider) did not accept your API key.",
        comment: "AI Polish, leave pop-up reason. %@ is a provider name, such as OpenAI.")
    }
    static var installOllama: String {
      String(
        localized: "Install Ollama to use AI polish.",
        comment: "AI Polish, leave pop-up reason. Ollama is a product name; keep it.")
    }
    static var startOllama: String {
      String(
        localized: "Start Ollama to use AI polish.",
        comment: "AI Polish, leave pop-up reason. Ollama is a product name; keep it.")
    }
    static var chooseOllamaModel: String {
      String(
        localized: "Choose an Ollama model to use AI polish.",
        comment: "AI Polish, leave pop-up reason. Ollama is a product name; keep it.")
    }
    static var ollamaModelMissing: String {
      String(
        localized: "Download the selected Ollama model, or choose another.",
        comment: "AI Polish, leave pop-up reason. Ollama is a product name; keep it.")
    }
    static func notDownloaded(_ model: String) -> String {
      String(
        localized: "\(model) is not downloaded yet.",
        comment: "AI Polish, leave pop-up reason. %@ is a model name, such as EG-1.")
    }
    static func downloadPaused(_ model: String) -> String {
      String(
        localized: "The \(model) download is paused.",
        comment: "AI Polish, leave pop-up reason. %@ is a model name, such as EG-1.")
    }
    static func updatePaused(_ model: String) -> String {
      String(
        localized: "The \(model) update is paused.",
        comment: "AI Polish, leave pop-up reason. %@ is a model name, such as EG-1.")
    }
    static func downloadFailed(_ model: String) -> String {
      String(
        localized: "The \(model) download did not finish.",
        comment: "AI Polish, leave pop-up reason. %@ is a model name, such as EG-1.")
    }
    static func downloadingTitle(_ model: String) -> String {
      String(
        localized: "\(model) is still downloading",
        comment: "AI Polish, notice when leaving the page during a download. %@ is a model name.")
    }
    static var downloadingMessage: String {
      String(
        localized:
          "The download is still in progress. Until setup finishes, text is pasted without AI polish.",
        comment: "AI Polish, notice when leaving the page during a download.")
    }
    static func verifyingTitle(_ model: String) -> String {
      String(
        localized: "Checking the downloaded \(model)",
        comment:
          "AI Polish, notice when leaving the page while a download is checked. %@ is a model name."
      )
    }
    static var verifyingMessage: String {
      String(
        localized: "Until this check finishes, text is pasted without AI polish.",
        comment: "AI Polish, notice when leaving the page while a download is checked.")
    }
    static var appleNotReadyTitle: String {
      String(
        localized: "Apple Intelligence isn't ready yet",
        comment: "AI Polish, notice when leaving the page. Apple Intelligence is a product name.")
    }
    static var appleNotReadyMessage: String {
      String(
        localized: "Until it is ready, text is pasted without AI polish.",
        comment: "AI Polish, notice when leaving the page while Apple Intelligence is not ready.")
    }
    static var appleUnavailableTitle: String {
      String(
        localized: "Apple Intelligence isn't available",
        comment: "AI Polish, leave pop-up title. Apple Intelligence is a product name.")
    }
    static var appleUnsupportedOSMessage: String {
      String(
        localized:
          "AI polish with Apple Intelligence requires macOS 26 or later. Pick another model.",
        comment: "AI Polish, leave pop-up. Apple Intelligence and macOS are product names.")
    }
    static var appleIneligibleMessage: String {
      String(
        localized: "This Mac does not support Apple Intelligence.",
        comment: "AI Polish, leave pop-up. Apple Intelligence is a product name.")
    }
    static var appleOffTitle: String {
      String(
        localized: "Apple Intelligence is turned off",
        comment: "AI Polish, leave pop-up title. Apple Intelligence is a product name.")
    }
    static var appleOffMessage: String {
      String(
        localized: "Turn it on in System Settings, or pick another model.",
        comment: "AI Polish, leave pop-up. System Settings is the name of the macOS app.")
    }
    static var finishSetup: String {
      String(
        localized: "Finish setup", comment: "AI Polish, leave pop-up button: stay on the page.")
    }
    static func goBack(_ provider: String) -> String {
      String(
        localized: "Go back to \(provider)",
        comment:
          "AI Polish, leave pop-up button: choose the previous model again. %@ is a model or provider name, such as EG-1."
      )
    }
    static var leaveAnyway: String {
      String(localized: "Leave anyway", comment: "AI Polish, leave pop-up button.")
    }
    static var pickAnother: String {
      String(
        localized: "Pick another model",
        comment: "AI Polish, leave pop-up button: stay on the page to choose another model.")
    }
    static var openSystemSettings: String {
      String(
        localized: "Open System Settings",
        comment: "AI Polish, leave pop-up button. System Settings is the name of the macOS app.")
    }
    static var ok: String {
      String(localized: "OK", comment: "AI Polish, notice button.")
    }
  }
}

/// The leave guard's decisions, apart from any window so they are tested directly. The window
/// shell calls these and applies the results.
@MainActor
enum PolishSetupLeaveGuard {
  /// The request to show when `intent` leaves AI Polish now, or nil to navigate at once.
  static func request(
    for intent: SettingsNavigationIntent, from current: SettingsPage,
    monitor: PolishSetupMonitor, previousProvider: LLMProvider?, currentProvider: LLMProvider,
    keyNotSaved: Bool
  ) -> PolishSetupLeaveRequest? {
    guard current == .aiPolish, intent.page != .aiPolish else { return nil }
    // A live read: the dialog is about the state now, not the last observed one.
    _ = monitor.currentContext()
    guard monitor.shows(.leaveDialog), let subject = monitor.promptSubject,
      let episode = monitor.currentEpisode
    else { return nil }
    let problem = subject.problem
    var goBack: LLMProvider?
    if let previous = previousProvider, previous != currentProvider, previous != .none,
      monitor.readiness(for: previous) == .noProblem
    {
      goBack = previous
    }
    let keyIsMissing: Bool
    if case .cloudKeyMissing = problem { keyIsMissing = true } else { keyIsMissing = false }
    return PolishSetupLeaveRequest(
      intent: intent, episode: episode, problem: problem, provider: subject.provider,
      goBackProvider: goBack, keyNotSaved: keyIsMissing && keyNotSaved)
  }

  /// What pressing `action` on `request` does now. Every button is validated against the live
  /// state BEFORE any effect: an effect is returned only while the displayed episode is still
  /// the current one. A changed state never re-presents a question from here (a second alert
  /// racing the first one's dismissal could overwrite a newer request); the person stays, and
  /// the next leave asks about whatever is true then.
  enum Outcome: Equatable {
    /// Close the dialog and stay on AI Polish.
    case stay
    /// Close the dialog and go where the person asked.
    case navigate(SettingsNavigationIntent)
    /// Choose `provider` through the normal setter, then try the leave again.
    case restoreProvider(LLMProvider, then: SettingsNavigationIntent)
    /// Open Apple Intelligence's pane in System Settings and stay.
    case openSystemSettings
  }

  static func resolve(
    _ action: PolishSetupLeaveAction, request: PolishSetupLeaveRequest,
    monitor: PolishSetupMonitor, previousProvider: LLMProvider?, currentProvider: LLMProvider,
    keyNotSaved: Bool
  ) -> Outcome {
    let live = Self.request(
      for: request.intent, from: .aiPolish, monitor: monitor, previousProvider: previousProvider,
      currentProvider: currentProvider, keyNotSaved: keyNotSaved)
    // Repaired while the question was open: nothing left to answer.
    guard let live else {
      switch action {
      case .finishSetup, .openSystemSettings: return .stay
      case .goBack, .leaveAnyway, .ok: return .navigate(request.intent)
      }
    }
    // A different problem now: this answer was about the old one, so it does nothing.
    guard live.episode == request.episode, live.problem == request.problem else { return .stay }
    switch action {
    case .finishSetup:
      return .stay
    case .openSystemSettings:
      guard case .appleUnavailable(.appleIntelligenceDisabled) = live.problem else { return .stay }
      return .openSystemSettings
    case .goBack(let provider):
      // Only while it is still offered: different, and fully set up right now.
      guard live.goBackProvider == provider else { return .stay }
      return .restoreProvider(provider, then: request.intent)
    case .leaveAnyway, .ok:
      monitor.acknowledge(.leaveDialog, in: request.episode)
      return .navigate(request.intent)
    }
  }
}

/// Whether the AI Polish page holds a typed, unsaved key for the chosen provider (#3438).
/// Content-free: only the yes/no reaches the window shell.
struct PolishSetupUnsavedKeyDraftKey: PreferenceKey {
  static let defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}
