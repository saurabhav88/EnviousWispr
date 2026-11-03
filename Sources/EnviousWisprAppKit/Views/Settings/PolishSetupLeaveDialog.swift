import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import SwiftUI

// MARK: - Leaving AI Polish (#3438) or EnviousMeet Summaries (#4321) with an unfinished setup

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

/// Which chosen engine a leave question is about (#4321): dictation's AI polish model on the
/// AI Polish page, or EnviousMeet's summary engine on the Meetings page's Summaries tab. One guard
/// serves both; the scope picks the guarded place and the words.
enum PolishSetupScope: Equatable {
  case dictation
  case meetingSummary

  /// Whether the window showing `state` is inside this scope's guarded place.
  func contains(_ state: SettingsNavigationState) -> Bool {
    switch self {
    case .dictation: state.selectedPage == .aiPolish
    case .meetingSummary: state.selectedPage == .meetings && state.meetingsTab == .summaries
    }
  }

  /// Whether the window moved into the guarded place: a new visit begins, and the window records
  /// the engine chosen at that moment for "Go back to".
  func entered(from before: SettingsNavigationState, to after: SettingsNavigationState) -> Bool {
    !contains(before) && contains(after)
  }

  /// A window state inside the guarded place, for judging an answer against the live state:
  /// while a question is open the window stays where it was, so leaving is decided the same way.
  var guardedState: SettingsNavigationState {
    var state = SettingsNavigationState()
    switch self {
    case .dictation: state.perform(.destination(.aiPolish))
    case .meetingSummary: state.perform(.destination(.meetings(.summaries)))
    }
    return state
  }
}

/// One pending "you are leaving" question: where the person was going (the latest request wins),
/// which engine and episode it is about, and what the dialog offers.
struct PolishSetupLeaveRequest: Equatable {
  var intent: SettingsNavigationIntent
  let scope: PolishSetupScope
  let episode: PolishSetupEpisodeToken
  let problem: PolishSetupProblem
  /// The provider that had `problem` when the question was raised; reported with every answer.
  let provider: LLMProvider
  /// The provider chosen when this visit to the guarded place began, offered as "Go back to" only when it
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
  /// Stay in the guarded place (also Escape). Not an answer: nothing is acknowledged.
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
    let scope = request.scope
    if !problem.isActionable {
      return PolishSetupLeaveDialogContent(
        title: informationalTitle(problem, scope), message: informationalMessage(problem, scope),
        buttons: [PolishSetupLeaveButton(title: Copy.ok, role: .plain, action: .ok)])
    }
    if case .appleUnavailable(let reason) = problem {
      return apple(reason, scope)
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
      title: Copy.finishTitle(scope),
      message: actionableReason(problem, scope, keyNotSaved: request.keyNotSaved) + " "
        + Copy.untilThen(scope),
      buttons: buttons)
  }

  private static func apple(
    _ reason: AIFailureReason, _ scope: PolishSetupScope
  ) -> PolishSetupLeaveDialogContent {
    if reason == .appleIntelligenceDisabled {
      return PolishSetupLeaveDialogContent(
        title: Copy.appleOffTitle, message: Copy.appleOffMessage(scope),
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
      message = Copy.appleUnsupportedOSMessage(scope)
    }
    return PolishSetupLeaveDialogContent(
      title: Copy.appleUnavailableTitle, message: message,
      buttons: [
        PolishSetupLeaveButton(title: Copy.pickAnother, role: .cancel, action: .finishSetup),
        PolishSetupLeaveButton(title: Copy.leaveAnyway, role: .plain, action: .leaveAnyway),
      ])
  }

  private static func actionableReason(
    _ problem: PolishSetupProblem, _ scope: PolishSetupScope, keyNotSaved: Bool
  ) -> String {
    switch problem {
    case .cloudKeyMissing(let provider):
      return keyNotSaved
        ? Copy.keyNotSaved(provider.displayName) : Copy.addKey(provider.displayName, scope)
    case .cloudKeyRejected(let provider): return Copy.keyRejected(provider.displayName)
    case .ollamaNotInstalled: return Copy.installOllama(scope)
    case .ollamaNotRunning: return Copy.startOllama(scope)
    case .ollamaNoModel: return Copy.chooseOllamaModel(scope)
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
      return Copy.appleUnsupportedOSMessage(scope)
    // #3988: the monitor never raises a leave dialog for it; its words have one owner.
    case .localEngineStoppedOutside(_, let stop):
      return PolishSetupSurfaceCopy.outsideStopNotice(stop)
    case .cloudNoModel(let provider):
      return PolishSetupSurfaceCopy.chooseProviderModel(provider, scope)
    case .cloudModelUnavailable(_, let model):
      return PolishSetupSurfaceCopy.modelNoLongerWorksNotice(model)
    }
  }

  private static func informationalTitle(
    _ problem: PolishSetupProblem, _ scope: PolishSetupScope
  ) -> String {
    switch problem {
    case .localEngineVerifying(let provider): return Copy.verifyingTitle(provider.displayName)
    case .appleModelNotReady: return Copy.appleNotReadyTitle
    case .localEngineDownloading(let provider): return Copy.downloadingTitle(provider.displayName)
    // #3988: never raised on leaving (the monitor refuses it); one copy owner if it ever is.
    case .localEngineStoppedOutside:
      return PolishSetupSurfaceCopy.outsideStopTitle
    case .cloudKeyMissing, .cloudKeyRejected, .ollamaNotInstalled, .ollamaNotRunning,
      .ollamaNoModel, .ollamaModelNotInstalled, .localEngineNotDownloaded,
      .localEngineDownloadPaused, .localEngineUpdatePaused, .localEngineFailed, .appleUnavailable,
      .cloudNoModel, .cloudModelUnavailable:
      return Copy.finishTitle(scope)
    }
  }

  private static func informationalMessage(
    _ problem: PolishSetupProblem, _ scope: PolishSetupScope
  ) -> String {
    switch problem {
    case .localEngineVerifying: return Copy.verifyingMessage(scope)
    case .appleModelNotReady: return Copy.appleNotReadyMessage(scope)
    case .localEngineStoppedOutside(_, let stop):
      return PolishSetupSurfaceCopy.outsideStopNotice(stop)
    case .localEngineDownloading, .cloudKeyMissing, .cloudKeyRejected, .ollamaNotInstalled,
      .ollamaNotRunning, .ollamaNoModel, .ollamaModelNotInstalled, .localEngineNotDownloaded,
      .localEngineDownloadPaused, .localEngineUpdatePaused, .localEngineFailed, .appleUnavailable,
      .cloudNoModel, .cloudModelUnavailable:
      return Copy.downloadingMessage(scope)
    }
  }

  /// The words, from the plan's copy deck (§17; council and Codex workshop, 2026-10-04). Lines
  /// that name what is lost have a meeting-summary twin (#4321 §17 F2); neutral lines (a key not
  /// saved or rejected, a model not downloaded, the buttons) serve both scopes.
  enum Copy {
    static func finishTitle(_ scope: PolishSetupScope) -> String {
      switch scope {
      case .dictation:
        String(
          localized: "Finish AI polish setup",
          comment: "AI Polish, pop-up when leaving the page while the chosen model is not set up.")
      case .meetingSummary:
        String(
          localized: "Finish summary setup",
          comment:
            "EnviousMeet Summaries tab, pop-up when leaving the tab while the chosen summary engine is not set up."
        )
      }
    }
    static func untilThen(_ scope: PolishSetupScope) -> String {
      switch scope {
      case .dictation:
        String(
          localized: "Until then, text is pasted without AI polish.",
          comment: "AI Polish, leave pop-up: the sentence after the reason.")
      case .meetingSummary:
        String(
          localized: "Until then, EnviousMeet can't write meeting summaries.",
          comment:
            "EnviousMeet Summaries tab, leave pop-up: the sentence after the reason. EnviousMeet is a product name; keep it."
        )
      }
    }
    static func addKey(_ provider: String, _ scope: PolishSetupScope) -> String {
      switch scope {
      case .dictation:
        String(
          localized: "Add your \(provider) API key to use AI polish.",
          comment: "AI Polish, leave pop-up reason. %@ is a provider name, such as OpenAI.")
      case .meetingSummary:
        String(
          localized: "Add your \(provider) API key to write meeting summaries.",
          comment:
            "EnviousMeet Summaries tab, leave pop-up reason. %@ is a provider name, such as OpenAI."
        )
      }
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
    static func installOllama(_ scope: PolishSetupScope) -> String {
      switch scope {
      case .dictation:
        String(
          localized: "Install Ollama to use AI polish.",
          comment: "AI Polish, leave pop-up reason. Ollama is a product name; keep it.")
      case .meetingSummary:
        String(
          localized: "Install Ollama to write meeting summaries.",
          comment:
            "EnviousMeet Summaries tab, leave pop-up reason. Ollama is a product name; keep it.")
      }
    }
    static func startOllama(_ scope: PolishSetupScope) -> String {
      switch scope {
      case .dictation:
        String(
          localized: "Start Ollama to use AI polish.",
          comment: "AI Polish, leave pop-up reason. Ollama is a product name; keep it.")
      case .meetingSummary:
        String(
          localized: "Start Ollama to write meeting summaries.",
          comment:
            "EnviousMeet Summaries tab, leave pop-up reason. Ollama is a product name; keep it.")
      }
    }
    static func chooseOllamaModel(_ scope: PolishSetupScope) -> String {
      switch scope {
      case .dictation:
        String(
          localized: "Choose an Ollama model to use AI polish.",
          comment: "AI Polish, leave pop-up reason. Ollama is a product name; keep it.")
      case .meetingSummary:
        String(
          localized: "Choose an Ollama model to write meeting summaries.",
          comment:
            "EnviousMeet Summaries tab, leave pop-up reason. Ollama is a product name; keep it.")
      }
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
    static func downloadingMessage(_ scope: PolishSetupScope) -> String {
      switch scope {
      case .dictation:
        String(
          localized:
            "The download is still in progress. Until setup finishes, text is pasted without AI polish.",
          comment: "AI Polish, notice when leaving the page during a download.")
      case .meetingSummary:
        String(
          localized:
            "The download is still in progress. Until setup finishes, EnviousMeet can't write meeting summaries.",
          comment:
            "EnviousMeet Summaries tab, notice when leaving the tab during a download. EnviousMeet is a product name; keep it."
        )
      }
    }
    static func verifyingTitle(_ model: String) -> String {
      String(
        localized: "Checking the downloaded \(model)",
        comment:
          "AI Polish, notice when leaving the page while a download is checked. %@ is a model name."
      )
    }
    static func verifyingMessage(_ scope: PolishSetupScope) -> String {
      switch scope {
      case .dictation:
        String(
          localized: "Until this check finishes, text is pasted without AI polish.",
          comment: "AI Polish, notice when leaving the page while a download is checked.")
      case .meetingSummary:
        String(
          localized: "Until this check finishes, EnviousMeet can't write meeting summaries.",
          comment:
            "EnviousMeet Summaries tab, notice when leaving the tab while a download is checked. EnviousMeet is a product name; keep it."
        )
      }
    }
    static var appleNotReadyTitle: String {
      String(
        localized: "Apple Intelligence isn't ready yet",
        comment: "AI Polish, notice when leaving the page. Apple Intelligence is a product name.")
    }
    static func appleNotReadyMessage(_ scope: PolishSetupScope) -> String {
      switch scope {
      case .dictation:
        String(
          localized: "Until it is ready, text is pasted without AI polish.",
          comment: "AI Polish, notice when leaving the page while Apple Intelligence is not ready.")
      case .meetingSummary:
        String(
          localized: "Until it is ready, EnviousMeet can't write meeting summaries.",
          comment:
            "EnviousMeet Summaries tab, notice when leaving the tab while Apple Intelligence is not ready. EnviousMeet is a product name; keep it."
        )
      }
    }
    static var appleUnavailableTitle: String {
      String(
        localized: "Apple Intelligence isn't available",
        comment: "AI Polish, leave pop-up title. Apple Intelligence is a product name.")
    }
    static func appleUnsupportedOSMessage(_ scope: PolishSetupScope) -> String {
      switch scope {
      case .dictation:
        String(
          localized:
            "AI polish with Apple Intelligence requires macOS 26 or later. Pick another model.",
          comment: "AI Polish, leave pop-up. Apple Intelligence and macOS are product names.")
      case .meetingSummary:
        String(
          localized:
            "Meeting summaries with Apple Intelligence require macOS 26 or later. Pick another model.",
          comment:
            "EnviousMeet Summaries tab, leave pop-up. Apple Intelligence and macOS are product names."
        )
      }
    }
    static var appleIneligibleMessage: String {
      String(
        localized: "This Mac does not support Apple Intelligence.",
        comment: "AI Polish, leave pop-up. Apple Intelligence is a product name.")
    }
    static var appleOffTitle: String {
      AppleIntelligenceSetupCopy.current.title
    }
    /// Owned by `AppleIntelligenceSetupCopy`, which words it for the displaying Mac's macOS.
    static func appleOffMessage(_ scope: PolishSetupScope) -> String {
      switch scope {
      case .dictation: AppleIntelligenceSetupCopy.current.leaveMessage
      case .meetingSummary: AppleIntelligenceSetupCopy.current.summaryLeaveMessage
      }
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
  /// The request to show when `intent` leaves `scope`'s guarded place now, or nil to navigate at
  /// once. Leaving is decided by performing the whole intent on a copy of the window's state, so a
  /// sidebar return keeps its remembered tab and a search result keeps its tab (#4321 §17 F1).
  /// `monitor` is the scope's own monitor; `currentProvider` is the scope's chosen engine.
  static func request(
    for intent: SettingsNavigationIntent, from current: SettingsNavigationState,
    scope: PolishSetupScope, monitor: PolishSetupMonitor, previousProvider: LLMProvider?,
    currentProvider: LLMProvider, keyNotSaved: Bool
  ) -> PolishSetupLeaveRequest? {
    guard scope.contains(current) else { return nil }
    var projected = current
    projected.perform(intent)
    guard !scope.contains(projected) else { return nil }
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
      intent: intent, scope: scope, episode: episode, problem: problem, provider: subject.provider,
      goBackProvider: goBack, keyNotSaved: keyIsMissing && keyNotSaved)
  }

  /// "Go back to" for `scope`: the previous engine through that scope's normal setter. The
  /// summary engine's never touches dictation's model, and dictation's never the summary
  /// engine (#4321 §17 F3).
  static func restore(
    _ provider: LLMProvider, scope: PolishSetupScope, in settings: SettingsManager
  ) {
    switch scope {
    case .dictation: settings.llmProvider = provider
    case .meetingSummary: settings.meetingSummaryLLMProvider = provider
    }
  }

  /// Another request arriving while a question is open: the latest destination replaces the
  /// pending one's, and the question keeps its episode, problem and offers. The window shell and
  /// the tests both go through here, so neither can drift from the other.
  static func replacingPendingDestination(
    of pending: PolishSetupLeaveRequest, with intent: SettingsNavigationIntent
  ) -> PolishSetupLeaveRequest {
    var latest = pending
    latest.intent = intent
    return latest
  }

  /// What pressing `action` on `request` does now. Every button is validated against the live
  /// state BEFORE any effect: an effect is returned only while the displayed episode is still
  /// the current one. A changed state never re-presents a question from here (a second alert
  /// racing the first one's dismissal could overwrite a newer request); the person stays, and
  /// the next leave asks about whatever is true then.
  enum Outcome: Equatable {
    /// Close the dialog and stay in the guarded place.
    case stay
    /// Close the dialog and go where the person asked.
    case navigate(SettingsNavigationIntent)
    /// Choose `provider` through the normal setter of the request's scope (dictation's model or
    /// the summary engine), then try the leave again.
    case restoreProvider(LLMProvider, then: SettingsNavigationIntent)
    /// Open the existing System Settings destination and stay; no repair is promised.
    case openSystemSettings
  }

  static func resolve(
    _ action: PolishSetupLeaveAction, request: PolishSetupLeaveRequest,
    monitor: PolishSetupMonitor, previousProvider: LLMProvider?, currentProvider: LLMProvider,
    keyNotSaved: Bool
  ) -> Outcome {
    let live = Self.request(
      for: request.intent, from: request.scope.guardedState, scope: request.scope,
      monitor: monitor, previousProvider: previousProvider, currentProvider: currentProvider,
      keyNotSaved: keyNotSaved)
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

/// Whether the page on screen (AI Polish, #3438, or EnviousMeet Summaries, #4321) holds a typed,
/// unsaved key for its chosen provider. Content-free: only the yes/no reaches the window shell.
/// Only one of the two pages is on screen at a time, so one value serves both.
struct PolishSetupUnsavedKeyDraftKey: PreferenceKey {
  static let defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}

extension ProviderSetupModel {
  /// A key typed for `provider` and not saved: the field differs from what was last loaded or
  /// saved, and is not empty. A key loaded from the Keychain is not a draft, and a local engine
  /// has no key. One rule for the AI Polish page and the Summaries tab (#4321 §17 F5).
  func hasUnsavedKeyDraft(for provider: LLMProvider) -> Bool {
    switch provider {
    case .openAI: return openAIKeyEdited && !openAIKey.isEmpty
    case .gemini: return geminiKeyEdited && !geminiKey.isEmpty
    case .claude: return claudeKeyEdited && !claudeKey.isEmpty
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return false
    }
  }
}
